`timescale 1ns/1ps

//=========================================================================
// smol soc : NaN-boxed hack-ISA cpus on a minimal AXI fabric (no burst)
//
//   cpu      : 2-state core, one instruction port + one byte data port
//   axi_m    : single-outstanding AXI master bridge, burst fields tied off
//   axi_s    : single-beat AXI slave with a simple backend interface
//   smol_rom : AXI slave rom, 8KB, $readmemh init, writable
//   smol_io  : AXI slave io device : dev regs / scratch ram / hw stacks /
//              timer / gpio+uart pins (old smol dev+ram layout at 0x2000)
//   cpu_axi  : cpu + im/dm masters + config slave (CTRL/IBASE/DBASE/STAT)
//   mesh_router : 5-port (E/W/N/S/L) XY-routing noc router with per-input
//              DECERR responders ; cpu_locmux merges a cpu's im+dm masters
//              into the router local port (the 2-state core never has both
//              in flight, so one owner bit covers the read channel)
//   axi_xbar : old priority interconnect (unused, kept for reference)
//
// fabric : 4x4 axi mesh (node = y*4+x, x east, y south) :
//   y=0 : rom io uart0 ram   (devices, local slave only)
//   y=1 : cpu0(bios) cpu1 cpu2 cpu3
//   y=2 : cpu4..7 , y=3 : cpu8..11   (compute cpus, started via config)
// the mesh netlist (module mesh_top) is GENERATED : `include "mesh.v`,
//   produced from the *aximesh* config list in sw.lisp :
//     sbcl --script sw.lisp --aximesh > mesh.v
//   smol_soc below = mesh_top + ports (conceptually soc_top = mesh_top + pads)
//
// address map (32-bit, cpus see the low 64KB) :
//   0x0000-0x1fff rom   (node0)   0x2000-0x20ff io device (node1)
//   0x2100-0x210f uart0 (node2)   0x4000-0x5fff ram       (node3)
//   0x3000+N*0x10 cpuN config, N=0..11 (node4+N)
//
// cpu config registers (word slots, 16B window) :
//   0x0 CTRL : bit0 enable (1=run, 0=hold in reset), bit1 halt (1=stop)
//   0x4 IBASE: 32-bit instruction fetch base (reset = BOOT_IB parameter)
//   0x8 DBASE: 32-bit data access base       (reset = BOOT_DB parameter)
//   0xc STAT : bit0 halted, [31:16] current pc (read only)
// cores issue 16-bit program-relative offsets ; physical master addresses
// are 32-bit : im = IBASE + p (bios cpu masked into the rom window),
//              dm = DBASE + a[15:0]
//=========================================================================


// 32-bit instruction word = IEEE754 float32, hack instructions live in the NaN space
//   i[30:23]==8'hFF && i[22:0]!=0  -> NaN -> hack instruction, payload = i[22:0]
//   i[22]   quiet bit = A/C selector:
//             1 = A-instruction (quiet NaN)   : A <= sext(imm16) = sext(i[16:1]), i[21:17] free
//             0 = C-instruction (signaling)   : i[0] const 1 keeps mantissa nonzero
//   non-NaN word (normal float / inf / zero / denormal) : A <= i (raw 32-bit immediate)
//   i[31] sign is dont-care for NaN, kept 0 by the assembler
//   C-instruction fields (32-bit data path) :
//     i[ 1]      src : ysel LSB (legacy 1-bit src, 0=A 1=M)
//     i[ 9:2]    opc : base ALU opcode
//     i[12:11]   dst : writeback D/A bitmask
//     i[10]      we[0] : memory byte write enable bit0 (legacy M dst bit)
//     i[15:13]   jmp : jump condition {lt,eq,gt} bitmask
//     i[18:16]        : ysel[3:1] ; ysel = {i[18:16],i[1]}
//                       0 = A, 1 = M, 2..15 = reserved for future chained ALU outputs
//     i[21:19]   we[3:1] : memory byte write enables, we = {i[21:19],i[10]}
//                       0001 = byte at a, 0011 = half at a, 1111 = aligned word
//   data memory : M read  = aligned word >> 8*a[1:0] (addressed byte in lane 0)
//                 M write = z << 8*a[1:0] through wstrb = we << a[1:0]
//                 (we=1111 forces an aligned 32-bit word store, a[1:0] ignored)
module cpu
(
  input              imready , // instruction port : fetch returns the whole 32-bit word
  input      [31: 0] imrdata ,
  output reg         imvalid ,
  output reg [15: 0] imaddr  ,
  input              dmready , // data port : 32-bit with byte write enables
  input      [31: 0] dmrdata ,
  output reg         dmvalid ,
  output reg [15: 0] dmaddr  ,
  output reg         dmwrite ,
  output reg [ 3: 0] dmwbe   ,
  output reg [31: 0] dmwdata ,
  input              rstb    ,
  input              fhalt   , // force halt from config
  output reg         halt    ,
  output     [15: 0] pc      ,
  input      [15: 0] entry   ,
  input              clk
);

reg [15:0] p;
reg [31:0] i;
reg signed [31:0] a, d, m;
wire       fnan = &i[30:23] & (|i[22:0]); // float32 NaN : boxed hack instruction
wire       cin  = fnan & ~i[22];          // C-instruction (signaling NaN)
wire       ain  = fnan &  i[22];          // A-instruction (quiet NaN)
wire [3:0] ysel = {i[18:16],i[1]};
wire [7:0] opc = i[9:2];
wire [1:0] dst = i[12:11]; // D/A writeback bitmask (M side lives in we)
wire [3:0] we  = {i[21:19],i[10]};
wire [2:0] jmp = i[15:13];
wire signed [31:0] x = d;
wire signed [31:0] y = (ysel == 4'd0) ? a : (ysel == 4'd1) ? m : 32'sd0;
wire signed [31:0] x0 = opc[5] ? 0 : x;
wire signed [31:0] x1 = opc[4] ? ~x0 : x0;
wire signed [31:0] y0 = opc[3] ? 0 : y;
wire signed [31:0] y1 = opc[2] ? ~y0 : y0;
wire signed [31:0] z0 = opc[1] ? 
  (opc[0] ? 
    (y1[31] ? (x1 >> (0-y1)) : x1 << y1) : 
    (x1[31] ? (y1 >> (0-x1)) : y1 << x1)) : 
  (opc[0] ? (x1 + y1) : (x1 & y1));
reg signed [31:0] rz0; integer k;
wire signed [31:0] z1 = opc[7] ? rz0 : z0;
wire signed [31:0] z  = opc[6] ? ~z1 : z1;
wire lt = z[31];
wire eq = ~|z;
wire le = lt || eq;
wire gt = ~le;
wire memreq = cin & ((ysel == 4'd1) | (|we)); // C-instruction touches data memory
reg cst, nst; // 0 = fetch, 1 = execute
assign pc = p;
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    cst <= 0;
    p <= entry;
  end
  else if(~halt) begin
    cst <= nst;
    case(cst) 
      0 : if(imready) begin
        i <= imrdata;
        p <= p + 4;
      end
      1 : if(~memreq | dmready) begin
        if(cin) begin
          if(dst[0]) d <= z;
          if(dst[1]) a <= z;
          if(|(jmp & {lt,eq,gt})) p <= a[15:0];
        end
        else if(ain) a <= {{16{i[16]}},i[16:1]}; // A-instruction : sign-extended imm16
        else       a <= i;                        // plain float word : raw 32-bit immediate
      end
    endcase
  end
end
always@(*) begin
  nst = cst;
  imvalid = 0;
  imaddr = p;
  dmvalid = 0;
  dmaddr = a[15:0];
  dmwrite = 0;
  dmwbe = 4'd0;
  dmwdata = z;
  m = dmrdata;
  halt = &p | fhalt;
  for(k=0;k<=31;k=k+1) rz0[k] = z0[31-k];
  // no bus request while halted (p==0xffff or fhalt) : keeps a parked cpu
  // off the axi fabric instead of refetching 0xffff forever
  if(rstb & ~halt) case(cst)
    0 : begin
      imvalid = 1;
      imaddr = p;
      if(imready) nst = 1;
    end
    1 : begin
      dmvalid = memreq;
      dmwrite = cin & (|we);
      dmwbe = {4{cin}} & we;
      dmaddr = a[15:0];
      if(~memreq | dmready) nst = 0;
    end
  endcase
end

endmodule


// single-outstanding AXI master bridge, no burst :
//   AW/AR LEN=0 SIZE=4B BURST=INCR, WLAST=1, BREADY/RREADY tied 1
module axi_m
#(
  parameter INST = 0 
)
(
  input              clk   ,
  input              rstb  ,
  // simple side : req held until gnt (1-cycle pulse)
  input              req   ,
  output             gnt   ,
  input      [31: 0] addr  , // 32-bit physical address (base register + core offset)
  input              write ,
  input      [ 3: 0] wbe   , // byte write enables, relative to addr lane
  input      [31: 0] wdata ,
  output     [31: 0] rdata , // aligned word >> 8*addr[1:0] (addressed byte in lane 0)
  output     [31: 0] rword , // whole aligned word (instruction fetch)
  // AXI write address
  output reg [31: 0] m_axi_awaddr  ,
  output reg         m_axi_awvalid ,
  input              m_axi_awready ,
  output     [ 7: 0] m_axi_awlen   ,
  output     [ 2: 0] m_axi_awsize  ,
  output     [ 1: 0] m_axi_awburst ,
  // AXI write data
  output reg [31: 0] m_axi_wdata   ,
  output reg [ 3: 0] m_axi_wstrb   ,
  output reg         m_axi_wvalid  ,
  input              m_axi_wready  ,
  output             m_axi_wlast   ,
  // AXI write response
  input      [ 1: 0] m_axi_bresp   ,
  input              m_axi_bvalid  ,
  output             m_axi_bready  ,
  // AXI read address
  output reg [31: 0] m_axi_araddr  ,
  output reg [ 2: 0] m_axi_arprot  ,
  output reg         m_axi_arvalid ,
  input              m_axi_arready ,
  output     [ 7: 0] m_axi_arlen   ,
  output     [ 2: 0] m_axi_arsize  ,
  output     [ 1: 0] m_axi_arburst ,
  // AXI read data
  input      [31: 0] m_axi_rdata   ,
  input      [ 1: 0] m_axi_rresp   ,
  input              m_axi_rvalid  ,
  input              m_axi_rlast   ,
  output             m_axi_rready
);

assign m_axi_awlen   = 8'h00;      // 1 beat
assign m_axi_awsize  = 3'd2;       // 4 bytes
assign m_axi_awburst = 2'b01;      // INCR
assign m_axi_wlast   = 1'b1;
assign m_axi_bready  = 1'b1;
assign m_axi_arlen   = 8'h00;
assign m_axi_arsize  = 3'd2;
assign m_axi_arburst = 2'b01;
assign m_axi_rready  = 1'b1;

reg [ 1: 0] st; // 0 idle, 1 write (wait B), 2 read (wait R)
reg [31: 0] al;
assign gnt   = ((st == 2'd1) & m_axi_bvalid) | ((st == 2'd2) & m_axi_rvalid);
assign rdata = m_axi_rdata >> {al[1:0],3'b000};
assign rword = m_axi_rdata;
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    st <= 0;
    al <= 0;
    m_axi_awaddr <= 0;  m_axi_awvalid <= 0;
    m_axi_wdata  <= 0;  m_axi_wstrb   <= 0;  m_axi_wvalid <= 0;
    m_axi_araddr <= 0;  m_axi_arprot  <= 0;  m_axi_arvalid <= 0;
  end
  else case(st)
    0 : if(req) begin
      al <= addr;
      if(write) begin
        // wbe=1111 : aligned 32-bit word store, address lane ignored ;
        // else     : lanes rotate by addr[1:0] so wbe=0001 writes wdata[7:0]
        //            at the byte address, wbe=0011 a halfword, and so on
        if(wbe == 4'b1111) begin
          m_axi_awaddr  <= {addr[31:2],2'b00};
          m_axi_wdata   <= wdata;
          m_axi_wstrb   <= 4'b1111;
        end
        else begin
          m_axi_awaddr  <= addr;
          m_axi_wdata   <= wdata << {addr[1:0],3'b000};
          m_axi_wstrb   <= wbe << addr[1:0];
        end
        m_axi_awvalid <= 1;
        m_axi_wvalid  <= 1;
        st <= 1;
      end
      else begin
        m_axi_araddr  <= addr;
        m_axi_arprot  <= INST ? 3'b100 : 3'b000;
        m_axi_arvalid <= 1;
        st <= 2;
      end
    end
    1 : begin
      if(m_axi_awready) m_axi_awvalid <= 0;
      if(m_axi_wready)  m_axi_wvalid  <= 0;
      if(m_axi_bvalid)  st <= 0;
    end
    2 : begin
      if(m_axi_arready) m_axi_arvalid <= 0;
      if(m_axi_rvalid)  st <= 0;
    end
    default : st <= 0;
  endcase
end

endmodule


// single-beat AXI slave, no burst : backend gets a comb read port and
// 1-cycle fire pulses with latched address/data for side effects
module axi_s
(
  input              clk   ,
  input              rstb  ,
  // AXI write address
  input      [31: 0] s_axi_awaddr  ,
  input              s_axi_awvalid ,
  output             s_axi_awready ,
  // AXI write data
  input      [31: 0] s_axi_wdata   ,
  input      [ 3: 0] s_axi_wstrb   ,
  input              s_axi_wvalid  ,
  output             s_axi_wready  ,
  // AXI write response
  output reg [ 1: 0] s_axi_bresp   ,
  output reg         s_axi_bvalid  ,
  input              s_axi_bready  ,
  // AXI read address
  input      [31: 0] s_axi_araddr  ,
  input      [ 2: 0] s_axi_arprot  ,
  input              s_axi_arvalid ,
  output             s_axi_arready ,
  // AXI read data
  output reg [31: 0] s_axi_rdata   ,
  output reg [ 1: 0] s_axi_rresp   ,
  output             s_axi_rlast   ,
  output reg         s_axi_rvalid  ,
  input              s_axi_rready  ,
  // backend : comb read
  output     [31: 0] baddr  , // byte address of the in-flight request
  output             binst  , // 1 = instruction fetch
  output             rh     , // read handshake this cycle (baddr valid, read side effects)
  input      [31: 0] brdata , // comb : aligned word / byte in lane baddr[1:0]
  // backend : 1-cycle fire pulses (side effects apply here)
  output reg [31: 0] faddr  ,
  output reg [31: 0] fwdata ,
  output reg [ 3: 0] fwstrb ,
  output reg         fwrite ,
  output reg         fread
);

assign s_axi_arready = 1'b1;
assign s_axi_awready = ~s_axi_arvalid; // read priority, masters never do both
assign s_axi_wready  = ~s_axi_arvalid;
assign s_axi_rlast   = 1'b1;
assign rh    = s_axi_arvalid & s_axi_arready;
assign baddr = s_axi_arvalid ? s_axi_araddr : s_axi_awaddr;
assign binst = s_axi_arvalid ? s_axi_arprot[2] : 1'b0;
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    s_axi_rdata  <= 0; s_axi_rresp <= 0; s_axi_rvalid <= 0;
    s_axi_bresp  <= 0; s_axi_bvalid <= 0;
    faddr <= 0; fwdata <= 0; fwstrb <= 0;
    fwrite <= 0; fread <= 0;
  end
  else begin
    fwrite <= 0;
    fread  <= 0;
    if(s_axi_rvalid & s_axi_rready) s_axi_rvalid <= 0;
    if(s_axi_bvalid & s_axi_bready) s_axi_bvalid <= 0;
    if(s_axi_arvalid & s_axi_arready) begin
      s_axi_rdata  <= brdata;
      s_axi_rresp  <= 2'b00;
      s_axi_rvalid <= 1;
      faddr <= s_axi_araddr;
      fread <= 1;
    end
    if(s_axi_awvalid & s_axi_awready & s_axi_wvalid & s_axi_wready) begin
      s_axi_bresp  <= 2'b00;
      s_axi_bvalid <= 1;
      faddr  <= s_axi_awaddr;
      fwdata <= s_axi_wdata;
      fwstrb <= s_axi_wstrb;
      fwrite <= 1;
    end
  end
end

endmodule


// 8KB rom as an AXI slave : $readmemh init, returns the aligned 32-bit word
// (byte lane extraction happens in the master bridge) ; writes honored per
// wstrb so one cpu can patch code for another
module smol_rom
(
  input              clk   ,
  input              rstb  ,
  input      [31: 0] s_axi_awaddr  ,
  input              s_axi_awvalid ,
  output             s_axi_awready ,
  input      [31: 0] s_axi_wdata   ,
  input      [ 3: 0] s_axi_wstrb   ,
  input              s_axi_wvalid  ,
  output             s_axi_wready  ,
  output     [ 1: 0] s_axi_bresp   ,
  output             s_axi_bvalid  ,
  input              s_axi_bready  ,
  input      [31: 0] s_axi_araddr  ,
  input      [ 2: 0] s_axi_arprot  ,
  input              s_axi_arvalid ,
  output             s_axi_arready ,
  output     [31: 0] s_axi_rdata   ,
  output     [ 1: 0] s_axi_rresp   ,
  output             s_axi_rlast   ,
  output             s_axi_rvalid  ,
  input              s_axi_rready
);

wire [31: 0] baddr, faddr, fwdata;
wire [ 3: 0] fwstrb;
wire         binst, rh, fwrite, fread;
reg  [31: 0] brdata;
reg  [ 7: 0] rom[0:'h1fff];
wire [12: 0] wa = {baddr[12:2],2'b00}; // aligned word offset
integer li;
initial $readmemh("rom.memh", rom);
always@(*) brdata = {rom[wa+3],rom[wa+2],rom[wa+1],rom[wa]};
always@(posedge clk) begin
  if(fwrite) begin
    for(li=0;li<4;li=li+1)
      if(fwstrb[li]) rom[{faddr[12:2],2'b00}+li[12:0]] <= fwdata[li*8 +: 8];
  end
end
axi_s s
(
  .clk(clk), .rstb(rstb),
  .s_axi_awaddr (s_axi_awaddr),
  .s_axi_awvalid(s_axi_awvalid),
  .s_axi_awready(s_axi_awready),
  .s_axi_wdata  (s_axi_wdata),
  .s_axi_wstrb  (s_axi_wstrb),
  .s_axi_wvalid (s_axi_wvalid),
  .s_axi_wready (s_axi_wready),
  .s_axi_bresp  (s_axi_bresp),
  .s_axi_bvalid (s_axi_bvalid),
  .s_axi_bready (s_axi_bready),
  .s_axi_araddr (s_axi_araddr),
  .s_axi_arprot (s_axi_arprot),
  .s_axi_arvalid(s_axi_arvalid),
  .s_axi_arready(s_axi_arready),
  .s_axi_rdata  (s_axi_rdata),
  .s_axi_rresp  (s_axi_rresp),
  .s_axi_rlast  (s_axi_rlast),
  .s_axi_rvalid (s_axi_rvalid),
  .s_axi_rready (s_axi_rready),
  .baddr(baddr), .binst(binst), .rh(rh), .brdata(brdata),
  .faddr(faddr), .fwdata(fwdata), .fwstrb(fwstrb),
  .fwrite(fwrite), .fread(fread)
);

endmodule


// io device as an AXI slave : the old smol dev+ram block at 0x2000, uart and
// gpio pins included. register map (byte offsets inside the 256B window) :
//   0x00-0x03 s0b/s0p/s1b/s1p hw stack alias regs (access to the aliased
//             address pushes/pops, remapped through s?b+s?p)
//   0x04 page (kept for compatibility, remap stays inside the window)
//   0x05-0x06 entry (legacy boot pc regs, now unused : boot pc lives in the
//             cpu config slave)
//   0x07-0x08 io_os/io_is iomux output/input shifter amounts
//   0x09-0x10 io_c  pin capture (reads return the live shifted io_o)
//   0x11-0x18 io_i  pin drive value (uart tx = io_i[0])
//   0x19-0x20 io_oe pin output enable
//   0x21-0x28 io_ie pin input enable
//   0x29-0x30 cnt   free-running ripple counter (reads return live value)
//   0x31 tmr_sel, 0x32 tmr_set (write control / read live tmr_vld status),
//   0x33 tmr_from, 0x34 tmr (reads return live countdown)
//   0x35-0xff scratch ram
module smol_io
(
  input              clk   , // bus clock (lck)
  input              ioclk , // pin/counter clock (board clk, old smol domains)
  input              rstb  ,
  output reg [63: 0] io_i  ,
  output reg [63: 0] io_oe ,
  output reg [63: 0] io_ie ,
  input      [63: 0] io_o  ,
  output     [ 7: 0] debug ,
  input      [31: 0] s_axi_awaddr  ,
  input              s_axi_awvalid ,
  output             s_axi_awready ,
  input      [31: 0] s_axi_wdata   ,
  input      [ 3: 0] s_axi_wstrb   ,
  input              s_axi_wvalid  ,
  output             s_axi_wready  ,
  output     [ 1: 0] s_axi_bresp   ,
  output             s_axi_bvalid  ,
  input              s_axi_bready  ,
  input      [31: 0] s_axi_araddr  ,
  input      [ 2: 0] s_axi_arprot  ,
  input              s_axi_arvalid ,
  output             s_axi_arready ,
  output     [31: 0] s_axi_rdata   ,
  output     [ 1: 0] s_axi_rresp   ,
  output             s_axi_rlast   ,
  output             s_axi_rvalid  ,
  input              s_axi_rready
);

wire [31: 0] baddr, faddr, fwdata;
wire [ 3: 0] fwstrb;
wire         binst, rh, fwrite, fread;
reg  [31: 0] brdata;

reg [7:0] dev[0:'h34];   // register file
reg [7:0] ram['h35:'hff]; // scratch ram

// stack alias registers + remap (same rules as the old smol ADDR logic,
// truncated to the 256B window)
wire [7:0] off  = baddr[7:0];
wire [7:0] foff = faddr[7:0];
wire [7:0] s0b = dev['h00], s0p = dev['h01];
wire [7:0] s1b = dev['h02], s1p = dev['h03];
wire [7:0] roff_r = (off==s0b) ? (s0p+s0b-8'd1) :
                    (off==s1b) ? (s1p+s1b-8'd1) : off;
wire [7:0] roff_w = (foff==s0b) ? (s0p+s0b) :
                    (foff==s1b) ? (s1p+s1b) : foff;

// timer / counter (board clock domain, as before)
wire [ 7: 0] tmr;
wire         tmr_vld;
wire [63: 0] cnt;
counter #(63) counter
(
  .tmr (tmr), .from(dev['h33]),
  .vld (tmr_vld), .set(dev['h32][0]), .sel(dev['h31]),
  .cnt (cnt),
  .rstb(rstb), .clk(ioclk)
);
assign debug[0] = cnt[28];
assign debug[7:1] = 7'd0;

// byte read : tmr_set/tmr/io_c/cnt return live status combinationally
// (control registers are never clobbered by status sampling)
function [7:0] rraw(input [7:0] o);
  rraw = (o==8'h32) ? {7'd0,tmr_vld} :
         (o==8'h34) ? tmr :
         ((o>=8'h09)&&(o<=8'h10)) ? io_c[(o-8'h09)*8 +: 8] :
         ((o>=8'h29)&&(o<=8'h30)) ? cnt[(o-8'h29)*8 +: 8] :
         (o<=8'h34) ? dev[o] : ram[o];
endfunction
// fetch returns the aligned 32-bit word, data access puts the addressed byte
// in lane baddr[1:0] (the master bridge extracts it from there)
always@(*) begin
  if(binst)
    brdata = {rraw(roff_r+8'd3),rraw(roff_r+8'd2),rraw(roff_r+8'd1),rraw(roff_r)};
  else
    brdata = {24'd0,rraw(roff_r)} << {off[1:0],3'b000};
end

wire [7:0] wb = fwdata >> {faddr[1:0],3'b000}; // single-byte writes (cpu is byte granular)
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    dev['h04] <= 0;          // page
    dev['h05] <= 0;          // entry lo (legacy)
    dev['h06] <= 0;          // entry hi (legacy)
    dev['h07] <= 0;          // io_os
    dev['h08] <= 0;          // io_is
    dev['h11] <= 0; dev['h12] <= 0; dev['h13] <= 0; dev['h14] <= 0; // io_i
    dev['h15] <= 0; dev['h16] <= 0; dev['h17] <= 0; dev['h18] <= 0;
    dev['h19] <= 0; dev['h1a] <= 0; dev['h1b] <= 0; dev['h1c] <= 0; // io_oe
    dev['h1d] <= 0; dev['h1e] <= 0; dev['h1f] <= 0; dev['h20] <= 0;
    dev['h21] <= 0; dev['h22] <= 0; dev['h23] <= 0; dev['h24] <= 0; // io_ie
    dev['h25] <= 0; dev['h26] <= 0; dev['h27] <= 0; dev['h28] <= 0;
    dev['h31] <= 0;          // tmr_sel
    dev['h32] <= 0;          // tmr_set
    dev['h33] <= 0;          // tmr_from
    dev['h00] <= 'hff;       // s0b
    dev['h01] <= 0;          // s0p
    dev['h02] <= 'hff;       // s1b
    dev['h03] <= 0;          // s1p
  end
  else begin
    if(fwrite) begin
      if(roff_w<=8'h34) dev[roff_w] <= wb;
      // push : alias write bumps the stack pointer
      if(foff==s0b) dev['h01] <= dev['h01]+8'd1;
      if(foff==s1b) dev['h03] <= dev['h03]+8'd1;
    end
    else if(rh) begin
      // pop : alias read drops the stack pointer (after the read data used
      // the pre-decrement value, like the old mfire semantics)
      if(off==s0b) dev['h01] <= dev['h01]-8'd1;
      if(off==s1b) dev['h03] <= dev['h03]-8'd1;
    end
  end
end
always@(posedge clk) begin
  if(fwrite & (roff_w>8'h34)) ram[roff_w] <= wb;
end

// iomux shifter : free-running on the board clock domain (the old io_valid
// pipeline only saved power ; reads of io_c are live now, so no wait states
// are needed behind the axi slave)
wire signed [7:0] io_os = dev['h07];
wire signed [7:0] io_is = dev['h08];
wire [63:0] io_oe_w = {dev['h20],dev['h1f],dev['h1e],dev['h1d],
                       dev['h1c],dev['h1b],dev['h1a],dev['h19]};
wire [63:0] io_i_w  = {dev['h18],dev['h17],dev['h16],dev['h15],
                       dev['h14],dev['h13],dev['h12],dev['h11]};
wire [63:0] io_ie_w = {dev['h28],dev['h27],dev['h26],dev['h25],
                       dev['h24],dev['h23],dev['h22],dev['h21]};
reg [63:0] io_c;
always@(negedge rstb or posedge ioclk) begin
  if(!rstb) begin
    io_i  <= 0;
    io_oe <= 0;
    io_ie <= 0;
    io_c  <= 0;
  end
  else begin
    io_oe <= (io_os < 0) ? (io_oe_w >> (0-io_os)) : (io_oe_w << io_os);
    io_i  <= (io_os < 0) ? (io_i_w  >> (0-io_os)) : (io_i_w  << io_os);
    io_ie <= io_ie_w;
    io_c  <= (io_is < 0) ? (io_o >> (0-io_is)) : (io_o << io_is);
  end
end

axi_s s
(
  .clk(clk), .rstb(rstb),
  .s_axi_awaddr (s_axi_awaddr),
  .s_axi_awvalid(s_axi_awvalid),
  .s_axi_awready(s_axi_awready),
  .s_axi_wdata  (s_axi_wdata),
  .s_axi_wstrb  (s_axi_wstrb),
  .s_axi_wvalid (s_axi_wvalid),
  .s_axi_wready (s_axi_wready),
  .s_axi_bresp  (s_axi_bresp),
  .s_axi_bvalid (s_axi_bvalid),
  .s_axi_bready (s_axi_bready),
  .s_axi_araddr (s_axi_araddr),
  .s_axi_arprot (s_axi_arprot),
  .s_axi_arvalid(s_axi_arvalid),
  .s_axi_arready(s_axi_arready),
  .s_axi_rdata  (s_axi_rdata),
  .s_axi_rresp  (s_axi_rresp),
  .s_axi_rlast  (s_axi_rlast),
  .s_axi_rvalid (s_axi_rvalid),
  .s_axi_rready (s_axi_rready),
  .baddr(baddr), .binst(binst), .rh(rh), .brdata(brdata),
  .faddr(faddr), .fwdata(fwdata), .fwstrb(fwstrb),
  .fwrite(fwrite), .fread(fread)
);

endmodule


// cpu + instruction master + data master + config slave
// config registers (word slots inside the 16B window) :
//   0x0 CTRL : bit0 enable (1=run, 0=hold core in reset), bit1 halt (1=stop)
//   0x4 ENTRY: pc0 instruction fetch offset. the core's pc p always starts at
//              0 and is program-relative ; the instruction master fetches
//              p+ENTRY (16-bit wrap), so a compute cpu runs code placed
//              anywhere in ram by the host. unused when ROM_ONLY=1.
//   0x8 PC   : current program-relative pc (read only)
//   0xc STAT : bit0 halted (read only)
// ROM_ONLY=1 (bios cpu) : instruction fetches are masked into the rom window
// (addr & 0x1fff), the core can never execute outside rom ; the data port is
// unrestricted so it can control every io device on the fabric.
// any master on the fabric (including this cpu's own data port) can reach
// these registers, so cpus can start/stop/reboot each other
module cpu_axi
#(
  parameter BOOT_EN = 1,         // enable after reset
  parameter [31:0] BOOT_IB = 32'h00000000, // IBASE after reset (instruction base)
  parameter [31:0] BOOT_DB = 32'h00000000, // DBASE after reset (data base)
  parameter ROM_ONLY = 0         // 1 = bios cpu : fetch from rom only
)
(
  input              clk   ,
  input              rstb  ,
  output             halt  ,
  // instruction master
  output     [31: 0] im_awaddr  ,
  output             im_awvalid ,
  input              im_awready ,
  output     [31: 0] im_wdata   ,
  output     [ 3: 0] im_wstrb   ,
  output             im_wvalid  ,
  input              im_wready  ,
  input      [ 1: 0] im_bresp   ,
  input              im_bvalid  ,
  output             im_bready  ,
  output     [31: 0] im_araddr  ,
  output     [ 2: 0] im_arprot  ,
  output             im_arvalid ,
  input              im_arready ,
  input      [31: 0] im_rdata   ,
  input      [ 1: 0] im_rresp   ,
  input              im_rvalid  ,
  output             im_rready  ,
  // data master
  output     [31: 0] dm_awaddr  ,
  output             dm_awvalid ,
  input              dm_awready ,
  output     [31: 0] dm_wdata   ,
  output     [ 3: 0] dm_wstrb   ,
  output             dm_wvalid  ,
  input              dm_wready  ,
  input      [ 1: 0] dm_bresp   ,
  input              dm_bvalid  ,
  output             dm_bready  ,
  output     [31: 0] dm_araddr  ,
  output     [ 2: 0] dm_arprot  ,
  output             dm_arvalid ,
  input              dm_arready ,
  input      [31: 0] dm_rdata   ,
  input      [ 1: 0] dm_rresp   ,
  input              dm_rvalid  ,
  output             dm_rready  ,
  // config slave
  input      [31: 0] s_axi_awaddr  ,
  input              s_axi_awvalid ,
  output             s_axi_awready ,
  input      [31: 0] s_axi_wdata   ,
  input      [ 3: 0] s_axi_wstrb   ,
  input              s_axi_wvalid  ,
  output             s_axi_wready  ,
  output     [ 1: 0] s_axi_bresp   ,
  output             s_axi_bvalid  ,
  input              s_axi_bready  ,
  input      [31: 0] s_axi_araddr  ,
  input      [ 2: 0] s_axi_arprot  ,
  input              s_axi_arvalid ,
  output             s_axi_arready ,
  output     [31: 0] s_axi_rdata   ,
  output     [ 1: 0] s_axi_rresp   ,
  output             s_axi_rlast   ,
  output             s_axi_rvalid  ,
  input              s_axi_rready
);

// config register file
reg  [ 1: 0] ctrl;
reg  [31: 0] ib_r; // IBASE : instruction fetch base (was ENTRY/pc0)
reg  [31: 0] db_r; // DBASE : data access base
wire         crstb = rstb & ctrl[0]; // enable=0 holds the core in reset
wire [15: 0] pc;
wire [31: 0] baddr, faddr, fwdata;
wire [ 3: 0] fwstrb;
wire         binst, rh, fwrite, fread;
reg  [31: 0] brdata;

// core : pc is program-relative, starts at 0 ; the fetch offset (ENTRY/pc0)
// is applied at the instruction master below
wire         imready, dmready;
wire [31: 0] imrdata;
wire [31: 0] dmrdata;
wire         imvalid, dmvalid, dmwrite;
wire [ 3: 0] dmwbe;
wire [15: 0] imaddr, dmaddr;
wire [31: 0] dmwdata;
// physical addresses : the core works with 16-bit program-relative offsets,
// the 32-bit base registers move the window anywhere in the address space.
// bios cpu (ROM_ONLY) is locked into the rom window for fetch.
wire [31: 0] im_phys = ROM_ONLY ? (({16'h0,imaddr} + ib_r) & 32'h1fff)
                                :  ({16'h0,imaddr} + ib_r);
wire [31: 0] dm_phys = {16'h0,dmaddr} + db_r;
cpu core
(
  .imready(imready), .imrdata(imrdata), .imvalid(imvalid), .imaddr(imaddr),
  .dmready(dmready), .dmrdata(dmrdata), .dmvalid(dmvalid), .dmaddr(dmaddr),
  .dmwrite(dmwrite), .dmwbe(dmwbe), .dmwdata(dmwdata),
  .rstb (crstb),
  .fhalt(ctrl[1]),
  .halt (halt),
  .pc   (pc),
  .entry(16'd0),
  .clk  (clk)
);

// instruction fetch master
axi_m #(1) im
(
  .clk(clk), .rstb(crstb),
  .req  (imvalid),
  .gnt  (imready),
  .addr (im_phys),
  .write(1'b0),
  .wbe  (4'd0),
  .wdata(32'd0),
  .rdata(),
  .rword(imrdata),
  .m_axi_awaddr (im_awaddr),
  .m_axi_awvalid(im_awvalid),
  .m_axi_awready(im_awready),
  .m_axi_awlen  (),
  .m_axi_awsize (),
  .m_axi_awburst(),
  .m_axi_wdata  (im_wdata),
  .m_axi_wstrb  (im_wstrb),
  .m_axi_wvalid (im_wvalid),
  .m_axi_wready (im_wready),
  .m_axi_wlast  (),
  .m_axi_bresp  (im_bresp),
  .m_axi_bvalid (im_bvalid),
  .m_axi_bready (im_bready),
  .m_axi_araddr (im_araddr),
  .m_axi_arprot (im_arprot),
  .m_axi_arvalid(im_arvalid),
  .m_axi_arready(im_arready),
  .m_axi_arlen  (),
  .m_axi_arsize (),
  .m_axi_arburst(),
  .m_axi_rdata  (im_rdata),
  .m_axi_rresp  (im_rresp),
  .m_axi_rvalid (im_rvalid),
  .m_axi_rlast  (1'b1),
  .m_axi_rready (im_rready)
);

// data access master
axi_m #(0) dm
(
  .clk(clk), .rstb(crstb),
  .req  (dmvalid),
  .gnt  (dmready),
  .addr (dm_phys),
  .write(dmwrite),
  .wbe  (dmwbe),
  .wdata(dmwdata),
  .rdata(dmrdata),
  .rword(),
  .m_axi_awaddr (dm_awaddr),
  .m_axi_awvalid(dm_awvalid),
  .m_axi_awready(dm_awready),
  .m_axi_awlen  (),
  .m_axi_awsize (),
  .m_axi_awburst(),
  .m_axi_wdata  (dm_wdata),
  .m_axi_wstrb  (dm_wstrb),
  .m_axi_wvalid (dm_wvalid),
  .m_axi_wready (dm_wready),
  .m_axi_wlast  (),
  .m_axi_bresp  (dm_bresp),
  .m_axi_bvalid (dm_bvalid),
  .m_axi_bready (dm_bready),
  .m_axi_araddr (dm_araddr),
  .m_axi_arprot (dm_arprot),
  .m_axi_arvalid(dm_arvalid),
  .m_axi_arready(dm_arready),
  .m_axi_arlen  (),
  .m_axi_arsize (),
  .m_axi_arburst(),
  .m_axi_rdata  (dm_rdata),
  .m_axi_rresp  (dm_rresp),
  .m_axi_rvalid (dm_rvalid),
  .m_axi_rlast  (1'b1),
  .m_axi_rready (dm_rready)
);

// config register read (comb, word slots) :
//   0x0 CTRL, 0x4 IBASE, 0x8 DBASE, 0xc STAT (bit0 halted, [31:16] pc)
always@(*) begin
  case(baddr[3:2])
    2'd0    : brdata = {30'd0,ctrl};
    2'd1    : brdata = ib_r;
    2'd2    : brdata = db_r;
    default : brdata = {pc,15'd0,halt};
  endcase
end
// config register write : per-byte through the wstrb lanes, so both byte
// stores (we=0001 at any lane) and full word stores (we=1111) work
integer li;
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    ctrl <= BOOT_EN ? 2'b01 : 2'b00;
    ib_r <= BOOT_IB;
    db_r <= BOOT_DB;
  end
  else if(fwrite) begin
    case(faddr[3:2])
      2'd0    : if(fwstrb[0]) ctrl <= fwdata[1:0];
      2'd1    : for(li=0;li<4;li=li+1)
                  if(fwstrb[li]) ib_r[li*8 +: 8] <= fwdata[li*8 +: 8];
      2'd2    : for(li=0;li<4;li=li+1)
                  if(fwstrb[li]) db_r[li*8 +: 8] <= fwdata[li*8 +: 8];
      default : ; // STAT is read only
    endcase
  end
end

axi_s cfg
(
  .clk(clk), .rstb(rstb),
  .s_axi_awaddr (s_axi_awaddr),
  .s_axi_awvalid(s_axi_awvalid),
  .s_axi_awready(s_axi_awready),
  .s_axi_wdata  (s_axi_wdata),
  .s_axi_wstrb  (s_axi_wstrb),
  .s_axi_wvalid (s_axi_wvalid),
  .s_axi_wready (s_axi_wready),
  .s_axi_bresp  (s_axi_bresp),
  .s_axi_bvalid (s_axi_bvalid),
  .s_axi_bready (s_axi_bready),
  .s_axi_araddr (s_axi_araddr),
  .s_axi_arprot (s_axi_arprot),
  .s_axi_arvalid(s_axi_arvalid),
  .s_axi_arready(s_axi_arready),
  .s_axi_rdata  (s_axi_rdata),
  .s_axi_rresp  (s_axi_rresp),
  .s_axi_rlast  (s_axi_rlast),
  .s_axi_rvalid (s_axi_rvalid),
  .s_axi_rready (s_axi_rready),
  .baddr(baddr), .binst(binst), .rh(rh), .brdata(brdata),
  .faddr(faddr), .fwdata(fwdata), .fwstrb(fwstrb),
  .fwrite(fwrite), .fread(fread)
);

endmodule


// axi interconnect : 4 masters x 4 slaves + default DECERR responder
//   m0 = cpu0 instruction, m1 = cpu0 data, m2 = cpu1 instruction, m3 = cpu1 data
//   s0 = rom 0x0000-0x1fff, s1 = io 0x2000-0x20ff,
//   s2 = cpu0 config 0x3000-0x300f, s3 = cpu1 config 0x3010-0x301f
// per-slave fixed-priority arbitration (lowest master index wins), one
// transaction per slave at a time, different slaves proceed in parallel
// buses are flattened vectors, master/slave k occupies bits [k*w +: w]
// axi interconnect : NM masters x NS slaves + default DECERR responder
//   m0/m1 = cpu0 im/dm, m2/m3 = cpu1, m4/m5 = cpu2, m6/m7 = cpu3
//   s0 = rom 0x0000-0x1fff, s1 = io 0x2000-0x20ff, s2 = uart0 0x2100-0x210f,
//   s3 = ram 0x4000-0x5fff, s4..s7 = cpu0..3 config 0x3000+n*0x10
// per-slave fixed-priority arbitration (lowest master index wins), one
// transaction per slave at a time, different slaves proceed in parallel
// buses are flattened vectors, master/slave k occupies bits [k*w +: w]
module axi_xbar
#(
  parameter NM = 8,
  parameter NS = 8
)
(
  input                  clk   ,
  input                  rstb  ,
  // masters
  input      [NM*32-1:0] m_awaddr  ,
  input      [  NM-1:0]  m_awvalid ,
  output reg [  NM-1:0]  m_awready ,
  input      [NM*32-1:0] m_wdata   ,
  input      [ NM*4-1:0] m_wstrb   ,
  input      [  NM-1:0]  m_wvalid  ,
  output reg [  NM-1:0]  m_wready  ,
  output reg [ NM*2-1:0] m_bresp   ,
  output reg [  NM-1:0]  m_bvalid  ,
  input      [  NM-1:0]  m_bready  ,
  input      [NM*32-1:0] m_araddr  ,
  input      [ NM*3-1:0] m_arprot  ,
  input      [  NM-1:0]  m_arvalid ,
  output reg [  NM-1:0]  m_arready ,
  output reg [NM*32-1:0] m_rdata   ,
  output reg [ NM*2-1:0] m_rresp   ,
  output reg [  NM-1:0]  m_rvalid  ,
  input      [  NM-1:0]  m_rready  ,
  // slaves (slot NS = default DECERR responder, internal)
  output     [NS*32-1:0] s_awaddr  ,
  output     [  NS-1:0]  s_awvalid ,
  input      [  NS-1:0]  s_awready ,
  output     [NS*32-1:0] s_wdata   ,
  output     [ NS*4-1:0] s_wstrb   ,
  output     [  NS-1:0]  s_wvalid  ,
  input      [  NS-1:0]  s_wready  ,
  input      [ NS*2-1:0] s_bresp   ,
  input      [  NS-1:0]  s_bvalid  ,
  output     [  NS-1:0]  s_bready  ,
  output     [NS*32-1:0] s_araddr  ,
  output     [ NS*3-1:0] s_arprot  ,
  output     [  NS-1:0]  s_arvalid ,
  input      [  NS-1:0]  s_arready ,
  input      [NS*32-1:0] s_rdata   ,
  input      [ NS*2-1:0] s_rresp   ,
  input      [  NS-1:0]  s_rvalid  ,
  output     [  NS-1:0]  s_rready
);

localparam NSW = NS+1;                    // slot count incl. default
localparam MW  = (NM>2) ? $clog2(NM) : 1; // master index width
localparam DW  = $clog2(NSW);             // slot/decode width

function [DW-1:0] dec(input [31:0] a);
  integer d;
  begin
    d = (a < 32'h2000) ? 0 : // rom
        (a < 32'h2100) ? 1 : // io
        (a < 32'h2110) ? 2 : // uart0
        (a < 32'h3000) ? NS :
        (a < 32'h3010) ? 4 : // cpu0 config
        (a < 32'h3020) ? 5 : // cpu1 config
        (a < 32'h3030) ? 6 : // cpu2 config
        (a < 32'h3040) ? 7 : // cpu3 config
        (a < 32'h4000) ? NS :
        (a < 32'h6000) ? 3 : // ram
        NS;
    dec = d[DW-1:0];
  end
endfunction

// full NSW-slot internal buses (slot NS = default responder)
reg  [NSW*32-1:0] si_araddr, si_awaddr, si_wdata;
reg  [NSW* 4-1:0] si_wstrb;
reg  [NSW* 3-1:0] si_arprot;
reg  [  NSW-1:0]  si_arvalid, si_awvalid, si_wvalid, si_rready, si_bready;
wire [  NSW-1:0]  si_arready = {1'b1,s_arready};
wire [  NSW-1:0]  si_awready = {1'b1,s_awready};
wire [  NSW-1:0]  si_wready  = {1'b1,s_wready};
wire [NSW*32-1:0] si_rdata   = {32'd0,s_rdata};
wire [NSW* 2-1:0] si_rresp   = {2'b11,s_rresp};
wire [NSW* 2-1:0] si_bresp   = {2'b11,s_bresp};
reg                   df_rvalid, df_bvalid;
wire [  NSW-1:0]  si_rvalid  = {df_rvalid,s_rvalid};
wire [  NSW-1:0]  si_bvalid  = {df_bvalid,s_bvalid};
assign s_araddr  = si_araddr[NS*32-1:0];
assign s_arprot  = si_arprot[NS*3-1:0];
assign s_arvalid = si_arvalid[NS-1:0];
assign s_awaddr  = si_awaddr[NS*32-1:0];
assign s_awvalid = si_awvalid[NS-1:0];
assign s_wdata   = si_wdata[NS*32-1:0];
assign s_wstrb   = si_wstrb[NS*4-1:0];
assign s_wvalid  = si_wvalid[NS-1:0];
assign s_rready  = si_rready[NS-1:0];
assign s_bready  = si_bready[NS-1:0];

reg [NSW-1:0] rbusy, wbusy;
reg [MW-1:0] rg [0:NS]; // read grant per slave
reg [MW-1:0] wg [0:NS]; // write grant per slave
reg [NSW-1:0] rany, wany;
reg [MW-1:0] rsel [0:NS];
reg [MW-1:0] wsel [0:NS];
integer ci, cs;
reg [DW-1:0] rdi, wdi;
always@(*) begin
  rany = 0;
  wany = 0;
  for(cs=0;cs<NSW;cs=cs+1) begin
    rsel[cs] = 0;
    wsel[cs] = 0;
    for(ci=0;ci<NM;ci=ci+1) begin
      if(!rany[cs] && m_arvalid[ci] && (dec(m_araddr[ci*32 +: 32])==cs) && !rbusy[cs]) begin
        rany[cs] = 1;
        rsel[cs] = ci;
      end
      if(!wany[cs] && m_awvalid[ci] && (dec(m_awaddr[ci*32 +: 32])==cs) && !wbusy[cs]) begin
        wany[cs] = 1;
        wsel[cs] = ci;
      end
    end
    si_arvalid[cs] = rany[cs] & m_arvalid[rsel[cs]];
    si_araddr[cs*32 +: 32] = m_araddr[rsel[cs]*32 +: 32];
    si_arprot[cs*3 +: 3] = m_arprot[rsel[cs]*3 +: 3];
    si_awvalid[cs] = wany[cs] & m_awvalid[wsel[cs]];
    si_awaddr[cs*32 +: 32] = m_awaddr[wsel[cs]*32 +: 32];
    si_wvalid[cs]  = wany[cs] & m_wvalid[wsel[cs]];
    si_wdata[cs*32 +: 32] = m_wdata[wsel[cs]*32 +: 32];
    si_wstrb[cs*4 +: 4]  = m_wstrb[wsel[cs]*4 +: 4];
    si_rready[cs] = rbusy[cs] & m_rready[rg[cs]];
    si_bready[cs] = wbusy[cs] & m_bready[wg[cs]];
  end
  for(ci=0;ci<NM;ci=ci+1) begin
    rdi = dec(m_araddr[ci*32 +: 32]);
    wdi = dec(m_awaddr[ci*32 +: 32]);
    m_arready[ci] = rany[rdi] & (rsel[rdi]==ci) & si_arready[rdi];
    m_awready[ci] = wany[wdi] & (wsel[wdi]==ci) & si_awready[wdi];
    m_wready[ci]  = wany[wdi] & (wsel[wdi]==ci) & si_wready[wdi];
    m_rvalid[ci] = 0;
    m_rdata[ci*32 +: 32] = 0;
    m_rresp[ci*2 +: 2] = 0;
    m_bvalid[ci] = 0;
    m_bresp[ci*2 +: 2] = 0;
    for(cs=0;cs<NSW;cs=cs+1) begin
      if(rbusy[cs] && (rg[cs]==ci)) begin
        m_rvalid[ci] = si_rvalid[cs];
        m_rdata[ci*32 +: 32] = si_rdata[cs*32 +: 32];
        m_rresp[ci*2 +: 2] = si_rresp[cs*2 +: 2];
      end
      if(wbusy[cs] && (wg[cs]==ci)) begin
        m_bvalid[ci] = si_bvalid[cs];
        m_bresp[ci*2 +: 2] = si_bresp[cs*2 +: 2];
      end
    end
  end
end

wire [NSW-1:0] rhsk = si_arvalid & si_arready;
wire [NSW-1:0] whsk = si_awvalid & si_awready & si_wvalid & si_wready;
integer si;
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    rbusy <= 0;
    wbusy <= 0;
    df_rvalid <= 0;
    df_bvalid <= 0;
    for(si=0;si<NSW;si=si+1) begin
      rg[si] <= 0;
      wg[si] <= 0;
    end
  end
  else begin
    for(si=0;si<NSW;si=si+1) begin
      if(si_rvalid[si] & si_rready[si]) rbusy[si] <= 1'b0;
      if(rhsk[si]) begin
        rbusy[si] <= 1'b1;
        rg[si] <= rsel[si];
      end
      if(si_bvalid[si] & si_bready[si]) wbusy[si] <= 1'b0;
      if(whsk[si]) begin
        wbusy[si] <= 1'b1;
        wg[si] <= wsel[si];
      end
    end
    // default responder : 1-cycle DECERR for unmapped addresses
    if(df_rvalid & si_rready[NS]) df_rvalid <= 1'b0;
    if(rhsk[NS]) df_rvalid <= 1'b1;
    if(df_bvalid & si_bready[NS]) df_bvalid <= 1'b0;
    if(whsk[NS]) df_bvalid <= 1'b1;
  end
end

endmodule


//=========================================================================
// mesh_router : 5-port NoC router for a 4x4 mesh, xy dimension-order
// routing (x first, then y -> deadlock free). ports 0=E 1=W 2=N 3=S 4=L,
// each port is one axi slave (traffic in) + one axi master (traffic out).
// per-output fixed-priority arbitration (lowest input index wins), one
// transaction per output at a time, held until B/R completes. addresses
// outside the map are answered locally with DECERR and never enter the mesh.
//
// global address -> node map (node id = y*4+x) :
//   node0 = rom 0x0000-0x1fff , node1 = io 0x2000-0x20ff
//   node2 = uart0 0x2100-0x210f , node3 = ram 0x4000-0x5fff
//   node4..15 = cpu0..11 config 0x3000+k*0x10 (k = node-4)
module mesh_router
#(
  parameter X = 0, // this router's mesh coordinates
  parameter Y = 0
)
(
  input                  clk   ,
  input                  rstb  ,
  // slave ports (traffic entering) : packed, port p at [p*w +: w]
  input      [5*32-1:0]  s_awaddr  ,
  input      [  4:0]     s_awvalid ,
  output reg [  4:0]     s_awready ,
  input      [5*32-1:0]  s_wdata   ,
  input      [5* 4-1:0]  s_wstrb   ,
  input      [  4:0]     s_wvalid  ,
  output reg [  4:0]     s_wready  ,
  output reg [5* 2-1:0]  s_bresp   ,
  output reg [  4:0]     s_bvalid  ,
  input      [  4:0]     s_bready  ,
  input      [5*32-1:0]  s_araddr  ,
  input      [5* 3-1:0]  s_arprot  ,
  input      [  4:0]     s_arvalid ,
  output reg [  4:0]     s_arready ,
  output reg [5*32-1:0]  s_rdata   ,
  output reg [5* 2-1:0]  s_rresp   ,
  output reg [  4:0]     s_rvalid  ,
  input      [  4:0]     s_rready  ,
  // master ports (traffic leaving) : same port order
  output reg [5*32-1:0]  m_awaddr  ,
  output reg [  4:0]     m_awvalid ,
  input      [  4:0]     m_awready ,
  output reg [5*32-1:0]  m_wdata   ,
  output reg [5* 4-1:0]  m_wstrb   ,
  output reg [  4:0]     m_wvalid  ,
  input      [  4:0]     m_wready  ,
  input      [5* 2-1:0]  m_bresp   ,
  input      [  4:0]     m_bvalid  ,
  output reg [  4:0]     m_bready  ,
  output reg [5*32-1:0]  m_araddr  ,
  output reg [5* 3-1:0]  m_arprot  ,
  output reg [  4:0]     m_arvalid ,
  input      [  4:0]     m_arready ,
  input      [5*32-1:0]  m_rdata   ,
  input      [5* 2-1:0]  m_rresp   ,
  input      [  4:0]     m_rvalid  ,
  output reg [  4:0]     m_rready
);

localparam [2:0] RE = 3'd0, RW = 3'd1, RN = 3'd2, RS = 3'd3, RL = 3'd4,
                 RERR = 3'd5; // unroutable : local DECERR, never leaves the port

// xy route : address -> node -> direction
function [2:0] rte(input [31:0] a);
  integer node, tx, ty;
  begin
    node = (a < 32'h2000) ? 0  : // rom
           (a < 32'h2100) ? 1  : // io
           (a < 32'h2110) ? 2  : // uart0
           (a < 32'h3000) ? 99 :
           (a < 32'h30c0) ? (4 + (a - 32'h3000) / 16) : // cpu0..11 config
           (a < 32'h4000) ? 99 :
           (a < 32'h6000) ? 3  : // ram
           99;
    if(node > 15) rte = RERR;
    else begin
      tx = node % 4;
      ty = node / 4;
      if     (tx > X) rte = RE;
      else if(tx < X) rte = RW;
      else if(ty > Y) rte = RS;
      else if(ty < Y) rte = RN;
      else            rte = RL;
    end
  end
endfunction

// per-input local DECERR responders (unmapped addresses)
reg [4:0] er_rvalid, er_bvalid;

reg [4:0] rbusy, wbusy;
reg [2:0] rg [0:4]; // read grant per output
reg [2:0] wg [0:4]; // write grant per output
reg [4:0] rany, wany;
reg [2:0] rsel [0:4];
reg [2:0] wsel [0:4];
integer ci, cs;
reg [2:0] rdi, wdi;
always@(*) begin
  rany = 0;
  wany = 0;
  for(cs=0;cs<5;cs=cs+1) begin
    rsel[cs] = 0;
    wsel[cs] = 0;
    for(ci=0;ci<5;ci=ci+1) begin
      if(!rany[cs] && s_arvalid[ci] && (rte(s_araddr[ci*32 +: 32])==cs) && !rbusy[cs]) begin
        rany[cs] = 1;
        rsel[cs] = ci;
      end
      if(!wany[cs] && s_awvalid[ci] && (rte(s_awaddr[ci*32 +: 32])==cs) && !wbusy[cs]) begin
        wany[cs] = 1;
        wsel[cs] = ci;
      end
    end
    m_arvalid[cs] = rany[cs] & s_arvalid[rsel[cs]];
    m_araddr[cs*32 +: 32] = s_araddr[rsel[cs]*32 +: 32];
    m_arprot[cs*3 +: 3] = s_arprot[rsel[cs]*3 +: 3];
    m_awvalid[cs] = wany[cs] & s_awvalid[wsel[cs]];
    m_awaddr[cs*32 +: 32] = s_awaddr[wsel[cs]*32 +: 32];
    m_wvalid[cs]  = wany[cs] & s_wvalid[wsel[cs]];
    m_wdata[cs*32 +: 32] = s_wdata[wsel[cs]*32 +: 32];
    m_wstrb[cs*4 +: 4]  = s_wstrb[wsel[cs]*4 +: 4];
    m_rready[cs] = rbusy[cs] & s_rready[rg[cs]];
    m_bready[cs] = wbusy[cs] & s_bready[wg[cs]];
  end
  for(ci=0;ci<5;ci=ci+1) begin
    rdi = rte(s_araddr[ci*32 +: 32]);
    wdi = rte(s_awaddr[ci*32 +: 32]);
    s_arready[ci] = (rdi==RERR) ? ~er_rvalid[ci]
                  : (rany[rdi] & (rsel[rdi]==ci) & m_arready[rdi]);
    s_awready[ci] = (wdi==RERR) ? ~er_bvalid[ci]
                  : (wany[wdi] & (wsel[wdi]==ci) & m_awready[wdi]);
    s_wready[ci]  = (wdi==RERR) ? ~er_bvalid[ci]
                  : (wany[wdi] & (wsel[wdi]==ci) & m_wready[wdi]);
    s_rvalid[ci] = er_rvalid[ci];
    s_rdata[ci*32 +: 32] = 32'd0;
    s_rresp[ci*2 +: 2] = 2'b11;
    s_bvalid[ci] = er_bvalid[ci];
    s_bresp[ci*2 +: 2] = 2'b11;
    for(cs=0;cs<5;cs=cs+1) begin
      if(rbusy[cs] && (rg[cs]==ci)) begin
        s_rvalid[ci] = m_rvalid[cs];
        s_rdata[ci*32 +: 32] = m_rdata[cs*32 +: 32];
        s_rresp[ci*2 +: 2] = m_rresp[cs*2 +: 2];
      end
      if(wbusy[cs] && (wg[cs]==ci)) begin
        s_bvalid[ci] = m_bvalid[cs];
        s_bresp[ci*2 +: 2] = m_bresp[cs*2 +: 2];
      end
    end
  end
end

wire [4:0] rhsk = m_arvalid & m_arready;
wire [4:0] whsk = m_awvalid & m_awready & m_wvalid & m_wready;
integer si;
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    rbusy <= 0;
    wbusy <= 0;
    er_rvalid <= 0;
    er_bvalid <= 0;
    for(si=0;si<5;si=si+1) begin
      rg[si] <= 0;
      wg[si] <= 0;
    end
  end
  else begin
    for(si=0;si<5;si=si+1) begin
      if(m_rvalid[si] & m_rready[si]) rbusy[si] <= 1'b0;
      if(rhsk[si]) begin
        rbusy[si] <= 1'b1;
        rg[si] <= rsel[si];
      end
      if(m_bvalid[si] & m_bready[si]) wbusy[si] <= 1'b0;
      if(whsk[si]) begin
        wbusy[si] <= 1'b1;
        wg[si] <= wsel[si];
      end
      // local DECERR responders (our masters always drive AW+W together)
      if(er_rvalid[si] & s_rready[si]) er_rvalid[si] <= 1'b0;
      else if(s_arvalid[si] & (rte(s_araddr[si*32 +: 32])==RERR) & ~er_rvalid[si])
        er_rvalid[si] <= 1'b1;
      if(er_bvalid[si] & s_bready[si]) er_bvalid[si] <= 1'b0;
      else if(s_awvalid[si] & s_wvalid[si] & (rte(s_awaddr[si*32 +: 32])==RERR) & ~er_bvalid[si])
        er_bvalid[si] <= 1'b1;
    end
  end
end

endmodule


// cpu_locmux : merges a cpu's instruction + data masters into the router's
// local slave port. the 2-state core never has im and dm requests in flight
// at the same time and im never writes, so only the read channel needs an
// owner flag for the response routing.
module cpu_locmux
(
  input              clk   ,
  input              rstb  ,
  // cpu instruction master (read only)
  input      [31: 0] im_araddr  ,
  input      [ 2: 0] im_arprot  ,
  input              im_arvalid ,
  output             im_arready ,
  output     [31: 0] im_rdata   ,
  output     [ 1: 0] im_rresp   ,
  output             im_rvalid  ,
  input              im_rready  ,
  // cpu data master
  input      [31: 0] dm_awaddr  ,
  input              dm_awvalid ,
  output             dm_awready ,
  input      [31: 0] dm_wdata   ,
  input      [ 3: 0] dm_wstrb   ,
  input              dm_wvalid  ,
  output             dm_wready  ,
  output     [ 1: 0] dm_bresp   ,
  output             dm_bvalid  ,
  input              dm_bready  ,
  input      [31: 0] dm_araddr  ,
  input      [ 2: 0] dm_arprot  ,
  input              dm_arvalid ,
  output             dm_arready ,
  output     [31: 0] dm_rdata   ,
  output     [ 1: 0] dm_rresp   ,
  output             dm_rvalid  ,
  input              dm_rready  ,
  // router local slave port
  output     [31: 0] l_awaddr   ,
  output             l_awvalid  ,
  input              l_awready  ,
  output     [31: 0] l_wdata    ,
  output     [ 3: 0] l_wstrb    ,
  output             l_wvalid   ,
  input              l_wready   ,
  input      [ 1: 0] l_bresp    ,
  input              l_bvalid   ,
  output             l_bready   ,
  output     [31: 0] l_araddr   ,
  output     [ 2: 0] l_arprot   ,
  output             l_arvalid  ,
  input              l_arready  ,
  input      [31: 0] l_rdata    ,
  input      [ 1: 0] l_rresp    ,
  input              l_rvalid   ,
  output             l_rready
);

reg rowner; // 1 = im owns the in-flight read
always@(negedge rstb or posedge clk)
  if(!rstb) rowner <= 1'b0;
  else if(l_arvalid & l_arready) rowner <= im_arvalid;

assign l_arvalid  = im_arvalid | dm_arvalid;
assign l_araddr   = im_arvalid ? im_araddr : dm_araddr;
assign l_arprot   = im_arvalid ? im_arprot : dm_arprot;
assign im_arready = l_arready & im_arvalid;
assign dm_arready = l_arready & ~im_arvalid & dm_arvalid;
assign im_rvalid  = l_rvalid &  rowner;
assign dm_rvalid  = l_rvalid & ~rowner;
assign im_rdata   = l_rdata;
assign im_rresp   = l_rresp;
assign dm_rdata   = l_rdata;
assign dm_rresp   = l_rresp;
assign l_rready   = rowner ? im_rready : dm_rready;
// writes : dm only (im is read only)
assign l_awaddr   = dm_awaddr;
assign l_awvalid  = dm_awvalid;
assign dm_awready = l_awready;
assign l_wdata    = dm_wdata;
assign l_wstrb    = dm_wstrb;
assign l_wvalid   = dm_wvalid;
assign dm_wready  = l_wready;
assign dm_bresp   = l_bresp;
assign dm_bvalid  = l_bvalid;
assign l_bready   = dm_bready;

endmodule


module counter 
#(
  parameter MSB=7 
)
(
  output reg [7:0] tmr, 
  input [7:0] from, 
  output reg vld, 
  input set, 
  input [7:0] sel, 
  output reg [MSB:0] cnt, 
  input rstb, clk 
);

wire [MSB:0] c = {~cnt[MSB-1:0],clk};
genvar k;
generate
for(k=0;k<=MSB;k=k+1) begin : bth
always@(negedge rstb or posedge c[k]) if(!rstb) cnt[k] <= 0; else cnt[k] <= ~cnt[k];
end
endgenerate
wire lck = (cnt >> sel) & 1'b1;
always@(posedge lck) begin
  if(!set) begin
    vld <= 0;
    tmr <= from;
  end
  else begin
    vld <= 1;
    if(|tmr) tmr <= tmr - 1;
  end
end
endmodule


module pad (io, o, i, ie, oe);
inout io;
output o;
input i, ie, oe;
assign o = io && ie;
assign io = oe ? i : 1'bz;
endmodule


// soc : 12 cpus + rom + io + uart0 + ram on a 4x4 axi mesh, no pads, no pll
//   clk = bus clock (lck), ioclk = board clock (pins / counter domains)
//   node layout (node id = y*4+x) :
//     y=0 : rom io uart0 ram          (devices)
//     y=1 : cpu0(bios) cpu1 cpu2 cpu3
//     y=2 : cpu4 cpu5 cpu6 cpu7       (compute)
//     y=3 : cpu8 cpu9 cpu10 cpu11     (compute)
//   cpu0 = bios cpu : fetch locked to rom, boots at reset, controls all io
//   cpu1..11 = compute cpus : fetch IBASE+p from ram, started via their config
`include "mesh.v"

// soc : mesh_top (generated by sw.lisp --aximesh, config = the *aximesh* list)
//   inside a thin wrapper ; conceptually soc_top = mesh_top + pads
//   clk = bus clock (lck), ioclk = board clock (pins / counter domains)
//   node layout (node id = y*4+x) :
//     y=0 : rom io uart0 ram          (devices)
//     y=1 : cpu0(bios) cpu1 cpu2 cpu3
//     y=2 : cpu4 cpu5 cpu6 cpu7       (compute)
//     y=3 : cpu8 cpu9 cpu10 cpu11     (compute)
//   cpu0 = bios cpu : fetch locked to rom, boots at reset, controls all io
//   cpu1..11 = compute cpus : fetch IBASE+p from ram, started via their config
module smol_soc
(
  output [63:0] io_i, io_oe, io_ie,
  input  [63:0] io_o,
  output        halt,
  output [ 7:0] debug,
  input         uart0_rx,
  output        uart0_tx,
  input         ioclk,
  input         rstb,
  input         clk
);

mesh_top msh
(
  .io_i(io_i), .io_oe(io_oe), .io_ie(io_ie), .io_o(io_o),
  .halt(halt), .debug(debug),
  .uart0_rx(uart0_rx), .uart0_tx(uart0_tx),
  .ioclk(ioclk), .rstb(rstb), .clk(clk)
);

endmodule


module pll (input rstb, clk, output reg vld, lck);
`ifdef SIM
initial lck = 0;
always #4 lck = ~lck;
`elsif SAED32
wire       REF_CLK = clk;
wire       FB_CLK = 1'b0;
wire       FB_MODE = 1'b0;
wire       PLL_BYPASS = 1'b0;
wire        CLK_4X,CLK_2X,CLK_1X;
PLL
u_pll 
(
  .REF_CLK(REF_CLK),
  .FB_CLK(FB_CLK),
  .FB_MODE(FB_MODE),
  .PLL_BYPASS(PLL_BYPASS),

  .CLK_4X(CLK_4X),
  .CLK_2X(CLK_2X),
  .CLK_1X(CLK_1X)
  );
always@(*) lck = CLK_4X;
`elsif ALTERA
wire [4:0] sub_wire0;
wire [0:0] sub_wire4 = 1'h0;
wire [0:0] sub_wire1 = sub_wire0[0:0];
always@(*) lck = sub_wire1;
wire  sub_wire2 = clk;
wire [1:0] sub_wire3 = {sub_wire4, sub_wire2};
altpll altpll_component (
  .inclk (sub_wire3),
  .clk (sub_wire0),
  .areset (1'b0),
  .clkena ({6{1'b1}}),
  .clkswitch (1'b0),
  .configupdate (1'b0),
  .pfdena (1'b1),
  .phasecounterselect ({4{1'b1}}),
  .phasestep (1'b1),
  .phaseupdown (1'b1),
  .pllena (1'b1));
defparam
  altpll_component.bandwidth_type = "AUTO",
  altpll_component.clk0_duty_cycle = 50,
  altpll_component.clk0_divide_by = 5,
  altpll_component.clk0_multiply_by = 10,
  altpll_component.clk0_phase_shift = "0",
  altpll_component.compensate_clock = "CLK0",
  altpll_component.inclk0_input_frequency = 50000,
  altpll_component.intended_device_family = "Cyclone IV E",
  altpll_component.lpm_hint = "CBX_MODULE_PREFIX=pll_pixel_clock",
  altpll_component.lpm_type = "altpll",
  altpll_component.operation_mode = "NORMAL",
  altpll_component.pll_type = "AUTO",
  altpll_component.width_clock = 5;
`elsif XILINX
wire pll_fb, locked;
wire _lck;
PLLE2_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKFBOUT_MULT(8),  
    .CLKIN1_PERIOD(8.0), 
    .CLKOUT0_DIVIDE(4), 
    .CLKOUT0_DUTY_CYCLE(0.5),
    .DIVCLK_DIVIDE(1)   
) pll_inst (
    .CLKIN1(clk),      
    .CLKFBIN(pll_fb),  
    .CLKFBOUT(pll_fb), 
    .RST(1'b0),        
    .CLKOUT0(_lck),     
    .LOCKED(locked)    
);
always@(*) lck = _lck;
`else
always@(*) lck = clk;
`endif
always@(negedge rstb or posedge lck) if(!rstb) vld <= 0; else vld <= 1;
endmodule


module macro0
(
  input rx, 
  output tx, 
  output halt,
  input rx0,
  output tx0,
  input vld, lck,
  input rstb, clk 
);

wire [7:0] debug;
wire [63:0] io_i, io_oe, io_ie;
wire [63:0] io_o;

smol_soc
soc (
  io_i, io_oe, io_ie,
  io_o,
  halt,
  debug,
  rx0, tx0,
  clk,
  vld, lck
);

assign io_o = (rx<<1) | 64'd0;
assign tx = (io_i>>0) & 1'b1;

endmodule


module macro1
(
  input rx, 
  output tx, 
  output halt,
  input rx0,
  output tx0,
  input rstb, clk 
);

wire [7:0] debug;
wire [63:0] io_i, io_oe, io_ie;
wire [63:0] io_o;

wire vld, lck;
pll pll (rstb, clk, vld, lck);

smol_soc
soc (
  io_i, io_oe, io_ie,
  io_o,
  halt,
  debug,
  rx0, tx0,
  clk,
  vld, lck
);

assign io_o = (rx<<1) | 64'd0;
assign tx = (io_i>>0) & 1'b1;

endmodule


module macro2
(
  input rx, 
  output tx, 
  output halt,
  input rx0,
  output tx0,
  input clk 
);

reg rstb;
initial rstb = 0;
always@(posedge clk) rstb = 1;

wire [7:0] debug;
wire [63:0] io_i, io_oe, io_ie;
wire [63:0] io_o;

wire vld, lck;
pll pll (rstb, clk, vld, lck);

smol_soc
soc (
  io_i, io_oe, io_ie,
  io_o,
  halt,
  debug,
  rx0, tx0,
  clk,
  vld, lck
);

assign io_o = (rx<<1) | 64'd0;
assign tx = (io_i>>0) & 1'b1;

endmodule


module top
(
  inout [63:0] io, 
  output halt,
  input uart0_rx,
  output uart0_tx,
  input rstb, clk 
);

wire [7:0] debug;
wire [63:0] io_i, io_oe, io_ie;
wire [63:0] io_o;

wire vld, lck;
pll pll (rstb, clk, vld, lck);

smol_soc
soc (
  io_i, io_oe, io_ie,
  io_o,
  halt,
  debug,
  uart0_rx, uart0_tx,
  clk,
  vld, lck
);

generate
genvar io_k;
for(io_k=0;io_k<=63;io_k=io_k+1) begin : io_bth 
pad u_io (io[io_k], io_o[io_k], io_i[io_k], io_ie[io_k], io_oe[io_k]);
end
endgenerate

endmodule


`ifdef SIM
module tb;

wire [63:0] io;
wire halt;
reg rstb, clk;
top top 
(
  .io(io), 
  .halt(halt),
  .uart0_rx(1'b1), .uart0_tx(),
  .rstb(rstb), .clk(clk) 
);

initial clk = 0;
always #10 clk = ~clk;
wire [7:0] ram_0x00 = top.soc.msh.iodev.dev['h00];
wire [7:0] ram_0x01 = top.soc.msh.iodev.dev['h01];
wire [7:0] ram_0x02 = top.soc.msh.iodev.dev['h02];
wire [7:0] ram_0x03 = top.soc.msh.iodev.dev['h03];
wire [7:0] ram_0x04 = top.soc.msh.iodev.dev['h04];
wire [7:0] ram_0x05 = top.soc.msh.iodev.dev['h05];
wire [7:0] ram_0x06 = top.soc.msh.iodev.dev['h06];
wire [7:0] ram_0x07 = top.soc.msh.iodev.dev['h07];
wire [7:0] ram_0x08 = top.soc.msh.iodev.dev['h08];
wire [7:0] ram_0x09 = top.soc.msh.iodev.dev['h09];
wire [7:0] ram_0x0a = top.soc.msh.iodev.dev['h0a];
wire [7:0] ram_0x0b = top.soc.msh.iodev.dev['h0b];
wire [7:0] ram_0x0c = top.soc.msh.iodev.dev['h0c];
wire [7:0] ram_0x0d = top.soc.msh.iodev.dev['h0d];
wire [7:0] ram_0x0e = top.soc.msh.iodev.dev['h0e];
wire [7:0] ram_0x0f = top.soc.msh.iodev.dev['h0f];
wire [7:0] ram_0x10 = top.soc.msh.iodev.dev['h10];
wire [7:0] ram_0x11 = top.soc.msh.iodev.dev['h11];
wire [7:0] ram_0x12 = top.soc.msh.iodev.dev['h12];
wire [7:0] ram_0x13 = top.soc.msh.iodev.dev['h13];
wire [7:0] ram_0x31 = top.soc.msh.iodev.dev['h31];
wire [7:0] ram_0x32 = top.soc.msh.iodev.dev['h32];
wire [7:0] ram_0x33 = top.soc.msh.iodev.dev['h33];
wire [7:0] ram_0x34 = top.soc.msh.iodev.dev['h34];
wire [7:0] ram_0x35 = top.soc.msh.iodev.ram['h35];
wire [7:0] ram_0x36 = top.soc.msh.iodev.ram['h36];
wire [7:0] ram_0x37 = top.soc.msh.iodev.ram['h37];
wire [7:0] ram_0x38 = top.soc.msh.iodev.ram['h38];
wire [7:0] ram_0x39 = top.soc.msh.iodev.ram['h39];
wire [7:0] ram_0x3a = top.soc.msh.iodev.ram['h3a];
wire [7:0] ram_0x3b = top.soc.msh.iodev.ram['h3b];
wire [7:0] ram_0x3c = top.soc.msh.iodev.ram['h3c];
wire [7:0] ram_0x3d = top.soc.msh.iodev.ram['h3d];
wire [7:0] ram_0x3e = top.soc.msh.iodev.ram['h3e];
wire [7:0] ram_0x3f = top.soc.msh.iodev.ram['h3f];
wire [7:0] ram_0x40 = top.soc.msh.iodev.ram['h40];

reg key1;
initial key1 = 1;
always@(posedge clk) begin
  repeat(100000) @(posedge clk);
  key1 = ~key1;
end
assign io[1] = key1 ? 1'bz : 1'b0;

initial begin
  rstb = 0;
  repeat(3) @(posedge clk);
  rstb = 1;
end

endmodule
`endif


// uart0 : minimal hardware uart as an AXI slave, byte registers
//   0x0 DATA : write starts a tx frame (10 bits : start, 8 data lsb first,
//              stop) ; read returns the last rx byte and clears
//              rx_valid/overrun
//   0x4 STAT : read : bit0 tx_busy, bit1 rx_valid, bit2 rx overrun
//   0x8 DIV  : 16-bit bit-period divider in clk cycles (lo@0x8, hi@0x9)
module smol_uart
#(
  parameter DIV0 = 16'd1085 // 115200 baud from a 125MHz bus clock
)
(
  input              clk   ,
  input              rstb  ,
  input              rx    ,
  output reg         tx    ,
  input      [31: 0] s_axi_awaddr  ,
  input              s_axi_awvalid ,
  output             s_axi_awready ,
  input      [31: 0] s_axi_wdata   ,
  input      [ 3: 0] s_axi_wstrb   ,
  input              s_axi_wvalid  ,
  output             s_axi_wready  ,
  output     [ 1: 0] s_axi_bresp   ,
  output             s_axi_bvalid  ,
  input              s_axi_bready  ,
  input      [31: 0] s_axi_araddr  ,
  input      [ 2: 0] s_axi_arprot  ,
  input              s_axi_arvalid ,
  output             s_axi_arready ,
  output     [31: 0] s_axi_rdata   ,
  output     [ 1: 0] s_axi_rresp   ,
  output             s_axi_rlast   ,
  output             s_axi_rvalid  ,
  input              s_axi_rready
);

wire [31: 0] baddr, faddr, fwdata;
wire [ 3: 0] fwstrb;
wire         binst, rh, fwrite, fread;
reg  [31: 0] brdata;
wire [ 3: 0] off  = baddr[3:0];
wire [ 3: 0] foff = faddr[3:0];
wire [ 7: 0] wb   = fwdata >> {faddr[1:0],3'b000};

reg [15: 0] div;
// tx : shift register of the frame, one bit per div cycles
reg          tbusy;
reg  [ 9: 0] tsh;
reg  [ 3: 0] tbc;
reg  [15: 0] tdiv;
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    tx    <= 1'b1;
    tbusy <= 1'b0;
    tsh   <= {10{1'b1}};
    tbc   <= 0;
    tdiv  <= 0;
  end
  else if(fwrite & (foff==4'h0) & ~tbusy) begin
    tsh   <= {1'b1,wb,1'b0}; // stop, data, start
    tx    <= 1'b0;           // start bit
    tbc   <= 4'd10;
    tdiv  <= 16'd0;
    tbusy <= 1'b1;
  end
  else if(tbusy) begin
    if(tdiv >= div-16'd1) begin
      tdiv <= 16'd0;
      tx   <= tsh[1];
      tsh  <= {1'b1,tsh[9:1]};
      tbc  <= tbc - 4'd1;
      if(tbc==4'd1) tbusy <= 1'b0; // stop bit fully on the line
    end
    else tdiv <= tdiv + 16'd1;
  end
end
// rx : 2-flop sync, start-edge detect, sample at mid-bit
reg          rbusy, rvld, ovf;
reg  [ 7: 0] rsh, rdat;
reg  [ 3: 0] rbc;
reg  [15: 0] rdiv;
reg          rx1, rx2;
always@(negedge rstb or posedge clk) begin
  if(!rstb) begin
    rbusy <= 1'b0; rvld <= 1'b0; ovf <= 1'b0;
    rsh <= 0; rdat <= 0; rbc <= 0; rdiv <= 0;
    rx1 <= 1'b1; rx2 <= 1'b1;
  end
  else begin
    rx1 <= rx;
    rx2 <= rx1;
    if(!rbusy) begin
      if(!rx2) begin // start edge : next sample at mid first data bit
        rbusy <= 1'b1;
        rdiv  <= div + {1'b0,div[15:1]}; // 1.5 bit periods
        rbc   <= 4'd0;
      end
    end
    else if(rdiv==16'd0) begin
      if(rbc==4'd8) begin // stop bit sample point
        rbusy <= 1'b0;
        if(rvld) ovf <= 1'b1;
        rdat  <= rsh;
        rvld  <= 1'b1;
      end
      else begin
        rdiv <= div;
        rsh  <= {rx2,rsh[7:1]};
        rbc  <= rbc + 4'd1;
      end
    end
    else rdiv <= rdiv - 16'd1;
    if(rh & (off==4'h0)) begin // DATA read clears the rx flags
      rvld <= 1'b0;
      ovf  <= 1'b0;
    end
  end
end
// register file
always@(negedge rstb or posedge clk) begin
  if(!rstb) div <= DIV0;
  else if(fwrite) begin
    if(foff==4'h8) div[ 7:0] <= wb;
    if(foff==4'h9) div[15:8] <= wb;
  end
end
always@(*) begin
  case(baddr[3:2])
    2'd0    : brdata = {24'd0,rdat};
    2'd1    : brdata = {29'd0,ovf,rvld,tbusy};
    2'd2    : brdata = {16'd0,div};
    default : brdata = 32'd0;
  endcase
end

axi_s s
(
  .clk(clk), .rstb(rstb),
  .s_axi_awaddr (s_axi_awaddr),
  .s_axi_awvalid(s_axi_awvalid),
  .s_axi_awready(s_axi_awready),
  .s_axi_wdata  (s_axi_wdata),
  .s_axi_wstrb  (s_axi_wstrb),
  .s_axi_wvalid (s_axi_wvalid),
  .s_axi_wready (s_axi_wready),
  .s_axi_bresp  (s_axi_bresp),
  .s_axi_bvalid (s_axi_bvalid),
  .s_axi_bready (s_axi_bready),
  .s_axi_araddr (s_axi_araddr),
  .s_axi_arprot (s_axi_arprot),
  .s_axi_arvalid(s_axi_arvalid),
  .s_axi_arready(s_axi_arready),
  .s_axi_rdata  (s_axi_rdata),
  .s_axi_rresp  (s_axi_rresp),
  .s_axi_rlast  (s_axi_rlast),
  .s_axi_rvalid (s_axi_rvalid),
  .s_axi_rready (s_axi_rready),
  .baddr(baddr), .binst(binst), .rh(rh), .brdata(brdata),
  .faddr(faddr), .fwdata(fwdata), .fwstrb(fwstrb),
  .fwrite(fwrite), .fread(fread)
);

endmodule


// 8KB system ram as an AXI slave : program/data space for the compute cpus,
// loaded by the bios cpu (over uart0) at host-chosen offsets
module smol_ram
#(
  parameter INIT = "none" // optional $readmemh file (sim)
)
(
  input              clk   ,
  input              rstb  ,
  input      [31: 0] s_axi_awaddr  ,
  input              s_axi_awvalid ,
  output             s_axi_awready ,
  input      [31: 0] s_axi_wdata   ,
  input      [ 3: 0] s_axi_wstrb   ,
  input              s_axi_wvalid  ,
  output             s_axi_wready  ,
  output     [ 1: 0] s_axi_bresp   ,
  output             s_axi_bvalid  ,
  input              s_axi_bready  ,
  input      [31: 0] s_axi_araddr  ,
  input      [ 2: 0] s_axi_arprot  ,
  input              s_axi_arvalid ,
  output             s_axi_arready ,
  output     [31: 0] s_axi_rdata   ,
  output     [ 1: 0] s_axi_rresp   ,
  output             s_axi_rlast   ,
  output             s_axi_rvalid  ,
  input              s_axi_rready
);

wire [31: 0] baddr, faddr, fwdata;
wire [ 3: 0] fwstrb;
wire         binst, rh, fwrite, fread;
reg  [31: 0] brdata;
reg  [ 7: 0] mem[0:'h1fff];
wire [12: 0] wa = {baddr[12:2],2'b00};
integer li;
initial begin
  if(INIT != "none") $readmemh(INIT, mem);
end
always@(*) brdata = {mem[wa+3],mem[wa+2],mem[wa+1],mem[wa]};
always@(posedge clk) begin
  if(fwrite) begin
    for(li=0;li<4;li=li+1)
      if(fwstrb[li]) mem[{faddr[12:2],2'b00}+li[12:0]] <= fwdata[li*8 +: 8];
  end
end
axi_s s
(
  .clk(clk), .rstb(rstb),
  .s_axi_awaddr (s_axi_awaddr),
  .s_axi_awvalid(s_axi_awvalid),
  .s_axi_awready(s_axi_awready),
  .s_axi_wdata  (s_axi_wdata),
  .s_axi_wstrb  (s_axi_wstrb),
  .s_axi_wvalid (s_axi_wvalid),
  .s_axi_wready (s_axi_wready),
  .s_axi_bresp  (s_axi_bresp),
  .s_axi_bvalid (s_axi_bvalid),
  .s_axi_bready (s_axi_bready),
  .s_axi_araddr (s_axi_araddr),
  .s_axi_arprot (s_axi_arprot),
  .s_axi_arvalid(s_axi_arvalid),
  .s_axi_arready(s_axi_arready),
  .s_axi_rdata  (s_axi_rdata),
  .s_axi_rresp  (s_axi_rresp),
  .s_axi_rlast  (s_axi_rlast),
  .s_axi_rvalid (s_axi_rvalid),
  .s_axi_rready (s_axi_rready),
  .baddr(baddr), .binst(binst), .rh(rh), .brdata(brdata),
  .faddr(faddr), .fwdata(fwdata), .fwstrb(fwstrb),
  .fwrite(fwrite), .fread(fread)
);

endmodule
