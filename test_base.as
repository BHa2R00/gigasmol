(inc "init.as")
(main)
; cpu1 : IBASE = 0x4080, DBASE = 0x4000 (full word writes via we=1111)
(setw #x3014 (const #x4080))
(setw #x3018 (const #x4000))
(set  #x3010 (const 1))
; read back the config words, park them in ram for the tb
#x3014 D=M #x4140 MW=D
#x3018 D=M #x4144 MW=D
(quit)
