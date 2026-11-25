`timescale 1ns/1ps
// tb_boot_fail : like tb_boot_seq but word 0x4040 is stuck at 0xaa
// (force on the ram array) -> cpu1 must print "1: fail at address 4040".
module tb_boot_fail;
wire [63:0] io; wire halt; reg rstb, clk;
top top (.io(io), .halt(halt), .rstb(rstb), .clk(clk));
initial clk = 0; always #10 clk = ~clk;
initial begin
  rstb = 0; repeat(3) @(posedge clk); rstb = 1;
  force top.soc.msh.uart0.div = 16'd20;
end
// after cpu1 pokes 0 at word 0x4040, corrupt mem['h40] -> read-back != 0
reg injected = 0;
always @(posedge top.soc.msh.clk) // pram runs on lck (8ns), not the tb clk
  if (!injected && top.soc.msh.pram.fwrite && top.soc.msh.pram.faddr[12:0]=='h40) begin
    injected <= 1;
    @(negedge top.soc.msh.clk); // let the ram's own nba write settle first
    top.soc.msh.pram.mem['h40] = 8'haa;
  end
task rxbyte;
  integer b; reg [7:0] v;
  begin
    #240; v = 0;
    for(b=0;b<8;b=b+1) begin v[b] = top.uart0_tx; #160; end
    $write("%c", v);
    #100;
  end
endtask
always @(negedge top.uart0_tx) rxbyte;
initial begin
  wait(top.soc.msh.cpu1.halt);
  repeat(200) @(posedge clk); // let the last uart frame finish shifting out
  $display("");
  $display("cpu1 halted (fail path)");
  $finish;
end
initial begin #20000000; $display(""); $display("TIMEOUT"); $finish; end
endmodule
