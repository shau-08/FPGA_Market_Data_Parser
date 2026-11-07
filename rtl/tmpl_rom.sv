// templateId -> supported? Registered (1 cycle). Add a row to support a template
// that shares the entry layout used in mdp_decode.
module tmpl_rom (
  input  logic        clk,
  input  logic [15:0] tid,
  output logic        valid
);
  always_ff @(posedge clk) begin
    case (tid)
      16'd46:  valid <= 1'b1;   // MDIncrementalRefreshBook
      16'd48:  valid <= 1'b1;   // MDIncrementalRefreshTradeSummary
      default: valid <= 1'b0;
    endcase
  end
endmodule
