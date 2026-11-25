# gigasmol

giga version of smol ISA implementaion

A NaN-boxed 32-bit hack-ISA SoC: 12 cpu cores on a 4x4 AXI mesh (netlist
generated from a lisp config by `sw.lisp --aximesh`), a lisp macro
assembler, and a rom0 BIOS (`sw.lisp --boot`) that boots each compute core
into its own ram self-test.

## Instruction set

### Instruction words

Every 32-bit instruction word is a legal float32; the cpu decodes by the
exponent field:

- **non-NaN word** — raw 32-bit immediate: `A <= word`
- **NaN word** (exponent `0xff`, mantissa nonzero) — an instruction; the
  quiet bit `i[22]` selects the flavor:
  - `i[22]=1` — **A-instruction**: `A <= sext(i[16:1])`, a sign-extended
    16-bit immediate (`#x8000..#xffff` read as negative)
  - `i[22]=0` — **C-instruction**: compute / store / jump, below

Registers are `A` (address and data), `D` (data), and `M`, the memory word
at `A`. The program counter `p` is a 16-bit *byte* address; fetches read
`IBASE + p` and data accesses read `DBASE + A`, so a program runs
identically wherever its base registers point. `p = 0xffff` parks the core.

### C-instruction: `dst=comp?jmp`

```
field   bits                meaning
-----   -----------------   --------------------------------------
opc     i[9:2]              ALU operation (comp)
dst     i[12:11], i[10]     write-back bits {A, D} + store width lsb
we      {i[21:19], i[10]}   store width: 0001 byte, 0011 half, 1111 word
jmp     i[15:13]            jump condition on the comp result
ysel    {i[18:16], i[1]}    ALU y source: 0 = A register, 1 = M
```

comp — the classic hack ALU set plus constants and shifts:

```
C0  C1  C-1   D  A   !D  !A   -D  -A   D+1  A+1   D-1  A-1
D+A   D-A  A-D   D&A   DVA (or)   D<<A  A<<D  (and ! variants)
```

Every comp written with `A` also exists with `M` (same opc, `ysel=1`):
`D=A`/`D=M`, `D=D+A`/`D=D+M`, `MD=A+1`/`MD=M+1`, ...

dst — any combination of `M`, `D`, `A`; a memory write also picks a width:

```
M=D   byte store        MH=D  half store        MW=D  word store
```

jmp — `JGT JEQ JGE JLT JNE JLE JMP`, tested on this instruction's comp
result; the target is taken from `A`: `p <= a[15:0]`.

### Examples

```
#x2104 D=M          A = 0x2104 (uart0 STAT) ; D = M
1 D=D&A             A = 1 ; D = D & A  (tx_busy bit)
42 D?JNE            A = 42 ; if D != 0 -> p = 42  (absolute in p space)
#x2100 M=D          A = 0x2100 (uart0 DATA) ; [A] = D, byte -> tx
#x4000 A=M          A = M[0x4000]  (ram pointer read)
D=C0 MW=D           D = 0 ; [A] = D, word store -> poke 0
D=C-1 MW=D          D = -1 ; word store        -> poke all-1s
D=M D=D+1           read back ; +1 must wrap to 0
D=D+A?JLT           D = D + A ; jump if the sum is negative
#xffff C0?JMP       A = -1 ; unconditional jump -> p = 0xffff : halt
```

### Memory map (cpu view, low 64 KB)

```
0x0000-0x1fff  rom (writable)        0x3000+16*k  cpu k config
0x2000-0x20ff  io device                +0x0 CTRL  bit0 enable
0x2100         uart0 DATA               +0x4 IBASE fetch base
0x2104         uart0 STAT (b0 busy)     +0x8 DBASE data base
0x4000-0x5fff  ram                      +0xc STAT  {pc,15'h0,halt}
```

## Assembler syntax (as)

`sw.lisp` reads the source as a **token stream** — any whitespace (spaces
or newlines) separates tokens, so pack a logical statement on one line.
It is not line-based asm.

```
number        decimal or #x hex; fits in 16 bits -> A-instruction,
              bigger -> raw non-NaN 32-bit word (A <= word)
#\c           character -> A-instruction with its code
D=D+A?JNE     a C-instruction name (dst=comp?jmp), see the table above
(name)        define a label at the current pc
name          reference: emits an A-instruction with the label's address
(name bytes)  allocate bytes in the data section (base 0x2000, -data moves it)
              and bind name to its address
(name ())     free that binding again
(name (args) body...)   define a macro (textual substitution)
(name a1 a2)            expand a macro
(inc "file")            include another source file
```

Labels make branches readable: a label reference loads `A` with the
label's byte address and `D?JNE` jumps to `A` — a label reference right
before a conditional jump is a loop. (The jump target lives in `p` space,
which is IBASE-relative; plain assembled programs run at IBASE=0 so label
addresses can be used directly, while the multi-image `--boot` code
computes its own fixups.)

### Example: polling uart putc, as a macro (from init.as)

```lisp
(uputc (c)
  (set uart_c c)                                        ; uart_c = c
  (_uputc) #x2104 D=M 1 D=D&A _uputc D?JNE (_uputc ())  ; poll while tx_busy
  uart_c D=M #x2100 M=D)                                ; write DATA
```

`(_uputc)` defines the label; `_uputc` before `D?JNE` loads its address
into `A`, so the conditional jump re-enters the poll. Macros from
`init.as` cover the usual plumbing: `(const n)`, `(set addr e)`,
`(setw addr e)`, `(eval addr)`, `(incf addr)`, `(jlt addr e v)` ...,
`(quit)`.

### Example: hello on uart0

```lisp
(inc "init.as")
(main)
(uputc (const #\h))
(uputc (const #\i))
(uputc (const #\newline))
(quit)
```

assemble and simulate:

```
sbcl --script sw.lisp asm -i hello.as -o rom.memh
iverilog -g2012 -DSIM -s tb_uart0 -o sim_uart0 tb_uart0.v hw.sv
vvp sim_uart0
```

### Example: rom0 boot image (BIOS + per-core ram tests)

```
sbcl --script sw.lisp --boot > boot.as        # sweep 0x4000..0x5fff
sbcl --script sw.lisp --boot 4080 > boot_short.as   # short sweep, for sims
```

cpu0 writes each compute core's IBASE (its test block in rom0), enables
it, waits for its halt, then moves on; each core prints
`N: ram test finish` or `N: fail at address HHHH` on uart0.
