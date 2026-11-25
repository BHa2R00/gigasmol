`timescale 1ns/1ps
// multi-cpu config test : cpu0 boots, writes cpu1 config over the axi xbar
// (ENTRY=0x0100 @0x3014/0x3015, CTRL=enable @0x3010), cpu1 starts, stores
// 0x42 into io-device ram 0x2040 and halts
module tb_mc;
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
  wait(halt); // cpu0 done : config writes issued
  $display("%0t cpu0 HALT (pc=%h)", $time, top.soc.msh.cpu0.core.p);
  wait(top.soc.msh.cpu1.core.p == 16'hffff); // cpu1 done
  repeat(20) @(posedge clk);
  if (top.soc.msh.iodev.ram['h40] === 8'h42)
    $display("%0t PASS : cpu1 ran from configured entry, ram[0x40]=%h", $time, top.soc.msh.iodev.ram['h40]);
  else
    $display("%0t FAIL : ram[0x40]=%h", $time, top.soc.msh.iodev.ram['h40]);
  $display("cpu1 STAT via cfg readback : halted=%b pc=%h", top.soc.msh.cpu1.halt, top.soc.msh.cpu1.pc);
  $finish;
end
initial begin #50000000; $display("TIMEOUT p0=%h p1=%h", top.soc.msh.cpu0.core.p, top.soc.msh.cpu1.core.p); $finish; end
endmodule
