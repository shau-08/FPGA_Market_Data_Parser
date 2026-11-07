# mdp3-parser

A line-rate market-data parser for CME MDP 3.0-style (SBE) feeds, written in SystemVerilog and running at **320.83 MHz** on a Digilent **Basys 3** (Artix-7 XC7A35T-1). Timing is closed in Vivado and the design has been programmed and self-checked on the board.

The datapath is 32 bits wide, one word per cycle, with no backpressure. It is cut-through: nothing is buffered between the Ethernet header and the decoded event. At 320 MHz that is 10.24 Gb/s of 32-bit words, the 10G word rate.

> **The "wire" is a BRAM replay of a stored frame stream.** A Basys 3 has no 10G input, so frames are replayed from block RAM at full clock rate. Packet and message framing has been checked against a real CME capture, but the book/trade message layout is modeled on MDP 3.0 / SBE and is **not yet verified against real market-data messages** (see [Validation against real data](#validation-against-real-data) and [Limitations](#limitations)).

```
 BRAM replay ──► udp_strip ──► mdp_decode ──► events + stats ──► UART (100 MHz domain)
  (320 MHz)      Eth/IP/UDP    SBE framer,     checksum, counters,
                 filter +      template ROM,   latency min/max
                 realign       repeating group
```

## Results

Post-route, Vivado 2025.2, `xc7a35tcpg236-1`, 320.83 MHz (962.5 MHz VCO / 3):

| Check | Result |
|---|---|
| Setup WNS | **+0.008 ns**, 0 of 2429 endpoints failing |
| Hold WHS | +0.018 ns, 0 failing |
| Pulse width WPWS | +0.541 ns, 0 failing |
| Constraints | All user-specified timing constraints met |

| Resource | Used | Available | Util. |
|---|---:|---:|---:|
| Slice LUTs | 702 | 20,800 | 3.38 % |
| Slice registers | 1,350 | 41,600 | 3.25 % |
| Block RAM (RAMB36) | 4 | 50 | 8.00 % |
| DSP48 | 0 | 90 | 0 % |
| MMCM | 1 | 5 | 20 % |

Estimated on-chip power: 0.241 W (0.169 W dynamic, 0.072 W static). Full reports are in [`reports/`](reports/).

**Board result:** the replay produces 282 events with checksum `CHK=2072055F`, all counters match, LED2 (PASS) lights and the UART line ends in `OK`.

> **Margin is thin.** +0.008 ns setup slack is a genuine pass, but a different seed or a small RTL change can move it by 0.1 ns or more. If you edit the design and it fails, try the `Performance_ExplorePostRoutePhysOpt` strategy, or drop `CLKFBOUT_MULT_F` in `rtl/basys3_top.sv` from 9.625 to 9.375 (312.5 MHz) for roughly 0.1 ns of real margin.

## How it works

| Module | Role |
|---|---|
| `basys3_top` | Harness: MMCM (100 → 320.83 MHz), per-domain resets, start trigger, pass/fail check, UART report, LEDs |
| `replay_engine` | Streams the stored frame words out of BRAM (`fpga/replay.mem`) |
| `mdp_parser_top` | Connects strip and decode, accumulates stats, checksum and latency min/max |
| `udp_strip` | Ethernet/IPv4/UDP filter and 2-byte realign. Accept/drop is decided from header words 3 to 9, before the first payload word arrives |
| `mdp_decode` | SBE decoder: packet header, message framing, template check, repeating-group entries. Emits one event per entry |
| `tmpl_rom` | Registered templateId → supported lookup (46 book, 48 trade summary) |
| `uart_tx` | 8N1 serial transmitter, 115200 baud at 100 MHz |

**Frame types handled:** valid MDP packets pass; frames with the wrong port, wrong multicast IP, non-IPv4 ethertype, TCP, odd UDP length, unknown templates, or a malformed message size are counted and dropped. After a malformed message the decoder resyncs at the next packet.

**Event fields:** template, packet sequence number, transact time, security ID, price, quantity, report sequence, number of orders, level, action, entry type, match-event indicator, and an arrival timestamp.

### What it took to reach 320 MHz

These changes were made over several rounds of working through the worst paths:

- Pipelined the replay BRAM address.
- Event registers load every cycle with no clock enable.
- Registered last-word flag (`last_w`) on the `rem` counter.
- Pipelined the latency min/max compare and the event checksum.
- Registered the `clear` signal.
- Split `mdp_decode` into a control stage (registered one-hot write strobes) and a capture stage, so no decode logic sits in front of the wide clock enables.

Event counts and checksum are identical to the original design in simulation. Event latency is a few cycles longer, which only shows in the LMIN/LMAX numbers.

## Repository layout

```
rtl/       SystemVerilog sources + build_params.svh (generated)
tb/        testbenches: tb_parser (core vs. golden), tb_top (full harness, stub MMCM)
scripts/   gen_mdp3.py (generator + golden model), pcap_to_replay.py, run_sim.sh, ooc_synth.tcl
fpga/      basys3.xdc, replay.mem
reports/   Vivado post-route timing, utilization and power reports
sim/       simulation output (generated, not tracked)
```

## Simulation

Needs `iverilog` and `python3`. From the repo root:

```
scripts/run_sim.sh [seed] [max_words]
```

This generates a mixed frame stream, runs the parser, diffs every RTL event field against the golden decoder in `gen_mdp3.py`, checks all counters and the checksum, then runs the whole Basys 3 harness (stub MMCM) and decodes the UART line. The generated traffic includes the bad-frame types listed above. Set `SKIP_GEN=1` to keep an existing `replay.mem` and `build_params.svh`, for example ones produced by `pcap_to_replay.py`.

## Building for the board

1. Create a Vivado project for part `xc7a35tcpg236-1` (board: Digilent Basys 3).
2. Add everything in `rtl/` as design sources (top: `basys3_top`) and `fpga/basys3.xdc` as constraints.
3. Add `fpga/replay.mem` as a memory/data file.
4. Run synthesis, implementation and bitstream generation. For a quick parser-only Fmax check without pins, use `vivado -mode batch -source scripts/ooc_synth.tcl -tclargs 3.125`.
5. Program the board. A run starts automatically about 20 ms after reset.

### Reading the board

| Control / indicator | Meaning |
|---|---|
| `btnC` | Replay again |
| `btnR` | Reset |
| LED0 | MMCM locked |
| LED1 | Replay done |
| LED2 | PASS: all counters and checksum match `build_params.svh` |
| LED3 | FAIL |
| LED15:8 | Low byte of minimum latency |

Open the Basys 3 USB-UART port at 115200 8N1. After each run it prints one line:

```
PKT=0024 PS=001C MSG=0042 EV=0000011A BAD=0001 UNK=0008 CHK=2072055F LMIN=.... LMAX=.... OK
```

(all values hex; PKT, PS, MSG, BAD, UNK = packets in, passed, messages, bad, unknown template.)

## Using a real capture

```
python scripts/pcap_to_replay.py capture.pcapng
python scripts/pcap_to_replay.py capture.pcap --group 224.0.31.1:14310 --max-words 8192
python scripts/pcap_to_replay.py capture.pcap --strip-vlan --keep-all
```

This regenerates `fpga/replay.mem`, `rtl/build_params.svh` and the golden events from your capture, and prints a layout survey (template and schema histogram, root and group block lengths). If the survey shows layouts that differ from the model, `mdp_decode.sv` needs to change. Rebuild the bitstream after regenerating, since `build_params.svh` is compiled in.

Note that a board PASS compares the RTL to the **same model** the script uses, so it proves "RTL == model", not "RTL == CME". For an independent check, decode the same pcap with a separate tool such as `sbedecoder` and compare events.

## Validation against real data

| Level | Status |
|---|---|
| RTL vs. independent Python golden model (synthetic traffic, several seeds) | Passed, in simulation and on the board |
| Packet and message framing vs. a real CME Globex capture | Confirmed (see below) |
| Book (46) and trade (48) message layouts vs. real data | **Not yet verified** |
| Hardware events vs. an independent decoder (e.g. `sbedecoder`) on real data | **Not yet done** |

**Real capture check.** A real Globex MDP 3.0 pcap (760 Ethernet frames, 38 multicast groups, 2023-07-16 13:30 UTC) was run through `pcap_to_replay.py`. The capture was taken outside trading hours and holds only heartbeat messages. It confirmed:

- Packet header: `MsgSeqNum` u32 and `SendingTime` u64 (epoch nanoseconds, consistent with the pcap timestamps), both little-endian.
- Message header: `MsgSize` (includes itself), `blockLength`, `templateId`, `schemaId` = 1, `version` = 9, all u16 little-endian.
- The pcap reader handles real nanosecond Ethernet captures and detects the multicast groups.

It also exposed a gap: heartbeat packets carry a 22-byte UDP payload, which is not a multiple of 4, so `udp_strip` drops them rather than decoding them. Book and trade messages are padded to multiples of 8 and are unaffected. The capture contains no incremental book or trade messages, so those layouts remain unchecked. The capture itself is not included in this repository.

## Limitations

- **Book/trade layout not verified on real data.** Template IDs 46/48, the 11-byte root block, the 3-byte group header and 32-byte entries are modeled on MDP 3.0 / SBE. Check them against the CME schema XML and a capture that contains incremental messages before claiming compatibility.
- Only synthetic traffic has been decoded on hardware. The real capture tested so far held heartbeats only.
- Heartbeat packets (payload not a multiple of 4 bytes) are dropped, not decoded.
- A real channel carries many templates besides 46 and 48; expect a high unknown-template count on live captures.
- Message sizes and UDP payload length must be multiples of 4. No VLAN (use `--strip-vlan`), IP options or fragmentation.
- Two templates supported; add rows to `tmpl_rom.sv` for others that share the entry layout.
- Replay memory holds 3,986 words (4 BRAM36 tiles); there is no live input.
- Not built: A/B feed arbiter, order book, latency histogram, AXI/PS path.
- Going well beyond ~330 MHz on a -1 part needs every path at two LUT levels or fewer, and the BRAM (~388 MHz) and clock buffers start to limit. The `rem`, `nw` and `st_events` counters and the `udp_strip` header compare are the next candidates.

## License

No license is set yet. Add a `LICENSE` file (MIT is a common choice) before publishing.
