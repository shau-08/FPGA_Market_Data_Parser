`timescale 1ns/1ps
module tb_parser;
  `include "build_params.svh"
  logic clk = 0, rst = 1, start = 0;
  always #1.5625 clk = ~clk;                       // 320 MHz

  logic        r_valid, r_last, r_busy, r_done;
  logic [31:0] r_data;
  wire         go = start && !r_busy;

  replay_engine #(.AW(AW_MEM), .NWORDS(N_WORDS), .MEMFILE("fpga/replay.mem")) u_rp (
    .clk, .rst, .start(go), .valid(r_valid), .data(r_data), .last(r_last), .busy(r_busy), .done(r_done));

  logic        ev_valid;
  logic [15:0] ev_tmpl, ev_ts;
  logic [31:0] ev_seq, ev_secid, ev_qty, ev_rpt, ev_nord;
  logic [63:0] ev_ttime, ev_px;
  logic [7:0]  ev_level, ev_action, ev_type, ev_mei;
  logic [15:0] st_pkt_in, st_pkt_pass, st_msgs, st_bad, st_unk, st_lat_min, st_lat_max, st_lat_last;
  logic [31:0] st_events, st_chk;

  mdp_parser_top dut (
    .clk, .rst, .clear(go), .cfg_ip(CFG_IP), .cfg_port(CFG_PORT),
    .s_valid(r_valid), .s_data(r_data), .s_last(r_last),
    .ev_valid, .ev_tmpl, .ev_seq, .ev_ttime, .ev_secid, .ev_px, .ev_qty, .ev_rpt, .ev_nord,
    .ev_level, .ev_action, .ev_type, .ev_mei, .ev_ts,
    .st_pkt_in, .st_pkt_pass, .st_msgs, .st_bad, .st_unk, .st_events, .st_chk,
    .st_lat_min, .st_lat_max, .st_lat_last);

  integer fd, errs = 0;
  always @(posedge clk) if (ev_valid)
    $fdisplay(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", ev_tmpl, ev_seq, ev_ttime, ev_secid,
              $signed(ev_px), ev_qty, ev_rpt, ev_nord, ev_level, ev_action, ev_type, ev_mei);

  task chk16(input [127:0] name, input [15:0] got, input [15:0] exp);
    if (got !== exp) begin errs++; $display("MISMATCH %0s got=%0d exp=%0d", name, got, exp); end
  endtask

  initial begin
    fd = $fopen("sim/events_hw.txt", "w");
    repeat (10) @(posedge clk); rst = 0;
    repeat (4)  @(posedge clk); start = 1; @(posedge clk); start = 0;
    wait (r_done);
    repeat (40) @(posedge clk);
    $fclose(fd);
    chk16("pkt_in",   st_pkt_in,   EXP_PKT_IN);
    chk16("pkt_pass", st_pkt_pass, EXP_PKT_PASS);
    chk16("msgs",     st_msgs,     EXP_MSGS);
    chk16("bad",      st_bad,      EXP_BAD);
    chk16("unk",      st_unk,      EXP_UNK);
    if (st_events !== EXP_EVENTS) begin errs++; $display("MISMATCH events got=%0d exp=%0d", st_events, EXP_EVENTS); end
    if (st_chk    !== EXP_CHK)    begin errs++; $display("MISMATCH chk got=%08x exp=%08x", st_chk, EXP_CHK); end
    $display("STATS pkt_in=%0d pass=%0d msgs=%0d bad=%0d unk=%0d events=%0d chk=%08x lat_min=%0d lat_max=%0d (cycles, frame word0 -> event)",
             st_pkt_in, st_pkt_pass, st_msgs, st_bad, st_unk, st_events, st_chk, st_lat_min, st_lat_max);
    if (errs == 0) $display("TB RESULT: PASS"); else $display("TB RESULT: FAIL");
    $finish;
  end
  initial begin #20_000_000; $display("TB TIMEOUT"); $finish; end
endmodule
