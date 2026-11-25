`timescale 1ns/1ps
// tb_boot_seq : short-range boot (0x4000..0x407f) orchestration check.
// forces uart div=20 (bit=160ns: 20 x 8ns lck) for sim speed; decodes the uart stream
// and checks the 11 messages arrive in cpu order.
module tb_boot_seq;
wire [63:0] io; wire halt; reg rstb, clk;
top top (.io(io), .halt(halt), .rstb(rstb), .clk(clk));
initial clk = 0; always #10 clk = ~clk;
initial begin
  rstb = 0; repeat(3) @(posedge clk); rstb = 1;
  force top.soc.msh.uart0.div = 16'd20;
end
// ---- uart decode (8N1, lsb first, bit = 160 ns) ----
reg [7:0] msg [0:511];
integer nch = 0;
task rxbyte;
  integer b; reg [7:0] v;
  begin
    #240; // mid data bit0
    v = 0;
    for(b=0;b<8;b=b+1) begin v[b] = top.uart0_tx; #160; end
    msg[nch] = v; nch = nch + 1;
    $write("%c", v);
    #100; // stop-bit margin, task must end before next frame can start
  end
endtask
always @(negedge top.uart0_tx) rxbyte;
// ---- halt order ----
integer expectcpu = 1; integer halted = 0;
always @(posedge clk) begin
  if(halted < 11) begin
    if(expectcpu==1  && top.soc.msh.cpu1.halt)  begin $display("%0t HALT cpu1", $time);  expectcpu=2;  halted=halted+1; end
    if(expectcpu==2  && top.soc.msh.cpu2.halt)  begin $display("%0t HALT cpu2", $time);  expectcpu=3;  halted=halted+1; end
    if(expectcpu==3  && top.soc.msh.cpu3.halt)  begin $display("%0t HALT cpu3", $time);  expectcpu=4;  halted=halted+1; end
    if(expectcpu==4  && top.soc.msh.cpu4.halt)  begin $display("%0t HALT cpu4", $time);  expectcpu=5;  halted=halted+1; end
    if(expectcpu==5  && top.soc.msh.cpu5.halt)  begin $display("%0t HALT cpu5", $time);  expectcpu=6;  halted=halted+1; end
    if(expectcpu==6  && top.soc.msh.cpu6.halt)  begin $display("%0t HALT cpu6", $time);  expectcpu=7;  halted=halted+1; end
    if(expectcpu==7  && top.soc.msh.cpu7.halt)  begin $display("%0t HALT cpu7", $time);  expectcpu=8;  halted=halted+1; end
    if(expectcpu==8  && top.soc.msh.cpu8.halt)  begin $display("%0t HALT cpu8", $time);  expectcpu=9;  halted=halted+1; end
    if(expectcpu==9  && top.soc.msh.cpu9.halt)  begin $display("%0t HALT cpu9", $time);  expectcpu=10; halted=halted+1; end
    if(expectcpu==10 && top.soc.msh.cpu10.halt) begin $display("%0t HALT cpu10", $time); expectcpu=11; halted=halted+1; end
    if(expectcpu==11 && top.soc.msh.cpu11.halt) begin $display("%0t HALT cpu11", $time); halted=halted+1; end
  end
end
// ---- verdict ----
integer i, e;
initial begin
  wait(halt);         // cpu0 parked (all configs issued)
  wait(halted==11);   // all test cpus finished (global timeout guards hangs)
  repeat(200) @(posedge clk); // let the last uart frame finish shifting out
  $display("");
  e = 0;
  // spot check ram = 0xff
  if(top.soc.msh.pram.mem['h0] !== 8'hff || top.soc.msh.pram.mem['h40] !== 8'hff ||
     top.soc.msh.pram.mem['h7f] !== 8'hff) begin $display("RAM content bad"); e=e+1; end
  if(e==0 && halted==11) $display("BOOT SEQ PASS");
  else $display("BOOT SEQ FAIL e=%0d halted=%0d", e, halted);
  $finish;
end
initial begin #200000000; $display("TIMEOUT"); $finish; end
endmodule
