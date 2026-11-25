`timescale 1ns/1ps
module tb_uart;
wire [63:0] io;
wire halt;
reg rstb, clk;
top top (.io(io), .halt(halt), .rstb(rstb), .clk(clk));
initial clk = 0;
always #10 clk = ~clk;
reg tx_prev;
initial begin
  tx_prev = 1'b1;
  rstb = 0;
  repeat(3) @(posedge clk); rstb = 1;
end
always @(top.io_i[0]) begin
  $display("%0t TX %b", $time, top.io_i[0]);
end
initial begin
  wait(halt);
  repeat(10) @(posedge clk);
  $display("HALT at %0t", $time);
  $finish;
end
initial begin
  #200000000; // 200ms safety timeout
  $display("TIMEOUT");
  $finish;
end
endmodule
