#!/usr/bin/env python3
"""Turn a real packet capture (pcap or pcapng, Ethernet) into the board's replay stimulus.

Writes (same files and formats as scripts/gen_mdp3.py, so the RTL/testbench are untouched):
  fpga/replay.mem          one 33-bit word per line: {last, data[31:0]}
  sim/events_expected.txt  golden events
  rtl/build_params.svh     N_WORDS / AW_MEM / CFG_IP / CFG_PORT / expected counters + checksum

Typical use (from the project root):
  python scripts/pcap_to_replay.py capture.pcapng                 # auto-detect the multicast group
  python scripts/pcap_to_replay.py capture.pcap --group 224.0.31.1:14310 --max-words 8192
  python scripts/pcap_to_replay.py capture.pcap --strip-vlan --keep-all

IMPORTANT: the golden decoder is the SAME model as the RTL (gen_mdp3.py: MDP3-style layout,
template IDs 46/48, 11-byte root block, 32-byte entries). A PASS on the board therefore proves
"RTL == model", not "RTL == CME". The layout survey printed below tells you whether the real data
actually looks like that model (template/schema histogram, root and group block lengths, ...).

Not supported by the hardware (frames are counted/dropped, never decoded): VLAN tags (use
--strip-vlan), IP options, IP fragments, UDP length not a multiple of 4, message sizes not a
multiple of 4. Truncated captures (snaplen < frame size) are dropped by this script.
"""
import argparse, collections, importlib.util, math, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen_mdp3", os.path.join(HERE, "gen_mdp3.py"))
gen = importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)


# ---------------------------------------------------------------- capture readers
def read_pcap(buf):
    """Classic libpcap. Returns (frames, linktype). frames = [(data, orig_len)]."""
    magic = buf[:4]
    if   magic == b"\xd4\xc3\xb2\xa1": end = "<"
    elif magic == b"\xa1\xb2\xc3\xd4": end = ">"
    elif magic == b"\x4d\x3c\xb2\xa1": end = "<"      # nanosecond variants
    elif magic == b"\xa1\xb2\x3c\x4d": end = ">"
    else: raise ValueError("not a pcap file")
    linktype = struct.unpack(end + "I", buf[20:24])[0]
    off, frames = 24, []
    while off + 16 <= len(buf):
        _, _, incl, orig = struct.unpack(end + "IIII", buf[off:off + 16]); off += 16
        if off + incl > len(buf): break                 # damaged tail
        frames.append((buf[off:off + incl], orig)); off += incl
    return frames, linktype


def read_pcapng(buf):
    off, end, iface_lt, frames = 0, "<", [], []
    while off + 12 <= len(buf):
        btype = struct.unpack("<I", buf[off:off + 4])[0]
        if btype == 0x0A0D0D0A:                          # section header: byte order magic
            bom = buf[off + 8:off + 12]
            end = "<" if bom == b"\x4d\x3c\x2b\x1a" else ">"
            iface_lt = []
        btype, blen = struct.unpack(end + "II", buf[off:off + 8])
        if blen < 12 or off + blen > len(buf): break
        body = buf[off + 8:off + blen - 4]
        if btype == 1:                                   # interface description
            iface_lt.append(struct.unpack(end + "H", body[0:2])[0])
        elif btype == 6:                                 # enhanced packet
            ifid, _, _, cap, orig = struct.unpack(end + "IIIII", body[:20])
            if iface_lt and iface_lt[ifid] == 1: frames.append((body[20:20 + cap], orig))
        elif btype == 3:                                 # simple packet (interface 0)
            orig = struct.unpack(end + "I", body[:4])[0]
            if iface_lt and iface_lt[0] == 1: frames.append((body[4:4 + min(orig, len(body) - 4)], orig))
        off += blen
    if not iface_lt: raise ValueError("pcapng without interface description")
    return frames, 1


def read_capture(path):
    buf = open(path, "rb").read()
    if buf[:4] == b"\x0a\x0d\x0d\x0a": return read_pcapng(buf)
    return read_pcap(buf)


# ---------------------------------------------------------------- frame helpers
def strip_vlan(fr):
    if len(fr) >= 18 and fr[12:14] in (b"\x81\x00", b"\x88\xa8"):
        return fr[:12] + fr[16:]
    return fr


def udp_key(fr):
    """(dst_ip, dst_port) for a plain IPv4/UDP frame, else None."""
    if len(fr) < 42 or fr[12:14] != b"\x08\x00" or fr[14] != 0x45 or fr[23] != 17: return None
    if struct.unpack(">H", fr[20:22])[0] & 0x3FFF: return None          # MF flag / fragment offset
    return struct.unpack(">I", fr[30:34])[0], struct.unpack(">H", fr[36:38])[0]


def ip_str(v): return ".".join(str((v >> s) & 255) for s in (24, 16, 8, 0))


def survey(frames, group):
    """Walk the payloads exactly like the decoder does and report what the data looks like."""
    tmpl, schema, ver = collections.Counter(), collections.Counter(), collections.Counter()
    blk, grp, act, etp = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    nmsg = bad = sz8 = 0
    for fr in frames:
        if udp_key(fr) != group: continue          # only frames the hardware would pass
        ulen = struct.unpack(">H", fr[38:40])[0]
        if ulen % 4 or ulen < 20: continue
        pl = fr[42:42 + ulen - 8]; L = len(pl); off = 12
        while off < L:
            if off + 4 > L: bad += 1; break
            size = struct.unpack("<H", pl[off:off + 2])[0]
            if size % 4 or size < 12 or off + size > L: bad += 1; break
            m = pl[off:off + size]; nmsg += 1; sz8 += (size % 8 == 0)
            if size >= 24:
                bl, t, sc, v = struct.unpack("<HHHH", m[2:10])
                tmpl[t] += 1; schema[sc] += 1; ver[v] += 1; blk[bl] += 1
                if t in gen.TEMPLATES:
                    grp[struct.unpack("<H", m[21:23])[0]] += 1
                    for i in range(m[23]):
                        b = 24 + 32 * i
                        if b + 28 > size: break
                        act[m[b + 25]] += 1; etp[chr(m[b + 26]) if 32 <= m[b + 26] < 127 else m[b + 26]] += 1
            off += size
    top = lambda c, n=8: ", ".join(f"{k}:{v}" for k, v in c.most_common(n)) or "-"
    print("\nLayout survey of the selected frames (what the decoder will see):")
    print(f"  messages walked        : {nmsg}  (size%8==0: {sz8}; framing errors: {bad})")
    print(f"  templateId histogram   : {top(tmpl)}   [decoder knows {sorted(gen.TEMPLATES)}]")
    print(f"  schemaId / version     : {top(schema)} / {top(ver)}")
    print(f"  root blockLength       : {top(blk)}   [decoder assumes 11]")
    print(f"  group blockLength      : {top(grp)}   [decoder assumes 32]")
    print(f"  MDUpdateAction values  : {top(act)}")
    print(f"  MDEntryType values     : {top(etp)}")
    known = sum(v for k, v in tmpl.items() if k in gen.TEMPLATES)
    if nmsg and known * 2 < nmsg:
        print("  WARNING: fewer than half of the messages use a template the decoder knows -- check the CME schema XML.")
    if blk and (set(blk) - {11}) and any(k in gen.TEMPLATES for k in tmpl):
        print("  WARNING: root blockLength != 11 seen -- entry offsets in mdp_decode.sv will not match this schema version.")
    if grp and set(grp) - {32}:
        print("  WARNING: group blockLength != 32 seen -- entry size in mdp_decode.sv will not match.")


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture", help=".pcap or .pcapng (Ethernet link type)")
    ap.add_argument("--out", default=os.path.dirname(HERE), help="project root (default: the folder above scripts/)")
    ap.add_argument("--group", help="multicast dst as IP:PORT (default: most frequent multicast UDP group)")
    ap.add_argument("--max-words", type=int, default=8192,
                    help="replay memory budget in 32-bit words (default 8192 = AW 13; the board's BRAM allows up to ~32768 "
                         "but deeper memories may cost timing at 320 MHz)")
    ap.add_argument("--skip", type=int, default=0, help="skip the first N selected frames")
    ap.add_argument("--strip-vlan", action="store_true", help="remove 802.1Q/802.1ad tags (hardware cannot parse them)")
    ap.add_argument("--keep-all", action="store_true",
                    help="keep all non-fragmented frames (other traffic too) so the hardware filter is exercised")
    a = ap.parse_args()

    if not os.path.isfile(a.capture):
        sys.exit(f"capture file not found: {a.capture}\n(give the path to a real .pcap/.pcapng file; 'capture.pcapng' in the docs is only a placeholder)")
    frames, lt = read_capture(a.capture)
    if lt != 1: sys.exit(f"link type {lt} not supported (need Ethernet = 1)")
    total = len(frames)
    frames = [(d, o) for d, o in frames]
    trunc = sum(1 for d, o in frames if len(d) < o)
    frames = [d for d, o in frames if len(d) >= o]
    if a.strip_vlan: frames = [strip_vlan(f) for f in frames]
    print(f"capture: {total} frames, {trunc} truncated (dropped)")

    groups = collections.Counter(k for k in map(udp_key, frames) if k and 224 <= (k[0] >> 24) <= 239)
    if a.group:
        ip, port = a.group.rsplit(":", 1)
        group = (gen.ip2int(ip), int(port))
    elif groups:
        group = groups.most_common(1)[0][0]
    else:
        sys.exit("no multicast UDP traffic found; pass --group IP:PORT")
    print("multicast groups seen: " + ", ".join(f"{ip_str(k[0])}:{k[1]} x{v}" for k, v in groups.most_common(5)))
    print(f"selected group       : {ip_str(group[0])}:{group[1]}")
    gen.MC_IP, gen.MC_PORT = ip_str(group[0]), group[1]            # golden() reads these globals

    if a.keep_all:
        # everything except IPv4 fragments (the hardware has no reassembly)
        sel = [f for f in frames if len(f) >= 14 and not (
            f[12:14] == b"\x08\x00" and len(f) >= 22 and struct.unpack(">H", f[20:22])[0] & 0x3FFF)]
    else:
        sel = [f for f in frames if udp_key(f) == group]
    sel = sel[a.skip:]

    out, words = [], 0
    for fr in sel:
        nw = (len(fr) + 3) // 4
        if words + nw > a.max_words: break
        out.append(fr); words += nw
    if not out: sys.exit("no frames fit the budget / matched the selection")
    print(f"selected {len(out)} of {len(sel)} frames -> {words} words (budget {a.max_words})")

    stats = dict(pkt_in=0, pkt_pass=0, msgs=0, bad=0, unk=0); events = []; lines = []
    for fr in out:
        gen.golden(fr, stats, events)
        pad = fr + bytes((-len(fr)) % 4)
        w = [struct.unpack(">I", pad[i:i + 4])[0] for i in range(0, len(pad), 4)]
        lines += ["%d%08x" % (1 if i == len(w) - 1 else 0, x) for i, x in enumerate(w)]
    chk = gen.checksum(events)
    aw = max(4, math.ceil(math.log2(len(lines))))
    for k in ("pkt_in", "pkt_pass", "msgs", "bad", "unk"):
        if stats[k] > 0xFFFF: sys.exit(f"counter {k}={stats[k]} exceeds the 16-bit hardware counter; lower --max-words")

    for d in ("fpga", "sim", "rtl"): os.makedirs(os.path.join(a.out, d), exist_ok=True)
    open(os.path.join(a.out, "fpga/replay.mem"), "w").write("\n".join(lines) + "\n")
    open(os.path.join(a.out, "sim/events_expected.txt"), "w").write("".join(gen.ev_line(e) + "\n" for e in events))
    with open(os.path.join(a.out, "rtl/build_params.svh"), "w") as f:
        f.write(f"// generated by scripts/pcap_to_replay.py from {os.path.basename(a.capture)} -- do not edit\n")
        f.write(f"localparam integer N_WORDS = {len(lines)};\nlocalparam integer AW_MEM = {aw};\n")
        f.write(f"localparam [31:0] CFG_IP = 32'h{group[0]:08x};\nlocalparam [15:0] CFG_PORT = 16'd{group[1]};\n")
        f.write(f"localparam [15:0] EXP_PKT_IN = 16'd{stats['pkt_in']};\nlocalparam [15:0] EXP_PKT_PASS = 16'd{stats['pkt_pass']};\n")
        f.write(f"localparam [15:0] EXP_MSGS = 16'd{stats['msgs']};\nlocalparam [15:0] EXP_BAD = 16'd{stats['bad']};\n")
        f.write(f"localparam [15:0] EXP_UNK = 16'd{stats['unk']};\nlocalparam [31:0] EXP_EVENTS = 32'd{len(events)};\n")
        f.write(f"localparam [31:0] EXP_CHK = 32'h{chk:08x};\n")
    print(f"frames={stats['pkt_in']} words={len(lines)} AW={aw} pass={stats['pkt_pass']} msgs={stats['msgs']} "
          f"bad={stats['bad']} unk={stats['unk']} events={len(events)} chk={chk:08x}")
    if aw > 13: print(f"NOTE: AW_MEM={aw} -> {2 ** aw}-word replay memory ({max(1, 33 * 2 ** aw // 36864)}+ RAMB36); re-check timing at 320 MHz.")
    survey(out, group)


if __name__ == "__main__":
    main()