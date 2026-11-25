`timescale 1ns/1ps
// tb_off : pc0 (ENTRY) offset fetch test
// cpu0 (BIOS, ROM) configures cpu1/2/3 ENTRY = 0x4000/0x4040/0x4080 + enable,
// each compute cpu runs a 6-word payload out of RAM that writes a signature
// byte (0xC1/0xC2/0xC3) to ram bytes 0x100/0x101/0x102 and halts.
module tb_off;
wire [63:0] io;
wire halt;
reg rstb, clk;
top top (.io(io), .halt(halt), .rstb(rstb), .clk(clk));
initial clk = 0;
always #10 clk = ~clk;
initial begin
  rstb = 0;
  repeat(3) @(posedge clk); rstb = 1;
end
initial begin
  wait(top.soc.msh.cpu1.core.p === 16'hffff &&
       top.soc.msh.cpu2.core.p === 16'hffff &&
       top.soc.msh.cpu3.core.p === 16'hffff);
  repeat(5) @(posedge clk);
  $display("cpu0 p=%h cpu1 p=%h cpu2 p=%h cpu3 p=%h",
           top.soc.msh.cpu0.core.p, top.soc.msh.cpu1.core.p,
           top.soc.msh.cpu2.core.p, top.soc.msh.cpu3.core.p);
  $display("ram[100]=%h ram[101]=%h ram[102]=%h",
           top.soc.msh.pram.mem['h100], top.soc.msh.pram.mem['h101], top.soc.msh.pram.mem['h102]);
  if(top.soc.msh.pram.mem['h100] === 8'hC1 &&
     top.soc.msh.pram.mem['h101] === 8'hC2 &&
     top.soc.msh.pram.mem['h102] === 8'hC3)
    $display("OFF PASS");
  else
    $display("OFF FAIL");
  $finish;
end
initial begin #50000000; $display("TIMEOUT"); $finish; end
endmodule
