#!/bin/bash
# v9 mesh regression : compile all tbs once, then per test regenerate
# rom.memh / ram.memh and run
cd /mnt/agents/work
PASS=0; FAIL=0

zeros_ram() {
python3 -c "open('ram.memh','w').write('\n'.join(['00']*8192)+'\n')"
}

# payload : A=sig; D=A; A=dst; M=D; A=-1; jmp
mkram() {
python3 - "$@" <<'PY'
import sys
mem = ['00']*8192
def putw(a, w):
    for i in range(4): mem[a+i] = '%02x' % ((w >> (8*i)) & 0xff)
def payload(a, sig, dst):
    ws = [0x7FC00000|(sig<<1), 0x7F8008C1, 0x7FC00000|(dst<<1),
          0x7F800431, 0x7FC1FFFE, 0x7F80E0A5]
    for i,w in enumerate(ws): putw(a+4*i, w)
args = sys.argv[1:]
mode = args[0]
if mode == 'base':
    payload(0x80, 0x5A, 0x100)
elif mode == 'off':
    payload(0x00, 0xC1, 0x4100); payload(0x40, 0xC2, 0x4101); payload(0x80, 0xC3, 0x4102)
elif mode == 'mesh':
    payload(0xc0, 0x11, 0x110)
open('ram.memh','w').write('\n'.join(mem)+'\n')
PY
}

asm() { sbcl --script sw.lisp asm -i "$1" -o rom.memh >/dev/null 2>&1; }

run() { # name tb expected-token
  vvp sim_$1 2>/dev/null | grep -v WARNING > run_$1.log
  if grep -q "$3" run_$1.log; then echo "PASS  $1"; PASS=$((PASS+1));
  else echo "FAIL  $1  (wanted '$3')"; FAIL=$((FAIL+1)); fi
}

echo "== compile =="
for t in 32 base off mc imm mesh uart0 uart boot_seq boot_fail; do
  iverilog -g2012 -DSIM -s tb_$t -o sim_$t tb_$t.v hw.sv || { echo "COMPILE FAIL tb_$t"; exit 1; }
done

echo "== tb_32 : 32-bit datapath / write-back =="
asm t32.as; zeros_ram; run 32 tb_32 "32 PASS"

echo "== tb_base : IBASE/DBASE config =="
asm test_base.as; mkram base; run base tb_base "BASE PASS"

echo "== tb_off : multi-core offset fetch =="
asm test_off.as; mkram off; run off tb_off "OFF PASS"

echo "== tb_mc : multi-core trigger =="
asm test_mc.as; zeros_ram; run mc tb_mc "PASS : cpu1 ran"

echo "== tb_imm : boundary immediates =="
asm t2.as; zeros_ram
vvp sim_imm 2>/dev/null | grep -v WARNING > run_imm.log
grep -E "A=" run_imm.log | tail -5
if grep -q "A=00007fff" run_imm.log && grep -q "A=ffffc000" run_imm.log && \
   grep -q "A=ffff8000" run_imm.log && grep -q "A=00000000" run_imm.log && \
   grep -q "A=ffffffff" run_imm.log; then echo "PASS  imm"; PASS=$((PASS+1));
else echo "FAIL  imm"; FAIL=$((FAIL+1)); fi

echo "== tb_uart0 : hello world (hw uart) =="
asm hello.as; zeros_ram
vvp sim_uart0 2>/dev/null | grep -v WARNING > run_uart0.log
python3 - <<'PY'
import re
T = 8680000.0
edges = []
for l in open('run_uart0.log'):
    m = re.match(r'(\d+) TX (\d)', l)
    if m: edges.append((int(m.group(1)), int(m.group(2))))
msg = ''
skip_until = 0
for i in range(1, len(edges)):
    t, v = edges[i]
    if t < skip_until: continue
    if v == 0 and edges[i-1][1] == 1:  # falling edge = start bit
        b = 0
        for k in range(8):
            ts = t + T*(1.5 + k)
            # find level at ts
            lvl = 1
            for te, ve in edges:
                if te <= ts: lvl = ve
                else: break
            b |= (lvl & 1) << k
        msg += chr(b)
        skip_until = t + T*9.2  # ignore data edges until this frame ends
print('decoded:', repr(msg))
ok = msg.startswith('hello world!') and 'RX PASS' in open('run_uart0.log').read()
print('UART0', 'PASS' if ok else 'FAIL')
open('uart0_result.txt','w').write('PASS' if ok else 'FAIL')
PY
if grep -q PASS uart0_result.txt; then echo "PASS  uart0"; PASS=$((PASS+1)); else echo "FAIL  uart0"; FAIL=$((FAIL+1)); fi

echo "== tb_uart : bit-bang hello =="
asm hello_bb.as; zeros_ram
vvp sim_uart 2>/dev/null | grep -v WARNING > run_uart.log
python3 - <<'PY'
import re
T = 2440000.0
edges = []
for l in open('run_uart.log'):
    m = re.match(r'(\d+) TX (\d)', l)
    if m: edges.append((int(m.group(1)), int(m.group(2))))
msg = ''
skip_until = 0
for i in range(1, len(edges)):
    t, v = edges[i]
    if t < skip_until: continue
    if v == 0 and edges[i-1][1] == 1:
        if t < 1000000: continue  # reset transient
        b = 0
        for k in range(8):
            ts = t + T*(1.5 + k)
            lvl = 1
            for te, ve in edges:
                if te <= ts: lvl = ve
                else: break
            b |= (lvl & 1) << k
        msg += chr(b)
        skip_until = t + T*9.2  # ignore data edges until this frame ends
print('decoded:', repr(msg))
ok = msg.startswith('hello world!')
print('BB', 'PASS' if ok else 'FAIL')
open('bb_result.txt','w').write('PASS' if ok else 'FAIL')
PY
if grep -q PASS bb_result.txt; then echo "PASS  uart(bb)"; PASS=$((PASS+1)); else echo "FAIL  uart(bb)"; FAIL=$((FAIL+1)); fi

echo "== tb_mesh : longest-path mesh boot =="
asm test_mesh.as; mkram mesh; run mesh tb_mesh "MESH PASS"

echo "== tb_boot_seq : rom0 bios boots cpu1..11, short ram sweep (SLOW, ~7 min) =="
sbcl --script sw.lisp --boot 4080 > boot_short.as 2>/dev/null
asm boot_short.as
python3 -c "open('ram.memh','w').write('\n'.join(['aa']*8192)+'\n')"
vvp sim_boot_seq 2>/dev/null | grep -v WARNING > run_boot_seq.log
python3 - <<'PY'
import re
log = open('run_boot_seq.log').read()
# the decoded uart stream interleaves with the tb's HALT $display lines,
# so check the per-cpu messages by ordered extraction, not substring
nums = re.findall(r'(\d+): ram test finish', log)
print('message order :', ' '.join(nums))
ok = (nums == [str(n) for n in range(1, 12)]) and 'BOOT SEQ PASS' in log
print('halt order + ram ok :', 'BOOT SEQ PASS' in log)
open('boot_seq_result.txt','w').write('PASS' if ok else 'FAIL')
PY
if grep -q PASS boot_seq_result.txt; then echo "PASS  boot_seq"; PASS=$((PASS+1)); else echo "FAIL  boot_seq"; FAIL=$((FAIL+1)); fi

echo "== tb_boot_fail : stuck ram word -> fail at address 4040 =="
asm boot_short.as
python3 -c "open('ram.memh','w').write('\n'.join(['aa']*8192)+'\n')"
vvp sim_boot_fail 2>/dev/null | grep -v WARNING > run_boot_fail.log
if grep -q "1: fail at address 4040" run_boot_fail.log; then echo "PASS  boot_fail"; PASS=$((PASS+1));
else echo "FAIL  boot_fail  (wanted '1: fail at address 4040')"; FAIL=$((FAIL+1)); fi

# restore the full-range boot rom as the default working image
sbcl --script sw.lisp --boot > boot.as 2>/dev/null
asm boot.as
zeros_ram

echo "=============================="
echo "TOTAL: $PASS pass, $FAIL fail"
