// Cut-through Ethernet/IPv4/UDP header strip + 2-byte realign.
// Input : 32-bit words, byte0 in [31:24] (network order), no FCS, one word/cycle.
// Output: UDP payload as 32-bit aligned words. Payload starts at frame byte 42
//         (= word 10, byte offset 2), so out word j = {w(10+j)[15:0], w(11+j)[31:16]}.
// The accept/drop decision is made from header words 3..9, i.e. BEFORE the first
// payload word arrives, so nothing is buffered (no store-and-forward).
// Only payloads whose length is a multiple of 4 are passed (MDP3 packets are).
module udp_strip (
  input  logic        clk,
  input  logic        rst,
  input  logic [31:0] cfg_ip,      // multicast dst IP
  input  logic [15:0] cfg_port,    // UDP dst port
  input  logic [15:0] ts_cnt,      // free-running cycle counter
  input  logic        s_valid,
  input  logic [31:0] s_data,
  input  logic        s_last,
  output logic        m_valid,
  output logic [31:0] m_data,
  output logic        m_sof,
  output logic        m_last,
  output logic [15:0] m_ts,        // ts_cnt captured at frame word 0
  output logic        evt_frame,   // pulse: frame seen
  output logic        evt_pass     // pulse: frame accepted
);
  logic [3:0]  wc;                 // word index, saturates at 11
  logic [15:0] prev;   // only the low half is ever used (2-byte payload offset)
  logic        ok_eth, ok_proto, ip_hi_ok, ok_ip, ok_port, len_ok;
  logic        active, first;
  logic [15:0] udp_len, frame_ts;
  logic [13:0] nw;                 // payload words still to emit

  wire pass_now = ok_eth & ok_proto & ok_ip & ok_port & len_ok;

  always_ff @(posedge clk) begin
    m_valid   <= 1'b0;
    m_sof     <= 1'b0;
    m_last    <= 1'b0;
    evt_frame <= 1'b0;
    evt_pass  <= 1'b0;
    if (rst) begin
      wc     <= 4'd0;
      active <= 1'b0;
    end else if (s_valid) begin
      prev <= s_data[15:0];
      if (wc != 4'd11) wc <= wc + 4'd1;
      case (wc)
        4'd0: frame_ts <= ts_cnt;
        4'd3: ok_eth   <= (s_data[31:16] == 16'h0800) && (s_data[15:8] == 8'h45);
        4'd5: ok_proto <= (s_data[7:0] == 8'd17);
        4'd7: ip_hi_ok <= (s_data[15:0] == cfg_ip[31:16]);
        4'd8: ok_ip    <= ip_hi_ok && (s_data[31:16] == cfg_ip[15:0]);
        4'd9: begin
          ok_port <= (s_data[31:16] == cfg_port);
          udp_len <= s_data[15:0];
          len_ok  <= (s_data[1:0] == 2'b00) && (s_data[15:0] >= 16'd20);
        end
        4'd10: begin
          active   <= pass_now;
          evt_pass <= pass_now;
          nw       <= 14'((udp_len - 16'd8) >> 2);
          first    <= 1'b1;
        end
        4'd11: begin
          if (active) begin
            m_valid <= 1'b1;
            m_data  <= {prev, s_data[31:16]};
            m_sof   <= first;
            m_last  <= (nw == 14'd1);
            m_ts    <= frame_ts;
            first   <= 1'b0;
            nw      <= nw - 14'd1;
            if (nw == 14'd1) active <= 1'b0;
          end
        end
        default: ;
      endcase
      if (s_last) begin
        wc        <= 4'd0;
        active    <= 1'b0;
        evt_frame <= 1'b1;
      end
    end
  end
endmodule