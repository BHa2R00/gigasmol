`timescale 1ns/1ps
// uart0 hello : cpu0 (bios) prints "hello world!\n\r" through the hardware
// uart0, then the tb pushes one rx byte and checks the rx flags
module tb_uart0;
wire [63:0] io;
wire halt;
reg rstb, clk;
reg rx0;
wire tx0;
top top (.io(io), .halt(halt), .uart0_rx(rx0), .uart0_tx(tx0), .rstb(rstb), .clk(clk));
initial clk = 0;
always #10 clk = ~clk;
initial begin
  rx0 = 1'b1;
  rstb = 0;
  repeat(3) @(posedge clk); rstb = 1;
end
always @(tx0) $display("%0t TX %b", $time, tx0);
task rx_send(input [7:0] b);
  integer k;
  begin
    rx0 = 0; #(8680);           // start
    for(k=0;k<8;k=k+1) begin rx0 = (b>>k)&1; #(8680); end
    rx0 = 1; #(8680);           // stop
  end
endtask
initial begin
  wait(halt);
  $display("HALT at %0t", $time);
  wait(top.soc.msh.uart0.tbusy === 1'b0); // last frame still on the wire after halt
  repeat(10) @(posedge clk);
  rx_send(8'h55);
  repeat(10) @(posedge clk);
  if(top.soc.msh.uart0.rvld === 1'b1 && top.soc.msh.uart0.rdat === 8'h55)
    $display("RX PASS : rdat=%h rvld=%b", top.soc.msh.uart0.rdat, top.soc.msh.uart0.rvld);
  else
    $display("RX FAIL : rdat=%h rvld=%b", top.soc.msh.uart0.rdat, top.soc.msh.uart0.rvld);
  $finish;
end
initial begin #200000000; $display("TIMEOUT"); $finish; end
endmodule
