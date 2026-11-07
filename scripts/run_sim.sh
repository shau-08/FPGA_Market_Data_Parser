#!/bin/sh
# usage: scripts/run_sim.sh [seed] [max_words]   (run from repo root; needs iverilog + python3)
set -e
# SKIP_GEN=1 keeps the existing replay.mem/build_params.svh (e.g. produced by scripts/pcap_to_replay.py)
[ -n "$SKIP_GEN" ] || python3 scripts/gen_mdp3.py --seed "${1:-1}" --max-words "${2:-4000}" --out .
iverilog -g2012 -I rtl -o sim/tb.vvp rtl/udp_strip.sv rtl/tmpl_rom.sv rtl/mdp_decode.sv rtl/mdp_parser_top.sv rtl/replay_engine.sv tb/tb_parser.sv
vvp -n sim/tb.vvp | tee sim/run.log
if diff -q sim/events_expected.txt sim/events_hw.txt >/dev/null; then echo "EVENT DIFF: identical ($(wc -l < sim/events_hw.txt) events)"; else echo "EVENT DIFF: MISMATCH"; diff sim/events_expected.txt sim/events_hw.txt | head; exit 1; fi
grep -q "TB RESULT: PASS" sim/run.log
# full-harness check (stubbed MMCM, UART line decoded): expects " OK" and LEDs=0111
iverilog -g2012 -I rtl -o sim/top.vvp tb/unisim_stub.v rtl/*.sv tb/tb_top.sv 2>/dev/null
(cd fpga && vvp -n ../sim/top.vvp | grep -a -E "PKT=|LEDs=")
