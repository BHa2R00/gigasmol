(inc "init.as")
(main)
; cpu11 (node15, 3x3) : IBASE = 0x40c0, DBASE = 0x4000, enable
(setw #x30b4 (const #x40c0))
(setw #x30b8 (const #x4000))
(set  #x30b0 (const 1))
(quit)
