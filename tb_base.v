`timescale 1ns/1ps
// tb_base : IBASE/DBASE config test
// cpu0 writes cpu1 IBASE=0x4080 / DBASE=0x4000 with full word stores, enables
// cpu1, then reads both config words back into ram[0x140..0x147].
// cpu1 fetches its payload from ram+0x80 (IBASE) and byte-stores 0x5A at data
// offset 0x100 -> physical 0x4100 (DBASE) -> ram[0x100].
module tb_base;
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
task chk(input [12:0] ad, input [7:0] v);
  if(top.soc.msh.pram.mem[ad] !== v)
    $display("FAIL mem[%h] = %h, expect %h", ad, top.soc.msh.pram.mem[ad], v);
endtask
initial begin
  wait(top.soc.msh.cpu1.core.p === 16'hffff);
  repeat(10) @(posedge clk);
  $display("cpu1 ib_r=%h db_r=%h (probe)", top.soc.msh.cpu1.ib_r, top.soc.msh.cpu1.db_r);
  chk('h100, 8'h5A);                      // DBASE-relative byte store
  chk('h140, 8'h80); chk('h141, 8'h40);   // IBASE readback = 0x00004080
  chk('h142, 8'h00); chk('h143, 8'h00);
  chk('h144, 8'h00); chk('h145, 8'h40);   // DBASE readback = 0x00004000
  chk('h146, 8'h00); chk('h147, 8'h00);
  if(top.soc.msh.cpu1.ib_r === 32'h4080 && top.soc.msh.cpu1.db_r === 32'h4000 &&
     top.soc.msh.pram.mem['h100] === 8'h5A &&
     top.soc.msh.pram.mem['h140] === 8'h80 && top.soc.msh.pram.mem['h141] === 8'h40 &&
     top.soc.msh.pram.mem['h144] === 8'h00 && top.soc.msh.pram.mem['h145] === 8'h40)
    $display("BASE PASS");
  else
    $display("BASE FAIL");
  $finish;
end
initial begin #50000000; $display("TIMEOUT"); $finish; end
endmodule
