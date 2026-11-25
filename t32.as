(inc "init.as")
(main)
; 32-bit float immediate (raw non-NaN word) + full word store
(setw #x4040 (const #x12345678))
; byte store into lane 1 of word 0x4044
(set  #x4045 (const #xAB))
; half store into lanes 2,3 of word 0x4044
(seth #x4046 (const #xBEEF))
; sign-extended imm16 : A=-1 -> D=0xFFFFFFFF -> word store
-1 D=A #x4050 MW=D
; 32-bit M read : word readback
#x4040 D=M #x4048 MW=D
; 32-bit M read : mixed word (byte+half stores above)
#x4044 D=M #x404c MW=D
(quit)
