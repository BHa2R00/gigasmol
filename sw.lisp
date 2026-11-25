#!/usr/bin/sbcl --script 
(defmacro argv () `sb-ext:*posix-argv*)
(defun float2bytes (f)
  (let ((u (sb-kernel:single-float-bits f)))
    (list 
      (ldb (byte 8  0) u) 
      (ldb (byte 8  8) u) 
      (ldb (byte 8 16) u) 
      (ldb (byte 8 24) u))))
(defun <- (l a b)
  (cond
    ((equalp l a) b)
    ((atom l) l)
    (t (map 'list (lambda (li) (<- li a b)) l))))
(defparameter *src*
  '((#\M #b1)))
(defparameter *alu*
  '(
    (C0      #b00101001) (C1      #b01111101) (C-1     #b00111001) 
    (D       #b00001100) (A       #b00110000) 
    (!D      #b01001100) (!A      #b01110000) 
    (-D      #b01001101) (-A      #b01110001) 
    (D+1     #b01011101) (A+1     #b01110101) 
    (D-1     #b00001101) (A-1     #b00110001) 
    (D+A     #b00000001)              
    (D-A     #b01010001) (A-D     #b01000101) 
    (D&A     #b00000000)              
    (DVA     #b01010100)              
    (D<<A    #b00000011) (A<<D    #b00000010) 
    (!D<<A   #b00010011) (A<<!D   #b00010010) 
    (D<<A    #b00000011) (D<<A    #b00000010) 
    (!A<<D   #b00000111) (D<<!A   #b00000110) 
    (D!<<A   #b01000011) (A!<<D   #b01000010) 
    (!D!<<A  #b01010011) (A!<<!D  #b01010010) 
    (D!<<A   #b01000011) (D!<<A   #b01000010) 
    (!A!<<D  #b01000111) (D!<<!A  #b01000110) 
    (^C1     #b11111101)              
    (^D      #b10001100) (^A      #b10110000) 
    (!^D     #b11001100) (!^A     #b11110000) 
    (-^D     #b11001101) (-^A     #b11110001) 
    (^D+1    #b11011101) (^A+1    #b11110101) 
    (^D-1    #b10001101) (^A-1    #b10110001) 
    (D^+A    #b10000001)              
    (D^-A    #b11010001) (A^-D    #b11000101) 
    (D^&A    #b10000000)              
    (D^VA    #b11010100)              
    (D^<<A   #b10000011) (A^<<D   #b10000010) 
    (!D^<<A  #b10010011) (A^<<!D  #b10010010) 
    (D^<<A   #b10000011) (D^<<A   #b10000010) 
    (!A^<<D  #b10000111) (D^<<!A  #b10000110) 
    (D!^<<A  #b11000011) (A!^<<D  #b11000010) 
    (!D!^<<A #b11010011) (A!^<<!D #b11010010) 
    (D!^<<A  #b11000011) (D!^<<A  #b11000010) 
    (!A!^<<D #b11000111) (D!^<<!A #b11000110) 
    ))
(defparameter *dst*
  '(                                ; name, D/A bitmask @i[12:11]+we0 @i[10], we[3:1] @i[21:19]
    (NIL #b000 0)
    (M   #b001 0) (D   #b010 0) (MD  #b011 0)
    (A   #b100 0) (AM  #b101 0) (AD  #b110 0) (AMD #b111 0)
    (MH  #b001 1) (MHD #b011 1) (AMH #b101 1) (AMHD #b111 1) ; half word : we=0011
    (MW  #b001 7) (MWD #b011 7) (AMW #b101 7) (AMWD #b111 7) ; full word : we=1111 (aligned)
    ))
(defparameter *jmp*
  '(
    (NIL #b000) 
    (JEQ #b010) (JNE #b101) 
    (JGT #b001) (JGE #b011)
    (JLT #b100) (JLE #b110)
    (JMP #b111)
    ))
(defparameter *cinst* (list))
(defun cinstname (d a j)
  (read-from-string
    (with-output-to-string (s)
      (if d (format s "~A=" d))
      (format s "~A" a)
      (if j (format s "?~A" j))
      )))
(map 'list
     (lambda (jmp)
       (map 'list
            (lambda (dst)
              (map 'list
                   (lambda (alu)
                     (let ((a (with-output-to-string (s) (format s "~A" (car alu))))
                           ; float32 NaN-box : exponent FF, quiet=0 (signaling) for C-instruction
                           ; i[0]=1 keeps mantissa nonzero even when all other payload bits are 0
                           (c #x7F800001))
                       (setf c (logior c (ash (cadr jmp) 13)))
                       (setf c (logior c (ash (cadr dst) 10)))
                       (setf c (logior c (ash (caddr dst) 19)))
                       (setf c (logior c (ash (cadr alu) 2)))
                       (push (list (cinstname (car dst) a (car jmp)) c) *cinst*)
                       (if (position #\A a)
                         (map 'list
                              (lambda (src)
                                (let ((a1 (substitute (car src) #\A a)))
                                  ; ysel = {i[18:16], i[1]} : src bit0 -> i[1], src bits[3:1] -> i[18:16]
                                  ; 0=A 1=M, 2..15 reserved for future chained ALU outputs
                                  (setf c (logior c (ash (logand (cadr src) 1) 1)))
                                  (setf c (logior c (ash (logand (cadr src) #b1110) 15)))
                                  (push (list (cinstname (car dst) a1 (car jmp)) c) *cinst*)
                                  ))
                              *src*))
                       ))
                   *alu*))
            *dst*))
     *jmp*)
(setf *cinst* (reverse *cinst*))
(defparameter *mode* nil)
(defparameter *data* #x2000)
(defparameter *size* #x2100)
(defparameter *mem* (list))
(defparameter *label* (list))
(defparameter *value* (list))
(defparameter *lambda* (list))
(defparameter *debug* nil)
(defun asm (s)
  (do ((a (read s nil 'end)
          (read s nil 'end)))
    ((equalp a 'end))
    (cond
      ((assoc a *value*) 
       (let ()
         ; A-instruction : quiet NaN (#x7FC00000) + imm16 at i[16:1]
         (push (logior #x7FC00000 (ash (logand #xffff (caddr (assoc a *value*))) 1)) *mem*)
         (if *debug* (format t "~4,'0x : ~15A ~8,'0x~%" (* 4 (1-(length *mem*))) a (car *mem*)))
         ))
      ((assoc a *label*) 
       (let ()
         (push (logior #x7FC00000 (ash (logand #xffff (cadr (assoc a *label*))) 1)) *mem*)
         (if *debug* (format t "~4,'0x : ~15A ~8,'0x~%" (* 4 (1-(length *mem*))) a (car *mem*)))
         ))
      ((assoc a *cinst*) 
       (let ()
         (push (cadr(assoc a *cinst*)) *mem*)
         (if *debug* (format t "~4,'0x : ~15A ~8,'0x~%" (* 4 (1-(length *mem*))) a (car *mem*)))
         ))
      ((listp a)
       (cond
         ((and
            (car a)
            (member (car a) '(inc include))
            (cadr a)
            (stringp (cadr a))
            (probe-file (cadr a))
            ) ;; include file : (inc path)
          (let ()
            (if *debug* (format t "include ~A~%" (cadr a)))
            (with-open-file (s1 (cadr a) :direction :input) (asm s1))
            ))
         ((and
            (assoc (car a) *lambda*)
            (= (length (cdr a)) (length (cadr (assoc (car a) *lambda*))))
            ) ;; expand macro : (macroname argvs... )
          (let ((i (cdr a))
                (v (cadr (assoc (car a) *lambda*)))
                (b (cddr (assoc (car a) *lambda*)))
                (b1 (list))
                (buf ""))
            (setf b1 b)
            (map 'list (lambda (vi ii) (setf b1 (<- b1 vi ii))) v i)
            (if *debug* (format t ">- ~A ~%-> ~A~%" a b1))
            (setf buf (with-output-to-string (s1) (format s1 "~{~S ~}" b1)))
            (with-input-from-string (s1 buf) (asm s1))
            ))
         ((and 
            (listp (car a)) (cdr a) 
            (atom (car(car a)))
            (or
              (stringp (cadr(car a)))
              (listp (cadr(car a)))
              (vectorp (cadr(car a)))
              (floatp (cadr(car a))))) ;; map : ((char/value/float "string"/#(vector)) body... )
          (let ((l (coerce (if (floatp (cadr(car a))) (float2bytes (cadr(car a))) (cadr(car a))) 'list))
                (i (car(car a)))
                (b (cdr a))
                (buf ""))
            (format t "~%debug: map~%")
            (map 'list
                 (lambda (li)
                   (setf buf 
                         (with-output-to-string (s1) 
                           (format s1 "~S" (append (list(list(list i li))) b))))
                   (with-input-from-string (s1 buf) (asm s1))
                   )
                 (if i l (list (list nil nil))))
            ))
         ((and (listp (car a)) (cdr a)) ;; lambda : ((binds... ) body... )
          (let ((i (car a))
                (b (cdr a))
                (buf ""))
            (format t "lambda : ~S~%" a)
            (map 'list (lambda (ik) (setf b (<- b (car ik) (cadr ik)))) i)
            (setf buf (with-output-to-string (s1) (format s1 "~{~S ~}" b)))
            (with-input-from-string (s1 buf) (asm s1))
            ))
         ((and (listp (cadr a)) (cddr a)) ;; define macro : (macroname (args... ) body... )
          (let ()
            (push a *lambda*)
            (if *debug* (format t "-< ~S~%" (car *lambda*)))
            ))
         ((and (cadr a) (numberp (cadr a))) ;; define value : (name bytes)
          (let ((data *data*))
            (map 'list
                 (lambda (v)
                   (if (= data *data*)
                   (let ((p (nth 2 v))
                         (l (nth 1 v)))
                     (setf p (+ l p))
                     ;(format t "v=~X p=~X~%" v p)
                     (if (not(member-if 
                               #'(lambda (vv)
                                  (let*((p0 (nth 2 vv))
                                        (p1 (+ p0 (nth 1 vv))))
                                    (if (and 
                                          (>= p p0) (< p p1)
                                          (if (< (cadr a) (nth 1 vv))
                                            (and (> (+ (cadr a) p) p0) (<= (+ (cadr a) p) p1))
                                            t)
                                          )
                                      t nil)))
                               *value*))
                       (let()
                         (setf data p)
                         ;(format t "data=~x~%" data)
                         ))
                     )))
                 *value*)
            (setf *data* data)
            (push (append a (list (logand #xffff *data*))) *value*)
            (if *debug* (format t "~4,'0x = ~A~%" (car(reverse(car *value*))) a))
            ;(format t "~X~%" *value*)
            (incf *data* (cadr a))
            ))
         ((and 
            (= 2 (length a)) 
            (equal nil (nth 1 a))
            (assoc (car a) *value*)) ;; free value : (name ()) 
          (let ()
            (if (assoc (car a) *value*) 
              (setf 
                *value* 
                (remove-if 
                  #'(lambda (i) 
                      (if (equalp (car i) (car a))
                        (let ()
                          (if *debug* (format t "free ~4,'0x = ~A~%" (nth 2 i) (nth 0 i)))
                          t)
                        nil)) 
                  *value*
                  :count 1)))
            ))
         (t ;; label: (name) 
          (let ()
            ; raw byte address : 32-bit instruction = 4 bytes per *mem* entry
            (push (list (car a) (logand #xffff (ash (length *mem*) 2))) *label*)
            (if *debug* (format t "~4,'0x = ~15A~%" (* 4 (length *mem*)) a))
            ))
         ))
      ((numberp a) ;; constant number : A-instruction, quiet NaN + imm16 at i[16:1]
       (let ((u (logand #xffffffff a)))
         (cond
           ((and (<= a 65535) (>= a -32768)) ; fits imm16 : A-instruction
            (push (logior #x7FC00000 (ash (logand #xffff a) 1)) *mem*))
           ((or (> a #xffffffff) (< a (- #x80000000)))
            (format t "error : immediate out of range (-2^31..2^32-1) : ~A~%" a))
           ((and (= (logand (ash u -23) #xff) #xff) (/= (logand u #x7fffff) 0))
            (format t "error : immediate collides with the NaN instruction space : ~A~%" a))
           (t ; 32-bit immediate : emitted as a raw (non-NaN) float word, cpu loads A<=i
            (push u *mem*)))
         (if *debug* (format t "~4,'0x : ~15A ~8,'0x~%" (* 4 (1-(length *mem*))) a (car *mem*)))
         ))
      ((characterp a) ;; constant number : char #\ 
       (let ()
         (push (logior #x7FC00000 (ash (char-code a) 1)) *mem*)
         (if *debug* (format t "~4,'0x : ~15A ~8,'0x~%" (* 4 (1-(length *mem*))) a (car *mem*)))
         ))
      ((atom a) ;; unallocated label refer 
       (let ()
         (push a *mem*)
         (if *debug* (format t "~4,'0x : ~15A ~%" (* 4 (1-(length *mem*))) (car *mem*)))
         ))
      (t (format t "syntax error : ~A~%" a)))
    ))

;=========================================================================
; --aximesh : NoC axi mesh netlist generator, config = plain lists :
;   (grid W H)                            mesh dimensions, node id = y*W+x
;   (node N dev rom|io|uart0|ram)         device node (local slave only)
;   (node N cpu [:name cpuK] [:boot-en 0|1] [:boot-ib A] [:boot-db A]
;               [:rom-only 0|1])          cpu node (local master via cpu_locmux
;                                         + config slave on the local port)
; cpu index k is assigned in node order ; halt output = first cpu's halt.
; link slot W*H is the dummy for off-mesh boundary ports.
; usage : sbcl --script sw.lisp --aximesh > mesh.v
(defparameter *aximesh*
  '((grid 4 4)
    (node  0 dev rom)
    (node  1 dev io)
    (node  2 dev uart0)
    (node  3 dev ram)
    (node  4 cpu :name cpu0  :boot-en 1 :boot-ib #x0    :boot-db #x0 :rom-only 1)
    (node  5 cpu :name cpu1)
    (node  6 cpu :name cpu2)
    (node  7 cpu :name cpu3)
    (node  8 cpu :name cpu4)
    (node  9 cpu :name cpu5)
    (node 10 cpu :name cpu6)
    (node 11 cpu :name cpu7)
    (node 12 cpu :name cpu8)
    (node 13 cpu :name cpu9)
    (node 14 cpu :name cpu10)
    (node 15 cpu :name cpu11)))

(defun gen-aximesh (&optional (cfg *aximesh*))
  (let* ((gw (cadr  (assoc 'grid cfg)))
         (gh (caddr (assoc 'grid cfg)))
         (nn (* gw gh))
         (dm nn)                          ; dummy link slot
         (tab (make-array nn :initial-element nil))
         (cpus '()) (devs '()) (k 0))
    (dolist (e cfg)
      (when (eq (car e) 'node)
        (let ((n (cadr e)) (kind (caddr e)) (pl (cdddr e)))
          (if (aref tab n) (error "aximesh : duplicate node ~D" n))
          (setf (aref tab n) e)
          (case kind
            (cpu (push (list n (getf pl :name (intern (format nil "CPU~D" k)))
                             (getf pl :boot-en 0) (getf pl :boot-ib #x4000)
                             (getf pl :boot-db 0) (getf pl :rom-only 0) k)
                       cpus)
                 (incf k))
            (dev (push (list n (cadddr e)) devs))
            (t   (error "aximesh : bad node kind ~A" kind))))))
    (setf cpus (nreverse cpus) devs (nreverse devs))
    (dotimes (n nn)
      (if (null (aref tab n)) (error "aximesh : node ~D is empty" n)))
    (flet ((sl (bus i wd) (format nil "~A[~D*~D +: ~D]" bus i wd wd))
           (bt (bus i)    (format nil "~A[~D]" bus i))
           (ct (items)    (format nil "{~{~A~^, ~}}" items)))
      (labels
          ((vslice (fam i wd) (if (= wd 1) (bt fam i) (sl fam i wd)))
           ;; router s-side concat {L,S,N,W,E} for one signal
           (scc (sig n nsi ssi esi wsi wd)
             (ct (list (vslice (format nil "l2r_~A" sig) n   wd)
                       (vslice (format nil "nb_~A"  sig) nsi wd)
                       (vslice (format nil "sb_~A"  sig) ssi wd)
                       (vslice (format nil "wb_~A"  sig) esi wd)
                       (vslice (format nil "eb_~A"  sig) wsi wd))))
           ;; router m-side concat {L,S,N,W,E} for one signal
           (mcc (sig n wd)
             (ct (mapcar (lambda (f) (vslice (format nil "~A_~A" f sig) n wd))
                         '("r2l" "sb" "nb" "wb" "eb"))))
           (rport (name cat) (format t "      .~A~9T(~A),~%" name cat))
           ;; device / cpu-config slave hookup lines on r2l[n]
           (devhook (n)
             (format t "    .s_axi_awaddr (~A), .s_axi_awvalid(~A), .s_axi_awready(~A),~%"
                     (sl "r2l_awaddr" n 32) (bt "r2l_awvalid" n) (bt "r2l_awready" n))
             (format t "    .s_axi_wdata  (~A), .s_axi_wstrb  (~A), .s_axi_wvalid (~A),~%"
                     (sl "r2l_wdata" n 32) (sl "r2l_wstrb" n 4) (bt "r2l_wvalid" n))
             (format t "    .s_axi_wready (~A),~%" (bt "r2l_wready" n))
             (format t "    .s_axi_bresp  (~A),   .s_axi_bvalid (~A),  .s_axi_bready (~A),~%"
                     (sl "r2l_bresp" n 2) (bt "r2l_bvalid" n) (bt "r2l_bready" n))
             (format t "    .s_axi_araddr (~A), .s_axi_arprot (~A), .s_axi_arvalid(~A),~%"
                     (sl "r2l_araddr" n 32) (sl "r2l_arprot" n 3) (bt "r2l_arvalid" n))
             (format t "    .s_axi_arready(~A),~%" (bt "r2l_arready" n))
             (format t "    .s_axi_rdata  (~A), .s_axi_rresp  (~A), .s_axi_rlast  (),~%"
                     (sl "r2l_rdata" n 32) (sl "r2l_rresp" n 2))
             (format t "    .s_axi_rvalid (~A),          .s_axi_rready (~A)~%"
                     (bt "r2l_rvalid" n) (bt "r2l_rready" n))))
        ;; ------ header ------
        (format t "//=========================================================================~%")
        (format t "// mesh_top : ~Dx~D axi noc mesh, generated by sw.lisp --aximesh~%" gw gh)
        (format t "//   do not edit : config is the *aximesh* list in sw.lisp~%")
        (format t "//   node id = y*~D+x ; " gw)
        (dolist (d devs) (format t "~A@~D " (cadr d) (car d)))
        (format t "; ~D cpus~%//~%" k)
        (format t "module mesh_top~%(")
        (format t "  output [63:0] io_i, io_oe, io_ie,~%")
        (format t "  input  [63:0] io_o,~%")
        (format t "  output        halt,~%")
        (format t "  output [ 7:0] debug,~%")
        (format t "  input         uart0_rx,~%")
        (format t "  output        uart0_tx,~%")
        (format t "  input         ioclk,~%")
        (format t "  input         rstb,~%")
        (format t "  input         clk~%")
        (format t ");~%~%")
        (format t "localparam NN = ~D; // mesh nodes~%" nn)
        (format t "localparam NC = ~D; // cpus~%~%" k)
        ;; ------ bus declarations ------
        (format t "// one-way axi link bundles : eb/wb/sb/nb[n] = traffic leaving node~%")
        (format t "// n to the east/west/south/north, slot ~D = off-mesh dummy.~%" dm)
        (format t "// l2r[n] = local masters -> router L slave ; r2l[n] = router L -> local slave~%")
        (dolist (fam '("eb" "wb" "sb" "nb"))
          (format t "wire [~D:0] ~A_awaddr, ~A_wdata, ~A_araddr, ~A_rdata;~%"
                  (* (1+ nn) 32) fam fam fam fam)
          (format t "wire [~D:0] ~A_wstrb;~%" (* (1+ nn) 4) fam)
          (format t "wire [~D:0] ~A_arprot;~%" (* (1+ nn) 3) fam)
          (format t "wire [~D:0] ~A_bresp, ~A_rresp;~%" (* (1+ nn) 2) fam fam)
          (format t "wire [~D:0] ~A_awvalid, ~A_awready, ~A_wvalid, ~A_wready;~%"
                  nn fam fam fam fam)
          (format t "wire [~D:0] ~A_bvalid, ~A_bready, ~A_arvalid, ~A_arready, ~A_rvalid, ~A_rready;~%"
                  nn fam fam fam fam fam fam))
        (format t "~%")
        (dolist (fam '("l2r" "r2l"))
          (format t "wire [~D:0] ~A_awaddr, ~A_wdata, ~A_araddr, ~A_rdata;~%"
                  (* nn 32) fam fam fam fam)
          (format t "wire [~D:0] ~A_wstrb;~%" (* nn 4) fam)
          (format t "wire [~D:0] ~A_arprot;~%" (* nn 3) fam)
          (format t "wire [~D:0] ~A_bresp, ~A_rresp;~%" (* nn 2) fam fam)
          (format t "wire [~D:0] ~A_awvalid, ~A_awready, ~A_wvalid, ~A_wready;~%"
                  (1- nn) fam fam fam fam)
          (format t "wire [~D:0] ~A_bvalid, ~A_bready, ~A_arvalid, ~A_arready, ~A_rvalid, ~A_rready;~%"
                  (1- nn) fam fam fam fam fam fam))
        (format t "~%// cpu-side buses (before the local mux) : im read only, dm full~%")
        (format t "wire [~D:0] ci_araddr, ci_rdata;~%" (* k 32))
        (format t "wire [~D:0] ci_arprot;~%" (* k 3))
        (format t "wire [~D:0] ci_rresp;~%" (* k 2))
        (format t "wire [~D:0] ci_arvalid, ci_arready, ci_rvalid, ci_rready;~%" (1- k))
        (format t "wire [~D:0] cd_awaddr, cd_wdata, cd_araddr, cd_rdata;~%" (* k 32))
        (format t "wire [~D:0] cd_wstrb;~%" (* k 4))
        (format t "wire [~D:0] cd_arprot;~%" (* k 3))
        (format t "wire [~D:0] cd_bresp, cd_rresp;~%" (* k 2))
        (format t "wire [~D:0] cd_awvalid, cd_awready, cd_wvalid, cd_wready;~%" (1- k))
        (format t "wire [~D:0] cd_bvalid, cd_bready, cd_arvalid, cd_arready, cd_rvalid, cd_rready;~%~%"
                (1- k))
        (format t "wire [~D:0] haltv;~%assign halt = haltv[0];~%~%" (1- k))
        ;; ------ dummy slot ties ------
        (format t "// dummy slot ~D : off-mesh boundary ports see an idle link~%" dm)
        (dolist (fam '("eb" "wb" "sb" "nb"))
          (format t "assign ~A = 32'd0; assign ~A = 1'b0;~%"
                  (sl (format nil "~A_awaddr" fam) dm 32) (bt (format nil "~A_awvalid" fam) dm))
          (format t "assign ~A = 32'd0; assign ~A = 4'd0; assign ~A = 1'b0; assign ~A = 1'b0;~%"
                  (sl (format nil "~A_wdata" fam) dm 32) (sl (format nil "~A_wstrb" fam) dm 4)
                  (bt (format nil "~A_wvalid" fam) dm) (bt (format nil "~A_bready" fam) dm))
          (format t "assign ~A = 32'd0; assign ~A = 3'd0; assign ~A = 1'b0; assign ~A = 1'b0;~%"
                  (sl (format nil "~A_araddr" fam) dm 32) (sl (format nil "~A_arprot" fam) dm 3)
                  (bt (format nil "~A_arvalid" fam) dm) (bt (format nil "~A_rready" fam) dm)))
        (format t "~%")
        ;; ------ cpus ------
        (format t "// cpus : node, name, boot params ; config slave on r2l[node]~%")
        (dolist (c cpus)
          (destructuring-bind (n name ben bib bdb rom kk) c
            (format t "cpu_axi #(.BOOT_EN(~D), .BOOT_IB(32'h~X), .BOOT_DB(32'h~X), .ROM_ONLY(~D)) ~A~%("
                    ben bib bdb rom (string-downcase (symbol-name name)))
            (format t "  .clk(clk), .rstb(rstb), .halt(~A),~%" (bt "haltv" kk))
            (format t "  .im_awaddr (), .im_awvalid(), .im_awready(1'b0),~%")
            (format t "  .im_wdata  (), .im_wstrb  (),     .im_wvalid (),~%")
            (format t "  .im_wready (1'b0),~%")
            (format t "  .im_bresp  (2'b00), .im_bvalid (1'b0), .im_bready (),~%")
            (format t "  .im_araddr (~A), .im_arprot (~A),~%"
                    (sl "ci_araddr" kk 32) (sl "ci_arprot" kk 3))
            (format t "  .im_arvalid(~A), .im_arready(~A),~%"
                    (bt "ci_arvalid" kk) (bt "ci_arready" kk))
            (format t "  .im_rdata  (~A), .im_rresp  (~A),~%"
                    (sl "ci_rdata" kk 32) (sl "ci_rresp" kk 2))
            (format t "  .im_rvalid (~A), .im_rready (~A),~%"
                    (bt "ci_rvalid" kk) (bt "ci_rready" kk))
            (format t "  .dm_awaddr (~A), .dm_awvalid(~A), .dm_awready(~A),~%"
                    (sl "cd_awaddr" kk 32) (bt "cd_awvalid" kk) (bt "cd_awready" kk))
            (format t "  .dm_wdata  (~A), .dm_wstrb  (~A), .dm_wvalid (~A),~%"
                    (sl "cd_wdata" kk 32) (sl "cd_wstrb" kk 4) (bt "cd_wvalid" kk))
            (format t "  .dm_wready (~A),~%" (bt "cd_wready" kk))
            (format t "  .dm_bresp  (~A),   .dm_bvalid (~A),  .dm_bready (~A),~%"
                    (sl "cd_bresp" kk 2) (bt "cd_bvalid" kk) (bt "cd_bready" kk))
            (format t "  .dm_araddr (~A), .dm_arprot (~A), .dm_arvalid(~A),~%"
                    (sl "cd_araddr" kk 32) (sl "cd_arprot" kk 3) (bt "cd_arvalid" kk))
            (format t "  .dm_arready(~A),~%" (bt "cd_arready" kk))
            (format t "  .dm_rdata  (~A), .dm_rresp  (~A), .dm_rvalid (~A),~%"
                    (sl "cd_rdata" kk 32) (sl "cd_rresp" kk 2) (bt "cd_rvalid" kk))
            (format t "  .dm_rready (~A),~%" (bt "cd_rready" kk))
            (devhook n)
            (format t ");~%~%")))
        ;; ------ devices ------
        (format t "// devices (local slave only)~%")
        (dolist (d devs)
          (destructuring-bind (n kind) d
            (case kind
              (rom   (format t "smol_rom rom~%(~%  .clk(clk), .rstb(rstb),~%"))
              (io    (format t "smol_io iodev~%(~%  .clk(clk), .ioclk(ioclk), .rstb(rstb),~%  .io_i(io_i), .io_oe(io_oe), .io_ie(io_ie), .io_o(io_o),~%  .debug(debug),~%"))
              (uart0 (format t "smol_uart uart0~%(~%  .clk(clk), .rstb(rstb),~%  .rx(uart0_rx), .tx(uart0_tx),~%"))
              (ram   (format t "smol_ram #(.INIT(\"ram.memh\")) pram~%(~%  .clk(clk), .rstb(rstb),~%"))
              (t     (error "aximesh : unknown device ~A" kind)))
            (devhook n)
            (format t ");~%~%")))
        ;; ------ routers + local hookups ------
        (format t "// routers : packed port order {L,S,N,W,E}~%")
        (dotimes (n nn)
          (let* ((x (mod n gw)) (y (floor n gw))
                 (wsi (if (> x 0)       (- n 1)  dm)) ; eb of west neighbour  -> E input
                 (esi (if (< x (1- gw)) (+ n 1)  dm)) ; wb of east neighbour  -> W input
                 (ssi (if (> y 0)       (- n gw) dm)) ; sb of north neighbour -> N input
                 (nsi (if (< y (1- gh)) (+ n gw) dm))) ; nb of south neighbour -> S input
            (format t "mesh_router #(.X(~D), .Y(~D)) rtr~D~%(" x y n)
            (rport "clk" "clk") (rport "rstb" "rstb")
            (rport "s_awaddr"  (scc "awaddr"  n nsi ssi esi wsi 32))
            (rport "s_awvalid" (scc "awvalid" n nsi ssi esi wsi 1))
            (rport "s_awready" (scc "awready" n nsi ssi esi wsi 1))
            (rport "s_wdata"   (scc "wdata"   n nsi ssi esi wsi 32))
            (rport "s_wstrb"   (scc "wstrb"   n nsi ssi esi wsi 4))
            (rport "s_wvalid"  (scc "wvalid"  n nsi ssi esi wsi 1))
            (rport "s_wready"  (scc "wready"  n nsi ssi esi wsi 1))
            (rport "s_bresp"   (scc "bresp"   n nsi ssi esi wsi 2))
            (rport "s_bvalid"  (scc "bvalid"  n nsi ssi esi wsi 1))
            (rport "s_bready"  (scc "bready"  n nsi ssi esi wsi 1))
            (rport "s_araddr"  (scc "araddr"  n nsi ssi esi wsi 32))
            (rport "s_arprot"  (scc "arprot"  n nsi ssi esi wsi 3))
            (rport "s_arvalid" (scc "arvalid" n nsi ssi esi wsi 1))
            (rport "s_arready" (scc "arready" n nsi ssi esi wsi 1))
            (rport "s_rdata"   (scc "rdata"   n nsi ssi esi wsi 32))
            (rport "s_rresp"   (scc "rresp"   n nsi ssi esi wsi 2))
            (rport "s_rvalid"  (scc "rvalid"  n nsi ssi esi wsi 1))
            (rport "s_rready"  (scc "rready"  n nsi ssi esi wsi 1))
            (rport "m_awaddr"  (mcc "awaddr"  n 32))
            (rport "m_awvalid" (mcc "awvalid" n 1))
            (rport "m_awready" (mcc "awready" n 1))
            (rport "m_wdata"   (mcc "wdata"   n 32))
            (rport "m_wstrb"   (mcc "wstrb"   n 4))
            (rport "m_wvalid"  (mcc "wvalid"  n 1))
            (rport "m_wready"  (mcc "wready"  n 1))
            (rport "m_bresp"   (mcc "bresp"   n 2))
            (rport "m_bvalid"  (mcc "bvalid"  n 1))
            (rport "m_bready"  (mcc "bready"  n 1))
            (rport "m_araddr"  (mcc "araddr"  n 32))
            (rport "m_arprot"  (mcc "arprot"  n 3))
            (rport "m_arvalid" (mcc "arvalid" n 1))
            (rport "m_arready" (mcc "arready" n 1))
            (rport "m_rdata"   (mcc "rdata"   n 32))
            (rport "m_rresp"   (mcc "rresp"   n 2))
            (rport "m_rvalid"  (mcc "rvalid"  n 1))
            (format t "      .m_rready  (~A)~%" (mcc "rready" n 1))
            (format t ");~%")
            (if (eq (caddr (aref tab n)) 'dev)
                (progn
                  (format t "// node ~D is a device : tie the router L slave input idle~%" n)
                  (format t "assign ~A = 32'd0; assign ~A = 1'b0;~%"
                          (sl "l2r_awaddr" n 32) (bt "l2r_awvalid" n))
                  (format t "assign ~A = 32'd0; assign ~A = 4'd0; assign ~A = 1'b0;~%"
                          (sl "l2r_wdata" n 32) (sl "l2r_wstrb" n 4) (bt "l2r_wvalid" n))
                  (format t "assign ~A = 1'b1;~%" (bt "l2r_bready" n))
                  (format t "assign ~A = 32'd0; assign ~A = 3'd0; assign ~A = 1'b0;~%"
                          (sl "l2r_araddr" n 32) (sl "l2r_arprot" n 3) (bt "l2r_arvalid" n))
                  (format t "assign ~A = 1'b1;~%~%" (bt "l2r_rready" n)))
                (let* ((e (aref tab n))
                       (kk (seventh (find n cpus :key #'car))))
                  (format t "cpu_locmux lm~D~%(" n)
                  (format t "  .clk(clk), .rstb(rstb),~%")
                  (format t "  .im_araddr (~A), .im_arprot (~A),~%"
                          (sl "ci_araddr" kk 32) (sl "ci_arprot" kk 3))
                  (format t "  .im_arvalid(~A), .im_arready(~A),~%"
                          (bt "ci_arvalid" kk) (bt "ci_arready" kk))
                  (format t "  .im_rdata  (~A), .im_rresp  (~A),~%"
                          (sl "ci_rdata" kk 32) (sl "ci_rresp" kk 2))
                  (format t "  .im_rvalid (~A), .im_rready (~A),~%"
                          (bt "ci_rvalid" kk) (bt "ci_rready" kk))
                  (format t "  .dm_awaddr (~A), .dm_awvalid(~A), .dm_awready(~A),~%"
                          (sl "cd_awaddr" kk 32) (bt "cd_awvalid" kk) (bt "cd_awready" kk))
                  (format t "  .dm_wdata  (~A), .dm_wstrb  (~A), .dm_wvalid (~A),~%"
                          (sl "cd_wdata" kk 32) (sl "cd_wstrb" kk 4) (bt "cd_wvalid" kk))
                  (format t "  .dm_wready (~A),~%" (bt "cd_wready" kk))
                  (format t "  .dm_bresp  (~A),   .dm_bvalid (~A),  .dm_bready (~A),~%"
                          (sl "cd_bresp" kk 2) (bt "cd_bvalid" kk) (bt "cd_bready" kk))
                  (format t "  .dm_araddr (~A), .dm_arprot (~A), .dm_arvalid(~A),~%"
                          (sl "cd_araddr" kk 32) (sl "cd_arprot" kk 3) (bt "cd_arvalid" kk))
                  (format t "  .dm_arready(~A),~%" (bt "cd_arready" kk))
                  (format t "  .dm_rdata  (~A), .dm_rresp  (~A), .dm_rvalid (~A),~%"
                          (sl "cd_rdata" kk 32) (sl "cd_rresp" kk 2) (bt "cd_rvalid" kk))
                  (format t "  .dm_rready (~A),~%" (bt "cd_rready" kk))
                  (format t "  .l_awaddr  (~A), .l_awvalid(~A), .l_awready(~A),~%"
                          (sl "l2r_awaddr" n 32) (bt "l2r_awvalid" n) (bt "l2r_awready" n))
                  (format t "  .l_wdata   (~A), .l_wstrb  (~A), .l_wvalid (~A),~%"
                          (sl "l2r_wdata" n 32) (sl "l2r_wstrb" n 4) (bt "l2r_wvalid" n))
                  (format t "  .l_wready  (~A),~%" (bt "l2r_wready" n))
                  (format t "  .l_bresp   (~A),   .l_bvalid (~A),  .l_bready (~A),~%"
                          (sl "l2r_bresp" n 2) (bt "l2r_bvalid" n) (bt "l2r_bready" n))
                  (format t "  .l_araddr  (~A), .l_arprot (~A), .l_arvalid(~A),~%"
                          (sl "l2r_araddr" n 32) (sl "l2r_arprot" n 3) (bt "l2r_arvalid" n))
                  (format t "  .l_arready (~A),~%" (bt "l2r_arready" n))
                  (format t "  .l_rdata   (~A), .l_rresp  (~A), .l_rvalid (~A),~%"
                          (sl "l2r_rdata" n 32) (sl "l2r_rresp" n 2) (bt "l2r_rvalid" n))
                  (format t "  .l_rready  (~A)~%" (bt "l2r_rready" n))
                  (format t ");~%~%")))))
        (format t "endmodule~%")))))

;=========================================================================
; --boot : boot.as generator for rom0, driven by the *aximesh* config list.
;   the first cpu in config order (boot-en 1) is the orchestrator ; every
;   other cpu gets its own ram-test program in the rom. cpu0 writes each
;   compute cpu's IBASE (pc0, config 0x4) with the base of its test program
;   and starts them ONE AT A TIME (the test clobbers the whole ram and all
;   cpus share uart0, so strict sequencing keeps both race-free), polling
;   STAT (config 0xc bit0 halted) before moving on.
;   each test program walks ram 0x4000..0x5fff byte by byte :
;   write 0 / read-check / write #xff / read-check, then prints on uart0 :
;     "<n>: ram test finish\n"   or   "<n>: fail at address <hhhh>\n"
;   usage : sbcl --script sw.lisp --boot > boot.as~%;           sbcl --script sw.lisp --boot 4080 > boot_short.as   (sweep ends at absolute 0x4080)
;           sbcl --script sw.lisp asm -i boot.as -o rom.memh
;
; jumps are program-relative (p <= A, fetch = IBASE + p) while assembler
; labels are absolute, so every jump/const target here is computed
; numerically by this generator (two-pass) instead of using asm labels.
; scratch vars live in the writable rom (0x1fe0..0x1ffc), NOT in ram
; (they would be swept) and NOT in the io scratch ram (smol_io writes a
; single byte per transaction, fwstrb ignored there) :
;   0x1ffc t_cfg (own IBASE config addr, parked per TEST block)
;   0x1ff8 t_ib  0x1ff4 t_tgt  0x1ff0 t_t2   (shared-block jump fixups)
;   0x1fe4 t_ptr 0x1fe0 t_hex  0x1fe8 t_dig
; FIN/FAIL are shared : stored once, executed under every cpu's IBASE.
; (:j ...) fixups are compile-time relative to the EMITTING block, which
; only works when the cpu's IBASE == that block's base. shared blocks
; therefore never use (:j) internally : they read back their own ib_r
; (config 0x4 is readable) via t_cfg and compute every jump target at
; runtime (A = label_abs - ib_r).
; the sweep is word granular (every byte is covered by the word pokes)
; over 0x4000..ramend-1. poke 0 / poke -1 via the C0 and C-1 alu
; constants so the pointer never has to leave A for immediates.
(defun gen-boot (&optional (cfg *aximesh*) (ramend "6000"))
  (let* ((nodes (remove-if-not (lambda (e) (and (eq (car e) 'node)
                                                (eq (caddr e) 'cpu)))
                               cfg))
         (ncpus (length nodes))
         (ltab (make-hash-table :test 'equal))
         (blocks '()))
    (labels
        ;; one emit call = one group = one output line (tokens space
        ;; separated : the asm reader tokenizes on any whitespace, and the
        ;; dialect is a token stream, not line-based asm)
        ((emit (b items) (setf (cdr b) (nconc (cdr b) (list items))))
         (gputc (c)                  ; putc char code c : poll busy, write (LOCAL jumps only,
           (let ((p (gensym)))       ; usable inside a block whose base == the cpu's IBASE)
             (list (list :l p) "#x2104" "D=M" "1" "D=D&A" (list :j p "D?JNE")
                   (format nil "~D" c) "D=A" "#x2100" "M=D")))
         (gputs (s) (mapcan (lambda (c) (gputc (char-code c))) (coerce s 'list)))
         (gdigs (n) (gputs (format nil "~D" n)))
         (gquit () (list "#xffff" "C0?JMP"))
         ;; ---- shared-block machinery -------------------------------------
         ;; FIN/FAIL are stored once but run under every cpu's IBASE, so
         ;; their internal jumps must be recomputed against the RUNNING
         ;; cpu's ib_r : the running cpu's own IBASE config address is
         ;; parked by each TEST block at rom scratch 0x1ffc (t_cfg), the
         ;; block caches ib_r at 0x1ff8 (t_ib) on entry, and jump targets
         ;; are fixed up at runtime into 0x1ff4/0x1ff0 (t_tgt/t_t2).
         ;;   t_cfg @1ffc  t_ib @1ff8  t_tgt @1ff4  t_t2 @1ff0
         ;;   t_ptr @1fe4  t_hex @1fe0 t_dig @1fe8   (all in writable rom)
         (gcache () (list "#x1ffc" "A=M" "D=M" "#x1ff8" "MW=D")) ; t_ib = own ib_r
         (gj (l)   ; unconditional jump to shared label l (clobbers A,D)
           (list "#x1ffc" "A=M" "D=M" (list :a l) "A=A-D" "C0?JMP"))
         (sgputc (c) ; putc for shared blocks : poll target precomputed via t_ib
           (let ((p (gensym)))
             (list (list :a p) "D=A" "#x1ff8" "A=M" "D=D-A" "#x1ff4" "MW=D"
                   (list :l p)
                   "#x2104" "D=M" "1" "D=D&A" "#x1ff4" "A=M" "D?JNE"
                   (format nil "~D" c) "D=A" "#x2100" "M=D"))))
      ;; ---------------- cpu0 boot block ----------------
      (let ((boot (list "BOOT")))
        (loop for e in nodes for k from 0
              for node = (cadr e)
              for ben = (getf (cdddr e) :boot-en 0)
              unless (= ben 1)
              do (let ((w (gensym))
                       (cb (format nil "#x~X" (+ #x3000 (* k #x10)))))
                   (emit boot (list (list :a (format nil "TEST~D" k)) "D=A"
                         (format nil "#x~X" (+ #x3000 (* k #x10) 4)) "MH=D"))
                   (emit boot (list "1" "D=A" cb "M=D"))
                   (emit boot (list (list :l w) (format nil "#x~X" (+ #x3000 (* k #x10) #xc))
                         "D=M" "1" "D=D&A" (list :j w "D?JEQ")))))
        (emit boot (gquit))
        (push boot blocks))
      ;; ---------------- per-cpu ram test blocks ----------------
      (loop for e in nodes for k from 0
            for ben = (getf (cdddr e) :boot-en 0)
            unless (= ben 1)
            do (let ((tblk (list (format nil "TEST~D" k)))
                     (lp (gensym)) (fl (gensym)))
                 ;; park own IBASE config address for the shared FIN/FAIL blocks
                 (emit tblk (list (format nil "#x~X" (+ #x3000 (* k #x10) 4)) "D=A"
                                  "#x1ffc" "MW=D"))                    ; t_cfg = &own IBASE
                 (emit tblk (list "#x4000" "D=A" "#x1fe4" "MW=D"))    ; t_ptr = 0x4000
                 (emit tblk (list (list :l lp)))
                 (emit tblk (list "#x1fe4" "A=M"))                     ; A = t_ptr
                 (emit tblk (list "D=C0" "MW=D" "D=M" (list :j fl "D?JNE"))) ; poke 0, check
                 (emit tblk (list "#x1fe4" "A=M"))                     ; the :j pair clobbered A
                 (emit tblk (list "D=C-1" "MW=D" "D=M" "D=D+1" (list :j fl "D?JNE"))) ; poke -1, check
                 (emit tblk (list "#x1fe4" "D=M" "D=D+1" "D=D+1" "D=D+1" "D=D+1"
                                  "#x1fe4" "MW=D"))                    ; t_ptr += 4
                 (emit tblk (list (format nil "#x~A" ramend) "D=D-A" (list :j lp "D?JLT")))
                 (emit tblk (gdigs k))                            ; "n"
                 (emit tblk (list (list :j "FIN" "A?JMP")))
                 (emit tblk (append (list (list :l fl)) (gdigs k)))
                 (emit tblk (list (list :j "FAIL" "A?JMP")))
                 (push tblk blocks)))
      ;; ---------------- shared finish tail ----------------
      ;; runs under every cpu's IBASE : all internal jumps go through the
      ;; runtime fixup machinery (t_cfg/t_ib/t_tgt), never (:j ...)
      (let ((fin (list "FIN")))
        (emit fin (gcache))                             ; t_ib = own ib_r
        (mapc (lambda (c) (emit fin (sgputc (char-code c)))) (coerce ": ram test finish" 'list))
        (emit fin (sgputc 10))
        (emit fin (gquit))
        (push fin blocks))
      ;; ---------------- shared fail tail ----------------
      (let ((fail (list "FAIL")))
        (emit fail (gcache))                            ; t_ib = own ib_r
        (mapc (lambda (c) (emit fail (sgputc (char-code c)))) (coerce ": fail at address " 'list))
        (emit fail (list "#x1fe4" "D=M" "#x1fe0" "MW=D"))      ; t_hex = t_ptr
        (dolist (pp '(4096 256 16 1))
          (let ((h (gensym)) (hd (gensym)) (hl (gensym)) (hn (gensym))
                (pq (gensym)))
            (emit fail (list "D=C0" "#x1fe8" "MW=D"))          ; t_dig = 0
            ;; hoist the loop-exit target (the condition lives in D inside)
            (emit fail (list (list :a hd) "D=A" "#x1ff8" "A=M" "D=D-A"
                             "#x1ff0" "MW=D"))                 ; t_t2 = hd - ib
            (emit fail (list (list :l h) "#x1fe0" "D=M"
                  (format nil "~D" pp) "D=D-A" "#x1ff0" "A=M" "D?JLT"))
            (emit fail (list "#x1fe0" "D=M" (format nil "~D" pp) "D=D-A"
                  "#x1fe0" "MW=D"))                            ; t_hex -= pp
            (emit fail (list "#x1fe8" "D=M+1" "#x1fe8" "MW=D")) ; t_dig++
            (emit fail (gj h))
            (emit fail (list (list :l hd)))
            ;; digit -> char : t_dig < 10 -> +'0', else +'A'-10
            (emit fail (list (list :a hl) "D=A" "#x1ff8" "A=M" "D=D-A"
                             "#x1ff0" "MW=D"))                 ; t_t2 = hl - ib
            (emit fail (list "#x1fe8" "D=M" "10" "D=D-A" "#x1ff0" "A=M" "D?JGE"))
            (emit fail (list "#x1fe8" "D=M" "#x30" "D=D+A" "#x1fe8" "MW=D")) ; +'0'
            (emit fail (gj hn))
            (emit fail (list (list :l hl)
                  "#x1fe8" "D=M" "#x37" "D=D+A" "#x1fe8" "MW=D"))  ; +'A'-10
            (emit fail (list (list :l hn)))
            ;; print the char in t_dig (poll target precomputed via t_ib)
            (emit fail (list (list :a pq) "D=A" "#x1ff8" "A=M" "D=D-A"
                             "#x1ff4" "MW=D"
                  (list :l pq) "#x2104" "D=M" "1" "D=D&A" "#x1ff4" "A=M" "D?JNE"
                  "#x1fe8" "D=M" "#x2100" "M=D"))))
        (emit fail (sgputc 10))
        (emit fail (gquit))
        (push fail blocks))
      (setf blocks (nreverse blocks))
      ;; ---------------- pass 1 : addresses ----------------
      (let ((pc 8))                 ; bytes 0..7 = init.as trampoline (main A?JMP)
        (dolist (b blocks)
          (setf (gethash (car b) ltab) pc)
          (dolist (g (cdr b))       ; g = one emit group
            (dolist (it g)
              (cond ((stringp it)            (incf pc 4))
                    ((eq (car it) :l)        (setf (gethash (cadr it) ltab) pc))
                    ((eq (car it) :j)        (incf pc 8))
                    ((eq (car it) :a)        (incf pc 4))
                    (t (error "boot : bad item ~A" it))))))
        (if (> pc 8192) (error "boot : rom overflow, ~D bytes > 8192" pc))
        ;; ---------------- pass 2 : print ----------------
        (format t ";; boot.as : generated by sw.lisp --boot from *aximesh*~%")
        (format t ";;   ~D cpus, ~D bytes of rom used~%" ncpus pc)
        (format t "(inc \"init.as\")~%(main)~%")
        (dolist (b blocks)
          (format t ";; ---- ~A @ #x~4,'0X ----~%" (car b) (gethash (car b) ltab))
          ;; fetch base : boot block runs on cpu0 (IBASE=0), all other blocks
          ;; are fetched through the owning cpu's IBASE = their storage base
          (let ((fb (if (equal (car b) "BOOT") 0 (gethash (car b) ltab))))
            (dolist (g (cdr b))     ; one line per emit group
              (dolist (it g)
                (cond ((stringp it)      (format t "~A " it))
                      ((eq (car it) :l))
                      ((eq (car it) :j)
                       (format t "~D ~A " (- (gethash (cadr it) ltab) fb) (caddr it)))
                      ((eq (car it) :a)
                       (format t "#x~X " (gethash (cadr it) ltab)))))
              (format t "~%"))))))))

(let ((argvs (argv)))
  (dotimes (k (length argvs))
    (cond
      ((or
         (<= (length (argv)) 1)
         (equalp (nth k argvs) "-h"))
       (let ()
         (format t "-h help~%")
         (format t "-g debug on~%")
         (format t "-data [data section base addr]~%")
         (format t "asm ~%")
         (format t "    -print-all-insts ~%")
         (format t "    -i [input asm file]~%")
         (format t "    -o [output memh]~%")
         (format t "bin ~%")
         (format t "    -o [output binary]~%")
         (format t "--aximesh  print NoC mesh top verilog (config = *aximesh* list) > mesh.v~%")
         (format t "--boot     print boot.as for rom0 (bios + per-cpu ram tests) > boot.as~%")
         (format t "--boot HHHH  same, with the ram sweep ending at absolute address 0xHHHH (default 6000)~%")
         ))
      ((equalp (nth k argvs) "-g") (setf *debug* t))
      ((equalp (nth k argvs) "--aximesh") (gen-aximesh *aximesh*) (sb-ext:quit))
      ((equalp (nth k argvs) "--boot")
       (gen-boot *aximesh* (if (nth (1+ k) argvs) (nth (1+ k) argvs) "6000"))
       (sb-ext:quit))
      ((equalp (nth k argvs) "-data") (setf *data* (read-from-string(nth (1+ k) argvs))))
      ((equalp (nth k argvs) "asm") (setf *mode* 'asm))
      ((equalp (nth k argvs) "bin") (setf *mode* 'bin))
      ((and
         (equalp *mode* 'asm)
         (equalp (nth k argvs) "-print-all-insts"))
       (let ((k 0))
         (format t "| ASM             : HEX ~%")
         (dotimes (j 8) (format t "-------------------------")) (format t "~%")
         (map 'list
              (lambda (i)
                (format t "| ~15A : ~8,'0X " (nth 0 i) (cadr i))
                (if (= 7 (rem k 8)) (format t "~%"))
                (incf k)
                )
              *cinst*)
         ))
      ((equalp (nth k argvs) "-i")
       (case *mode*
         ('asm 
          (let ()
            (with-open-file (s (nth (1+ k) argvs) :direction :input) (asm s))
            ;(format t "mem : ~S~%" *mem*)
            ;(format t "label : ~S~%" *label*)
            ;(format t "daat : ~S~%" *data*)
            ))
         ))
      ((equalp (nth k argvs) "-o")
       (case *mode*
         ('asm 
          (let ((err nil))
            (setf *mem* 
                  (map 'list 
                       (lambda (m) 
                         (if (numberp m)
                           m
                           (if (assoc m *label*) 
                             (let ((c (logior #x7FC00000 (ash (logand #xffff (cadr(assoc m *label*))) 1))))
                               (if *debug* (format t "~4,'0X = ~A~%" (cadr(assoc m *label*)) m))
                               c)
                             (let ()
                               (setf err t)
                               (format t "error : no define: ~A~%" m)
                               m)))
                         ) 
                       *mem*))
            (if (not err)
            (let ((m (list)))
              (do ((u (pop *mem*) (pop *mem*))) 
                ((not *mem*)
                 (let ()
                   (push (logand #xff (ash u -24)) m)
                   (push (logand #xff (ash u -16)) m)
                   (push (logand #xff (ash u -8)) m)
                   (push (logand #xff u) m)
                   (setf *mem* m)))
                (push (logand #xff (ash u -24)) m)
                (push (logand #xff (ash u -16)) m)
                (push (logand #xff (ash u -8)) m)
                (push (logand #xff u) m))))
            (with-open-file (s (nth (1+ k) argvs) 
                                  :direction :output
                                  :if-does-not-exist :create
                                  :if-exists :supersede
                                  ) 
                 (format s "~{~2,'0x~%~}" *mem*))))
         ('bin
          (let ()
            (with-open-file (s (nth (1+ k) argvs) 
                                  :direction :output
                                  :if-does-not-exist :create
                                  :if-exists :supersede
                                  :element-type '(unsigned-byte 8)
                                  ) 
                 (map 'list
                      (lambda (b)
                        (write-byte b s))
                      *mem*))
            ))
         ))
      ))
  )
