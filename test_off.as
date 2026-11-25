(inc "init.as")
(main)
; cpu1 : ENTRY = 0x4000, enable
(set #x3015 (const #x40))
(set #x3010 (const 1))
; cpu2 : ENTRY = 0x4040, enable
(set #x3024 (const #x40))
(set #x3025 (const #x40))
(set #x3020 (const 1))
; cpu3 : ENTRY = 0x4080, enable
(set #x3034 (const #x80))
(set #x3035 (const #x40))
(set #x3030 (const 1))
(quit)
