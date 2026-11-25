`timescale 1ns/1ps
module tb_imm;
wire [63:0] io;
wire halt;
reg rstb, clk;
top top (.io(io), .halt(halt), .rstb(rstb), .clk(clk));
initial clk = 0;
always #10 clk = ~clk;
reg [15:0] a_prev;
initial begin
  rstb = 0; a_prev = 16'hxxxx;
  repeat(3) @(posedge clk); rstb = 1;
end
always @(top.soc.msh.cpu0.core.a) begin
  if (^top.soc.msh.cpu0.core.a !== 1'bx)
    $display("%0t A=%h", $time, top.soc.msh.cpu0.core.a);
end
initial begin
  wait(halt);
  repeat(5) @(posedge clk);
  $display("HALT D=%h", top.soc.msh.cpu0.core.d);
  $finish;
end
initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
