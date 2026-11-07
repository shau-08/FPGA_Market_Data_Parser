// Parser core (single clock domain, target 320+ MHz): strip -> decode -> stats.
// Free-running 16-bit cycle counter stamps each frame's first word; latency is
// measured from that stamp to the cycle ev_valid is visible.
module mdp_parser_top (
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,          // clears stats (pulse)
  input  logic [31:0] cfg_ip,
  input  logic [15:0] cfg_port,
  input  logic        s_valid,
  input  logic [31:0] s_data,
  input  logic        s_last,
  output logic        ev_valid,
  output logic [15:0] ev_tmpl,
  output logic [31:0] ev_seq,
  output logic [63:0] ev_ttime,
  output logic [31:0] ev_secid,
  output logic [63:0] ev_px,
  output logic [31:0] ev_qty,
  output logic [31:0] ev_rpt,
  output logic [31:0] ev_nord,
  output logic [7:0]  ev_level,
  output logic [7:0]  ev_action,
  output logic [7:0]  ev_type,
  output logic [7:0]  ev_mei,
  output logic [15:0] ev_ts,
  output logic [15:0] st_pkt_in,
  output logic [15:0] st_pkt_pass,
  output logic [15:0] st_msgs,
  output logic [15:0] st_bad,
  output logic [15:0] st_unk,
  output logic [31:0] st_events,
  output logic [31:0] st_chk,
  output logic [15:0] st_lat_min,
  output logic [15:0] st_lat_max,
  output logic [15:0] st_lat_last
);
  // clear arrives from a high-fanout control path; register it (stats are only
  // consumed >= 3 cycles after start, so one extra cycle is harmless)
  logic clear_q;
  always_ff @(posedge clk) clear_q <= clear;

  logic [15:0] ts_cnt;
  always_ff @(posedge clk) ts_cnt <= rst ? 16'd0 : ts_cnt + 16'd1;

  logic        p_valid, p_sof, p_last, evt_frame, evt_pass;
  logic [31:0] p_data;
  logic [15:0] p_ts;
  logic        msg_pulse, unk_pulse, bad_pulse;

  udp_strip u_strip (
    .clk, .rst, .cfg_ip, .cfg_port, .ts_cnt,
    .s_valid, .s_data, .s_last,
    .m_valid(p_valid), .m_data(p_data), .m_sof(p_sof), .m_last(p_last), .m_ts(p_ts),
    .evt_frame, .evt_pass);

  mdp_decode u_dec (
    .clk, .rst,
    .m_valid(p_valid), .m_data(p_data), .m_sof(p_sof), .m_last(p_last), .m_ts(p_ts),
    .ev_valid, .ev_tmpl, .ev_seq, .ev_ttime, .ev_secid, .ev_px, .ev_qty, .ev_rpt,
    .ev_nord, .ev_level, .ev_action, .ev_type, .ev_mei, .ev_ts,
    .msg_pulse, .unk_pulse, .bad_pulse);

  // checksum over every field of every event (mirrored in gen_mdp3.py).
  // Pipelined: stage 1 registers two partial XORs, stage 2 folds them into st_chk.
  logic [31:0] mix_a, mix_b;
  logic        ev_v1;
  always_ff @(posedge clk) begin
    mix_a <= ev_secid ^ ev_qty ^ ev_px[31:0] ^ ev_px[63:32] ^ ev_rpt ^ ev_nord;
    mix_b <= ev_seq ^ ev_ttime[31:0] ^ ev_ttime[63:32] ^
             {ev_tmpl, ev_level, ev_action} ^ {ev_type, ev_mei, 16'h0000};
    ev_v1 <= ev_valid;
  end

  // Latency stats are pipelined: stage 1 subtracts, stage 2 compares (registered
  // flags), stage 3 updates min/max. Events are >= 4 cycles apart, so the one-cycle
  // stale compare against min/max can never matter.
  logic [15:0] lat_r, lat_r2;
  logic        lat_v2, lat_lt, lat_gt;   // lat_v == ev_v1
  always_ff @(posedge clk) begin
    lat_r  <= ts_cnt - ev_ts;
    lat_r2 <= lat_r;
    lat_v2 <= ev_v1;
    lat_lt <= (lat_r < st_lat_min);
    lat_gt <= (lat_r > st_lat_max);
    if (rst || clear_q) begin
      st_pkt_in <= '0; st_pkt_pass <= '0; st_msgs <= '0; st_bad <= '0; st_unk <= '0;
      st_events <= '0; st_chk <= '0;
      st_lat_min <= 16'hFFFF; st_lat_max <= '0; st_lat_last <= '0;
    end else begin
      if (evt_frame) st_pkt_in   <= st_pkt_in + 16'd1;
      if (evt_pass)  st_pkt_pass <= st_pkt_pass + 16'd1;
      if (msg_pulse) st_msgs     <= st_msgs + 16'd1;
      if (bad_pulse) st_bad      <= st_bad + 16'd1;
      if (unk_pulse) st_unk      <= st_unk + 16'd1;
      if (ev_v1) begin
        st_events <= st_events + 32'd1;
        st_chk    <= {st_chk[30:0], st_chk[31]} ^ mix_a ^ mix_b;
      end
      if (lat_v2) begin
        st_lat_last <= lat_r2;
        if (lat_lt) st_lat_min <= lat_r2;
        if (lat_gt) st_lat_max <= lat_r2;
      end
    end
  end
endmodule