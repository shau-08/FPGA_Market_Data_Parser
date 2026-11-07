`timescale 1ns/1ps
module uart_tx #(parameter CLKS_PER_BIT = 868) (   // 100 MHz / 115200
  input  logic       clk, rst,
  input  logic [7:0] data,
  input  logic       valid,
  output logic       ready,
  output logic       tx
);
  logic [3:0] bitn; logic [15:0] cnt; logic [9:0] sh; logic busy;
  assign ready = !busy;
  always_ff @(posedge clk) begin
    if (rst) begin busy <= 1'b0; tx <= 1'b1; end
    else if (!busy) begin
      tx <= 1'b1;
      if (valid) begin sh <= {1'b1, data, 1'b0}; busy <= 1'b1; cnt <= '0; bitn <= '0; tx <= 1'b0; end
    end else if (cnt == CLKS_PER_BIT-1) begin
      cnt <= '0;
      if (bitn == 4'd9) begin busy <= 1'b0; tx <= 1'b1; end
      else begin bitn <= bitn + 4'd1; tx <= sh[bitn + 4'd1]; end
    end else cnt <= cnt + 16'd1;
  end
endmodule
