`timescale 1ns/1ps
// Full harness sim: MMCM stubbed, UART line decoded by a behavioural receiver.
module tb_top;
  logic clk = 0, btnC = 0, btnR = 0; wire txp; wire [15:0] led;
  always #5 clk = ~clk;
  basys3_top #(.AUTO_DELAY(200), .CLKS_PER_BIT(868)) dut (.clk, .btnC, .btnR, .uart_tx_pin(txp), .led);
  reg [7:0] b; integer i;
  initial begin
    forever begin
      @(negedge txp);
      #(868*10/2); #(868*10);
      for (i = 0; i < 8; i = i + 1) begin b[i] = txp; #(868*10); end
      $write("%c", b);
    end
  end
  initial begin #12_000_000; $display("\nLEDs=%b", led[3:0]); $finish; end
endmodule
