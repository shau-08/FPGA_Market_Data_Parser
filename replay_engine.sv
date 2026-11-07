// Replays a BRAM-held frame stream at 1 word/cycle (the stand-in for the 10G wire).
// mem word = {last, data[31:0]}. address reg + BRAM read + output reg => 3-cycle latency (valid is delayed to match).
// addr_q is a pure pipeline stage: Vivado absorbs it into the BRAM address capture,
// so the BRAM ADDR pins are driven straight from the addr flops (no incrementer in
// front of the BRAM's large address setup time).
module replay_engine #(
  parameter AW      = 12,
  parameter NWORDS  = 1024,
  parameter MEMFILE = "replay.mem"
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  output logic        valid,
  output logic [31:0] data,
  output logic        last,
  output logic        busy,
  output logic        done
);
  (* ram_style = "block" *) logic [32:0] mem [0:(1<<AW)-1];
  initial $readmemh(MEMFILE, mem);

  logic [AW-1:0] addr, addr_q;
  logic [32:0]   rd0, rd1;
  logic          issue, v0, v1, v2;

  assign busy  = issue | v0 | v1 | v2;
  assign valid = v2;
  assign data  = rd1[31:0];
  assign last  = rd1[32];

  always_ff @(posedge clk) begin
    addr_q <= addr;
    rd0 <= mem[addr_q];
    rd1 <= rd0;
    v0  <= issue;
    v1  <= v0;
    v2  <= v1;
    if (rst) begin
      issue <= 1'b0; addr <= '0; done <= 1'b0;
    end else begin
      if (start && !busy) begin
        issue <= 1'b1; addr <= '0; done <= 1'b0;
      end else if (issue) begin
        addr <= addr + 1'b1;
        if (addr == NWORDS-1) issue <= 1'b0;
      end
      if (v2 && !v1 && !v0 && !issue) done <= 1'b1;
    end
  end
endmodule