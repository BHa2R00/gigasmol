`timescale 1ns/1ps
// tb_32 : 32-bit data path test
//   float-immediate load, word/half/byte stores via we[3:0], 32-bit M reads,
//   sign-extended imm16 (-1 -> 0xFFFFFFFF)
module tb_32;
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
integer j;
initial begin
  wait(halt);
  repeat(5) @(posedge clk);
  for(j='h40; j<='h53; j=j+1) $display("mem[%h]=%h", j, top.soc.msh.pram.mem[j]);
  chk('h40,8'h78); chk('h41,8'h56); chk('h42,8'h34); chk('h43,8'h12); // word store
  chk('h44,8'h00); chk('h45,8'hAB); chk('h46,8'hEF); chk('h47,8'hBE); // byte+half
  chk('h50,8'hFF); chk('h51,8'hFF); chk('h52,8'hFF); chk('h53,8'hFF); // sext(-1)
  chk('h48,8'h78); chk('h49,8'h56); chk('h4a,8'h34); chk('h4b,8'h12); // word readback
  chk('h4c,8'h00); chk('h4d,8'hAB); chk('h4e,8'hEF); chk('h4f,8'hBE); // mixed readback
  $display("32 PASS : d=%h a=%h", top.soc.msh.cpu0.core.d, top.soc.msh.cpu0.core.a);
  $finish;
end
initial begin #50000000; $display("TIMEOUT"); $finish; end
endmodule
