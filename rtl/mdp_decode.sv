// MDP3-style SBE decoder. Input: word-aligned UDP payload (from udp_strip).
//   packet : MsgSeqNum u32 | SendingTime u64 | messages...   (all little-endian)
//   message: MsgSize u16 | SBE hdr (blockLen,templateId,schemaId,version u16) |
//            root block (11B: TransactTime u64, MatchEventIndicator u8, 2B rsvd) |
//            groupSize (blockLen u16, numInGroup u8) | entries (32B each)
//   entry  : px i64 | qty i32 | secid i32 | rptseq u32 | norders i32 |
//            level u8 | action u8 | entryType u8 | 5B pad
// Message sizes must be a multiple of 4 (they are 8-aligned in MDP3) so every
// message starts on a word boundary and field extraction is purely word-indexed.
// Two stages: stage A (control FSM) decodes each word into registered one-hot write
// strobes; stage B captures the (delayed) word into the wide data registers with
// those strobes as clock-enables, so no decode logic sits in front of 32-bit CEs.
// An event is emitted two cycles after the word holding level/action arrives.
module mdp_decode (
  input  logic        clk,
  input  logic        rst,
  input  logic        m_valid,
  input  logic [31:0] m_data,
  input  logic        m_sof,
  input  logic        m_last,
  input  logic [15:0] m_ts,
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
  output logic        msg_pulse,
  output logic        unk_pulse,
  output logic        bad_pulse
);
  function automatic [31:0] bs32(input [31:0] x);
    bs32 = {x[7:0], x[15:8], x[23:16], x[31:24]};
  endfunction

  logic [1:0]  hdr;      // packet-header words still to skip after sof
  logic [2:0]  mw;       // message word index (saturates at 6 = entry phase)
  logic [13:0] rem;      // words left in message after the current one
  logic        last_w;   // registered (rem == 1): current word is the message's last
  logic        skip;     // lost sync: ignore the rest of the packet
  logic [2:0]  ew;       // word index inside entry
  logic [7:0]  ent_left;
  logic [15:0] tmpl;
  logic        rom_valid;

  // stage-B capture registers
  logic [31:0] pkt_seq;
  logic [15:0] pkt_ts, tt_a, tt_c;
  logic [31:0] tt_b;
  logic [7:0]  mei;
  logic [31:0] px_lo, px_hi, qty_r, sec_r, rpt_r, nord_r;

  // stage A -> B: delayed data word and one-hot strobes
  logic [31:0] d_q;
  logic [15:0] ts_q;
  logic s_sof, s_tta, s_ttb, s_ttc, s_px0, s_px1, s_qty, s_sec, s_rpt, s_nord, s_ev;

  tmpl_rom u_rom (.clk(clk), .tid(tmpl), .valid(rom_valid));

  wire        end_msg  = (mw != 3'd0) && last_w;
  wire [13:0] sz_words = {m_data[23:16], m_data[31:26]};
  wire        sz_bad   = (m_data[25:24] != 2'b00) || (sz_words < 14'd3);
  wire        trunc    = m_last && !m_sof && !skip && ((hdr != 2'd0) || !end_msg);

  // ---------------- stage B: capture on registered strobes (no decode in the CE path)
  always_ff @(posedge clk) begin
    d_q  <= m_data;
    ts_q <= m_ts;
    if (s_sof) begin pkt_seq <= bs32(d_q); pkt_ts <= ts_q; end
    if (s_tta) tt_a <= d_q[15:0];
    if (s_ttb) tt_b <= d_q;
    if (s_ttc) begin tt_c <= d_q[31:16]; mei <= d_q[15:8]; end
    if (s_px0) px_lo  <= d_q;
    if (s_px1) px_hi  <= d_q;
    if (s_qty) qty_r  <= d_q;
    if (s_sec) sec_r  <= d_q;
    if (s_rpt) rpt_r  <= d_q;
    if (s_nord) nord_r <= d_q;
    // Event payload registers load EVERY cycle (no CE): only consumed while ev_valid.
    ev_tmpl   <= tmpl;
    ev_seq    <= pkt_seq;
    ev_ts     <= pkt_ts;
    ev_mei    <= mei;
    ev_ttime  <= {tt_c[7:0], tt_c[15:8], tt_b[7:0], tt_b[15:8],
                  tt_b[23:16], tt_b[31:24], tt_a[7:0], tt_a[15:8]};
    ev_px     <= {bs32(px_hi), bs32(px_lo)};
    ev_qty    <= bs32(qty_r);
    ev_secid  <= bs32(sec_r);
    ev_rpt    <= bs32(rpt_r);
    ev_nord   <= bs32(nord_r);
    ev_level  <= d_q[31:24];
    ev_action <= d_q[23:16];
    ev_type   <= d_q[15:8];
    ev_valid  <= s_ev;
  end

  // ---------------- stage A: control FSM
  always_ff @(posedge clk) begin
    msg_pulse <= 1'b0;
    unk_pulse <= 1'b0;
    bad_pulse <= 1'b0;
    {s_sof, s_tta, s_ttb, s_ttc, s_px0, s_px1, s_qty, s_sec, s_rpt, s_nord, s_ev} <= '0;
    if (rst) begin
      hdr <= 2'd0; mw <= 3'd0; skip <= 1'b1; ew <= 3'd0;
    end else if (m_valid) begin
      if (m_sof) begin
        s_sof   <= 1'b1;
        hdr     <= 2'd2;
        mw      <= 3'd0;
        ew      <= 3'd0;
        skip    <= 1'b0;
      end else if (hdr != 2'd0) begin
        hdr <= hdr - 2'd1;
      end else if (!skip) begin
        case (mw)
          3'd0: begin
            rem    <= sz_words - 14'd1;
            last_w <= (sz_words == 14'd2);   // rem would be 1
            if (sz_bad) begin
              skip <= 1'b1; bad_pulse <= 1'b1;
            end else begin
              mw <= 3'd1; msg_pulse <= 1'b1;
            end
          end
          3'd1: begin tmpl <= {m_data[23:16], m_data[31:24]}; mw <= 3'd2; end
          3'd2: begin s_tta <= 1'b1; mw <= 3'd3; end
          3'd3: begin s_ttb <= 1'b1; mw <= 3'd4; end
          3'd4: begin
            s_ttc <= 1'b1; mw <= 3'd5;
            if (!rom_valid) unk_pulse <= 1'b1;
          end
          3'd5: begin ent_left <= m_data[7:0]; ew <= 3'd0; mw <= 3'd6; end
          default: begin
            ew <= ew + 3'd1;
            case (ew)
              3'd0: s_px0  <= 1'b1;
              3'd1: s_px1  <= 1'b1;
              3'd2: s_qty  <= 1'b1;
              3'd3: s_sec  <= 1'b1;
              3'd4: s_rpt  <= 1'b1;
              3'd5: s_nord <= 1'b1;
              3'd6: if (rom_valid && ent_left != 8'd0) begin
                s_ev     <= 1'b1;
                ent_left <= ent_left - 8'd1;
              end
              default: ;
            endcase
          end
        endcase
        if (mw != 3'd0) begin
          if (last_w) begin                  // last word of this message
            mw <= 3'd0; ew <= 3'd0;
            if (mw < 3'd4) unk_pulse <= 1'b1; // too short to carry a known template
          end else begin
            rem    <= rem - 14'd1;
            last_w <= (rem == 14'd2);        // next rem == 1
          end
        end
      end
      if (trunc) bad_pulse <= 1'b1;
    end
  end
endmodule