#!/usr/bin/env python3
"""MDP3-style traffic generator + golden decoder.

Writes:
  fpga/replay.mem          one 33-bit word per line: {last, data[31:0]} (9 hex digits)
  sim/events_expected.txt  golden events, same text format the testbench dumps
  rtl/build_params.svh     N_WORDS / AW_MEM / expected counters + checksum

The golden decoder parses the raw frame BYTES (struct.unpack), independent of the
generator's construction path. Layout is MODELED ON MDP 3.0 / SBE, not byte-exact
CME: check field offsets against the CME schema XML before pointing at real data.
"""
import argparse, random, struct, math, sys

M32 = 0xFFFFFFFF
MC_IP, MC_PORT = "224.0.31.1", 14310          # placeholder multicast group
TEMPLATES = {46: "book", 48: "trade"}
ENTRY = struct.Struct("<qiiIiBBB5x")           # px qty secid rptseq norders level action type
ROOT = struct.Struct("<QB2x")                  # transact_time, match_event_ind, 2B reserved
assert ENTRY.size == 32 and ROOT.size == 11

def ip2int(s): a, b, c, d = map(int, s.split(".")); return (a << 24) | (b << 16) | (c << 8) | d

def ip_checksum(h):
    s = sum(struct.unpack(">10H", h)); s = (s & 0xFFFF) + (s >> 16); s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

# ---------------------------------------------------------------- construction
def make_msg(rng, tmpl, n):
    body = b""
    for _ in range(n):
        if tmpl == 46:
            et, lvl, act = rng.choice([ord("0"), ord("1")]), rng.randint(1, 10), rng.randint(0, 5)
        else:
            et, lvl, act = ord("2"), rng.randint(0, 2), rng.randint(0, 1)   # level byte = aggressor side
        body += ENTRY.pack(rng.randint(-5000, 4_000_000_000), rng.randint(1, 5000), rng.randint(1, 60000),
                           rng.randint(1, 2**31), rng.randint(1, 40), lvl, act, et)
    root = ROOT.pack(rng.getrandbits(63), rng.choice([0, 1, 4, 128]))
    pre = struct.pack("<HHHH", 11, tmpl, 9, rng.randint(0, 3)) + root + struct.pack("<HB", 32, n)
    msg = struct.pack("<H", 2 + len(pre) + len(body)) + pre + body
    assert len(msg) % 4 == 0
    return msg

def make_unknown(rng):
    words = rng.randint(3, 12)
    return struct.pack("<HHHHH", words * 4, 11, rng.choice([32, 99, 4]), 9, 0) + bytes(rng.getrandbits(8) for _ in range(words * 4 - 10))

def make_bad(rng):
    return struct.pack("<H", 26) + bytes(rng.getrandbits(8) for _ in range(26))   # size%4 != 0 -> desync

def mdp_payload(rng, seq, kind="good"):
    p = struct.pack("<IQ", seq, rng.getrandbits(63))
    for _ in range(rng.randint(1, 4)):
        r = rng.random()
        if r < 0.12: p += make_unknown(rng)
        else:
            t = rng.choice([46, 46, 48])
            p += make_msg(rng, t, rng.randint(1, 8))
    if kind == "bad": p += make_bad(rng)
    assert len(p) % 4 == 0
    return p

def make_frame(rng, payload, dip=MC_IP, dport=MC_PORT, etype=0x0800, proto=17):
    eth = bytes([0x01, 0x00, 0x5E, 0x00, 0x1F, 0x01, 0x00, 0x1B, 0x21, 0xAA, 0xBB, 0xCC]) + struct.pack(">H", etype)
    ulen = 8 + len(payload)
    ip = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + ulen, rng.getrandbits(16), 0x4000, 64, proto, 0,
                     bytes([10, 1, 2, 3]), struct.pack(">I", ip2int(dip)))
    ip = ip[:10] + struct.pack(">H", ip_checksum(ip)) + ip[12:]
    udp = struct.pack(">HHHH", 40000, dport, ulen, 0)
    f = eth + ip + udp + payload
    return f + bytes(max(0, 60 - len(f)))

# ---------------------------------------------------------------- golden decode
def golden(frame, stats, events):
    stats["pkt_in"] += 1
    if len(frame) < 42: return
    et = struct.unpack(">H", frame[12:14])[0]; vihl = frame[14]; proto = frame[23]
    dip = struct.unpack(">I", frame[30:34])[0]; dport, ulen = struct.unpack(">HH", frame[36:40])
    if not (et == 0x0800 and vihl == 0x45 and proto == 17 and dip == ip2int(MC_IP) and dport == MC_PORT
            and ulen % 4 == 0 and ulen >= 20):
        return
    stats["pkt_pass"] += 1
    pl = frame[42:42 + ulen - 8]; L = len(pl)
    seq = struct.unpack("<I", pl[0:4])[0]
    off = 12
    while off < L:
        if off + 4 > L: stats["bad"] += 1; return
        size = struct.unpack("<H", pl[off:off + 2])[0]
        if size % 4 or size < 12: stats["bad"] += 1; return
        if off + size > L: stats["bad"] += 1; return
        stats["msgs"] += 1
        m = pl[off:off + size]
        tid = struct.unpack("<H", m[4:6])[0]
        if tid not in TEMPLATES or size < 24:
            stats["unk"] += 1
        else:
            tt, mei = struct.unpack("<QB", m[10:19])
            ngrp = m[23]
            for i in range(ngrp):
                b = 24 + 32 * i
                if b + 28 > size: break
                px, qty, sec, rpt, nord, lvl, act, etp = struct.unpack("<qiiIiBBB", m[b:b + 27])
                events.append(dict(tmpl=tid, seq=seq, tt=tt, sec=sec, px=px, qty=qty, rpt=rpt, nord=nord,
                                   lvl=lvl, act=act, etp=etp, mei=mei))
        off += size

def ev_line(e):
    return "%d %d %d %d %d %d %d %d %d %d %d %d" % (e["tmpl"], e["seq"], e["tt"], e["sec"], e["px"], e["qty"],
                                                     e["rpt"], e["nord"], e["lvl"], e["act"], e["etp"], e["mei"])

def checksum(events):
    c = 0
    for e in events:
        px = e["px"] & 0xFFFFFFFFFFFFFFFF
        mix = ((e["sec"] ^ e["qty"] ^ (px & M32) ^ (px >> 32) ^ e["rpt"] ^ e["nord"] ^ e["seq"] ^
                (e["tt"] & M32) ^ (e["tt"] >> 32)) & M32)
        mix ^= (e["tmpl"] << 16) | (e["lvl"] << 8) | e["act"]
        mix ^= (e["etp"] << 24) | (e["mei"] << 16)
        c = (((c << 1) | (c >> 31)) & M32) ^ (mix & M32)
    return c

# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max-words", type=int, default=4000)
    ap.add_argument("--out", default=".")
    a = ap.parse_args()
    rng = random.Random(a.seed)

    frames, words, seq = [], 0, 1000
    while True:
        r = rng.random()
        if   r < 0.70: fr = make_frame(rng, mdp_payload(rng, seq)); seq += 1
        elif r < 0.76: fr = make_frame(rng, mdp_payload(rng, seq, "bad")); seq += 1
        elif r < 0.84: fr = make_frame(rng, mdp_payload(rng, seq), dport=MC_PORT + 1)
        elif r < 0.90: fr = make_frame(rng, mdp_payload(rng, seq), dip="224.0.31.2")
        elif r < 0.94: fr = make_frame(rng, mdp_payload(rng, seq), etype=0x0806)
        elif r < 0.97: fr = make_frame(rng, mdp_payload(rng, seq), proto=6)
        else:          fr = make_frame(rng, mdp_payload(rng, seq) + b"\x01\x02")      # len % 4 == 2
        nw = (len(fr) + 3) // 4
        if words + nw > a.max_words: break
        frames.append(fr); words += nw

    stats = dict(pkt_in=0, pkt_pass=0, msgs=0, bad=0, unk=0); events = []
    lines = []
    for fr in frames:
        golden(fr, stats, events)
        pad = fr + bytes((-len(fr)) % 4)
        w = [struct.unpack(">I", pad[i:i + 4])[0] for i in range(0, len(pad), 4)]
        lines += ["%d%08x" % (1 if i == len(w) - 1 else 0, x) for i, x in enumerate(w)]
    chk = checksum(events)
    aw = max(4, math.ceil(math.log2(len(lines))))

    open(f"{a.out}/fpga/replay.mem", "w").write("\n".join(lines) + "\n")
    open(f"{a.out}/sim/events_expected.txt", "w").write("".join(ev_line(e) + "\n" for e in events))
    with open(f"{a.out}/rtl/build_params.svh", "w") as f:
        f.write("// generated by scripts/gen_mdp3.py -- do not edit\n")
        f.write(f"localparam integer N_WORDS = {len(lines)};\nlocalparam integer AW_MEM = {aw};\n")
        f.write(f"localparam [31:0] CFG_IP = 32'h{ip2int(MC_IP):08x};\nlocalparam [15:0] CFG_PORT = 16'd{MC_PORT};\n")
        f.write(f"localparam [15:0] EXP_PKT_IN = 16'd{stats['pkt_in']};\nlocalparam [15:0] EXP_PKT_PASS = 16'd{stats['pkt_pass']};\n")
        f.write(f"localparam [15:0] EXP_MSGS = 16'd{stats['msgs']};\nlocalparam [15:0] EXP_BAD = 16'd{stats['bad']};\n")
        f.write(f"localparam [15:0] EXP_UNK = 16'd{stats['unk']};\nlocalparam [31:0] EXP_EVENTS = 32'd{len(events)};\n")
        f.write(f"localparam [31:0] EXP_CHK = 32'h{chk:08x};\n")
    print(f"frames={stats['pkt_in']} words={len(lines)} AW={aw} pass={stats['pkt_pass']} msgs={stats['msgs']} "
          f"bad={stats['bad']} unk={stats['unk']} events={len(events)} chk={chk:08x}")

if __name__ == "__main__":
    main()
