`timescale 1ns/1ps
// Behavioural stand-ins for Xilinx primitives (simulation with iverilog only)
module BUFG(input I, output O); assign O = I; endmodule
module MMCME2_BASE #(parameter BANDWIDTH="OPTIMIZED", parameter real CLKIN1_PERIOD=10.0,
  parameter integer DIVCLK_DIVIDE=1, parameter real CLKFBOUT_MULT_F=9.6, parameter real CLKOUT0_DIVIDE_F=3.0)
 (input CLKIN1, input CLKFBIN, output CLKFBOUT, output reg CLKOUT0, output reg LOCKED, input PWRDWN, input RST);
  assign CLKFBOUT = CLKIN1;
  initial begin CLKOUT0 = 0; LOCKED = 0; #200 LOCKED = 1; end
  always #1.5625 CLKOUT0 = ~CLKOUT0;
endmodule
