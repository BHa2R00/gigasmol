`timescale 1ns/1ps
// tb_boot : --boot generated rom0 image, FULL range (impractically slow in
// iverilog : ~20 s sim time). the practical checks are :
//   tb_boot_seq   short sweep (--boot 4080) : 11 cpus in order, decoded prints
//   tb_boot_fail  stuck word at 0x4040 -> "1: fail at address 4040"
//   tb_boot_full1 cpu1 alone, full sweep, ram all-0xff check
// cpu0 starts cpu1..cpu11 one at a time, each runs its own ram test from
// rom0 (IBASE = its test block) and prints "<n>: ram test finish\n" or
// "<n>: fail at address <hhhh>\n" on uart0. this tb only logs tx edges.
// note : the soc runs on the pll's lck (8 ns in SIM), so uart bit time at
// the default div=1085 is 8.68 us, not 21.7 us.
module tb_boot;
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
always @(top.uart0_tx) $display("%0t TX %b", $time, top.uart0_tx);
initial begin
  wait(halt); // cpu0 parked -> all 11 tests done
  repeat(20) @(posedge clk);
  $display("ram[0]=%h ram[1000]=%h ram[1fff]=%h",
    top.soc.msh.pram.mem['h0], top.soc.msh.pram.mem['h1000], top.soc.msh.pram.mem['h1fff]);
  $display("CPU0 HALT (all tests done)");
  $finish;
end
initial begin #900000000; $display("TIMEOUT"); $finish; end
endmodule
