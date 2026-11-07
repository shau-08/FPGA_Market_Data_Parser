// Basys 3 (XC7A35T-1) harness. clk100 -> MMCM -> 320 MHz parser domain.
//   BRAM replay @320MHz -> mdp_parser_top @320MHz -> stats -> (static CDC) -> UART @100MHz
// btnC = replay again, btnR = reset. A run auto-starts ~20 ms after reset.
// LEDs: 0 locked, 1 done, 2 PASS (all counters + checksum match build_params.svh), 3 FAIL.
module basys3_top #(parameter AUTO_DELAY = 2_000_000, parameter CLKS_PER_BIT = 868) (
  input  logic        clk,
  input  logic        btnC, btnR,
  output logic        uart_tx_pin,
  output logic [15:0] led
);
  `include "build_params.svh"

  // ---------------- clocks
  logic fb, fb_b, clk_f_u, clk_f, clk100, locked;
  BUFG u_bg100 (.I(clk), .O(clk100));
  MMCME2_BASE #(.BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1),
                .CLKFBOUT_MULT_F(9.625), .CLKOUT0_DIVIDE_F(3.0)) u_mmcm (   // 962.5 MHz VCO / 3 = 320.83 MHz (MULT_F must be a multiple of 0.125)
    .CLKIN1(clk), .CLKFBIN(fb_b), .CLKFBOUT(fb), .CLKOUT0(clk_f_u), .LOCKED(locked),
    .PWRDWN(1'b0), .RST(1'b0));
  BUFG u_bgfb (.I(fb), .O(fb_b));
  BUFG u_bgf  (.I(clk_f_u), .O(clk_f));

  // ---------------- resets: async assert, sync release, per domain
  wire rst_req = btnR | ~locked;
  (* ASYNC_REG = "TRUE" *) logic [3:0] rs100 = 4'hF, rsf = 4'hF;
  always_ff @(posedge clk100 or posedge rst_req) if (rst_req) rs100 <= 4'hF; else rs100 <= {rs100[2:0], 1'b0};
  always_ff @(posedge clk_f   or posedge rst_req) if (rst_req) rsf   <= 4'hF; else rsf   <= {rsf[2:0],   1'b0};
  wire rst_s = rs100[3], rst_f = rsf[3];

  // ---------------- slow domain: start trigger (button or auto)
  (* ASYNC_REG = "TRUE" *) logic [1:0] btn_sync;
  logic btn_d; logic [23:0] auto_cnt; logic auto_done; logic start_tog;
  wire  btn_rise = btn_sync[1] & ~btn_d;
  wire  auto_go  = !auto_done && (auto_cnt == AUTO_DELAY);
  always_ff @(posedge clk100) begin
    btn_sync <= {btn_sync[0], btnC};
    btn_d    <= btn_sync[1];
    if (rst_s) begin auto_cnt <= '0; auto_done <= 1'b0; start_tog <= 1'b0; end
    else begin
      if (!auto_done) auto_cnt <= auto_cnt + 24'd1;
      if (auto_go) auto_done <= 1'b1;
      if (btn_rise || auto_go) start_tog <= ~start_tog;
    end
  end

  // ---------------- fast domain
  (* ASYNC_REG = "TRUE" *) logic [2:0] tog_s;
  always_ff @(posedge clk_f) tog_s <= {tog_s[1:0], start_tog};
  wire start_f = tog_s[2] ^ tog_s[1];

  logic        r_valid, r_last, r_busy, r_done;
  logic [31:0] r_data;
  wire         go = start_f && !r_busy;

  replay_engine #(.AW(AW_MEM), .NWORDS(N_WORDS), .MEMFILE("replay.mem")) u_rp (
    .clk(clk_f), .rst(rst_f), .start(go), .valid(r_valid), .data(r_data), .last(r_last),
    .busy(r_busy), .done(r_done));

  logic        ev_valid;
  logic [15:0] ev_tmpl, ev_ts;
  logic [31:0] ev_seq, ev_secid, ev_qty, ev_rpt, ev_nord;
  logic [63:0] ev_ttime, ev_px;
  logic [7:0]  ev_level, ev_action, ev_type, ev_mei;
  logic [15:0] st_pkt_in, st_pkt_pass, st_msgs, st_bad, st_unk, st_lat_min, st_lat_max, st_lat_last;
  logic [31:0] st_events, st_chk;

  mdp_parser_top u_parser (
    .clk(clk_f), .rst(rst_f), .clear(go), .cfg_ip(CFG_IP), .cfg_port(CFG_PORT),
    .s_valid(r_valid), .s_data(r_data), .s_last(r_last),
    .ev_valid, .ev_tmpl, .ev_seq, .ev_ttime, .ev_secid, .ev_px, .ev_qty, .ev_rpt, .ev_nord,
    .ev_level, .ev_action, .ev_type, .ev_mei, .ev_ts,
    .st_pkt_in, .st_pkt_pass, .st_msgs, .st_bad, .st_unk, .st_events, .st_chk,
    .st_lat_min, .st_lat_max, .st_lat_last);

  // ---------------- slow domain: wait for done, then print stats (quasi-static after done)
  (* ASYNC_REG = "TRUE" *) logic [1:0] done_sync;
  logic done_d;
  always_ff @(posedge clk100) begin done_sync <= {done_sync[0], r_done}; done_d <= done_sync[1]; end
  wire done_rise = done_sync[1] & ~done_d;

  wire pass = (st_pkt_in == EXP_PKT_IN) && (st_pkt_pass == EXP_PKT_PASS) && (st_msgs == EXP_MSGS) &&
              (st_bad == EXP_BAD) && (st_unk == EXP_UNK) && (st_events == EXP_EVENTS) && (st_chk == EXP_CHK);

  function automatic [31:0] h4(input [15:0] v);
    integer i; reg [3:0] n;
    for (i = 0; i < 4; i = i + 1) begin n = v[4*(3-i) +: 4]; h4[8*(3-i) +: 8] = (n < 10) ? (8'h30 + n) : (8'h37 + n); end
  endfunction
  function automatic [63:0] h8(input [31:0] v);
    integer i; reg [3:0] n;
    for (i = 0; i < 8; i = i + 1) begin n = v[4*(7-i) +: 4]; h8[8*(7-i) +: 8] = (n < 10) ? (8'h30 + n) : (8'h37 + n); end
  endfunction

  wire [23:0] verdict = pass ? " OK" : " NG";
  wire [8*68-1:0] line_pre = {"PKT=", h4(st_pkt_in), " PS=", h4(st_pkt_pass), " MSG=", h4(st_msgs),
                              " EV=", h8(st_events), " BAD=", h4(st_bad), " UNK=", h4(st_unk), " CHK=", h8(st_chk)};
  wire [8*93-1:0] line = {line_pre, " LMIN=", h4(st_lat_min), " LMAX=", h4(st_lat_max), verdict, 16'h0D0A};
  localparam K = 93;   // chars in line (68 + 25); checked by scripts/run_sim.sh top-level run

  logic [1:0] pst; logic [6:0] pidx; logic [5:0] pw; logic [7:0] u_data; logic u_valid, u_ready;
  logic pass_r, fail_r;
  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (.clk(clk100), .rst(rst_s), .data(u_data), .valid(u_valid),
                                                 .ready(u_ready), .tx(uart_tx_pin));
  always_ff @(posedge clk100) begin
    u_valid <= 1'b0;
    if (rst_s) begin pst <= 2'd0; pass_r <= 1'b0; fail_r <= 1'b0; end
    else case (pst)
      2'd0: if (done_rise) begin pst <= 2'd1; pw <= '0; end
      2'd1: begin pw <= pw + 6'd1; if (pw == 6'd40) begin pst <= 2'd2; pidx <= '0; pass_r <= pass; fail_r <= ~pass; end end
      2'd2: if (u_ready && !u_valid) begin
              u_valid <= 1'b1; u_data <= line[8*(K-1-pidx) +: 8];
              if (pidx == K-1) pst <= 2'd0; else pidx <= pidx + 7'd1;
            end
      default: pst <= 2'd0;
    endcase
  end

  assign led = {st_lat_min[7:0], 4'b0, fail_r, pass_r, done_sync[1], locked};
endmodule