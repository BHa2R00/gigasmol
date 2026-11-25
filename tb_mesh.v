`timescale 1ns/1ps
// tb_mesh : longest-path boot over the 4x4 mesh
// cpu0 (node4) configures cpu11 (node15) : config route E,E,E,S,S (5 hops),
// cpu11 fetches its payload from ram (node3) : N,N,N,W,W,W route L (6 hops),
// then stores 0x11 at DBASE+0x110 = 0x4110 -> pram byte 0x110.
module tb_mesh;
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
  wait(top.soc.msh.cpu11.core.p === 16'hffff);
  repeat(10) @(posedge clk);
  $display("cpu11 ib=%h db=%h p=%h", top.soc.msh.cpu11.ib_r, top.soc.msh.cpu11.db_r, top.soc.msh.cpu11.core.p);
  $display("ram[110]=%h", top.soc.msh.pram.mem['h110]);
  if(top.soc.msh.cpu11.ib_r === 32'h40c0 && top.soc.msh.cpu11.db_r === 32'h4000 &&
     top.soc.msh.pram.mem['h110] === 8'h11)
    $display("MESH PASS");
  else
    $display("MESH FAIL");
  $finish;
end
initial begin #50000000; $display("TIMEOUT"); $finish; end
endmodule
