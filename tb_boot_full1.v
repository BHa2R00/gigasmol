`timescale 1ns/1ps
// tb_boot_full1 : cpu1 alone runs the FULL 0x4000..0x5fff sweep (force-start),
// must print "1: ram test finish" and leave ram = all 0xff.
module tb_boot_full1;
wire [63:0] io; wire halt; reg rstb, clk;
top top (.io(io), .halt(halt), .rstb(rstb), .clk(clk));
initial clk = 0; always #10 clk = ~clk;
initial begin
  rstb = 0; repeat(3) @(posedge clk); rstb = 1;
  force top.soc.msh.uart0.div = 16'd20;
  force top.soc.msh.cpu1.ib_r = 32'h278;
  force top.soc.msh.cpu1.ctrl = 2'b01;
  force top.soc.msh.cpu2.ctrl = 2'b00; // keep cpu2+ off so the final ram check is undisturbed
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
integer k, e;
initial begin
  wait(top.soc.msh.cpu1.halt);
  repeat(200) @(posedge clk); // let the last uart frame finish shifting out
  $display("");
  e = 0;
  for(k=0;k<'h2000;k=k+1)
    if(top.soc.msh.pram.mem[k] !== 8'hff) begin
      if(e<5) $display("ram[%h]=%h (expect ff)", k, top.soc.msh.pram.mem[k]);
      e = e + 1;
    end
  if(e==0) $display("BOOT FULL1 PASS"); else $display("BOOT FULL1 FAIL e=%0d", e);
  $finish;
end
initial begin #4000000000; $display(""); $display("TIMEOUT"); $finish; end
endmodule
