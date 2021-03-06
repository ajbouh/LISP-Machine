;;; -*- Mode:LISP; Package:LAMBDA; Base:8; Readtable:ZL -*-

;;; Copyright LISP Machine, Inc. 1986
;;;   See filename "Copyright.Text" for
;;; licensing and release information.

;4/86 bobp
;Working copy for purpose of change spi- funcs to methods, to support
;both the LMI debug board and explorer-spi / nu-debug.

;In general, every command will send back at least a space.
;The ones that want to return values print each as a hex number
;separated by a space, and terminated by a space.  An error response
;is a '*' followed by one hex digit of error code.  It is defined
;that except for the T0 and T1 test commands, that if an error
;is going to happen, it will be returned before any data.

;it looks like it always ends a command with <space><cr>  (but no <lf>)


(defvar *stream* nil)
(defvar *spi-trace* nil)

(defvar *spi-lock* nil)

(defun spi-command (nbits format-string &rest format-args)
  (with-lock (*spi-lock*)
    (if (string-search "~%" format-string)
        (ferror nil "format-string must not contain newlines!"))
    (cond (*spi-trace*
           (format *spi-trace* "<")
           (apply 'format *spi-trace* format-string format-args)
           (format *spi-trace* ">")))
    (apply 'format *stream* format-string format-args)
    (send *stream* :tyo #/newline)
    (send *stream* :force-output)
    (read-response nbits)))

(defconst error-responses '("Unknown error code"                ;0
                            "Invalid Command"                   ;1
                            "Invalid Hex Number"                ;2
                            "Raven Not Halted"                  ;3
                            "Trace in Progress"                 ;4
                            "Shifter Busy"                      ;5
                            "Number Out of Range"               ;6
                            "Shifter Test Error"                ;7
                            "Trace Ram Test part 1 Error"       ;8
                            "Selected IBUF empty"               ;9
                            "Trace Ram Test part 2 Error"       ;A
                            ))

(defun spi-tyi ()
  (do ((c (logand 177 (char-int (send *stream* :tyi-busy-wait)))
          (logand 177 (char-int (send *stream* :tyi-busy-wait)))))
      ((not (= c 15))
       (if *spi-trace*
           (if (char-equal c #/space)
               (send *spi-trace* :tyo #/ )
             (send *spi-trace* :tyo c)))
       c)
    (if *spi-trace*
        (if (char-equal c #/space)
            (send *spi-trace* :tyo #/ )
          (send *spi-trace* :tyo c)))))

(defun read-response (&optional nbits)
  (do* ((c (spi-tyi) (spi-tyi))
        (digit (digit-char-p c 16.) (digit-char-p c 16.))
        (first-time t nil)
        (val 0))
       ((and (null digit)
             (not (memq c '(15 215 12))))       ;anybody's CR or LF
        (cond ((char-equal c #/space)
               (cond ((or (null nbits) (= nbits 0))
                      (cond ((null first-time)
                             (ferror nil ; 'unexpected-value
                                     "The value ~x was returned when no value was expected."
                                     val))
                            (t nil)))
                     (t
                      (logand (1- (ash 1 nbits)) val))))
              ((char-equal c #/*)
               (let* ((code (digit-char-p (spi-tyi) 16.))
                      (space (spi-tyi)))
                 (cond ((char-equal space #/space)
                        (ferror nil ;'spi-error
                                "SPI error ~x: ~s; accumulated value ~x"
                                code (nth code error-responses) val))
                       (t
                        (ferror nil ;'spi-error
                          "SPI error ~x: ~s; + protocol broke down"
                                code (nth code error-responses))))))
              (t
               (ferror nil ;'spi-error
                       "Unknown character ~c received.  Accumulated val is ~x."
                       c val))))
    (if digit
        (setq val (+ (ash val 4) digit)))))


(defun spi-write-shift-register (data)
  "Write 16 bits of DATA to the shift register on the SPI board.
Error response if Explorer running, or if shifter is busy."
  (spi-command nil "W0 ~x" data))

(defmethod (ti-serial-access-path :spi-write-trace-ram-adr) (adr)
  "Write 12 bits of ADR to trace ram address register.
Error response if SPI board is in TRACE mode."
  (spi-command nil "W1 ~x" adr))

(defmethod (ti-serial-access-path :spi-write-trace-ram-data) (data)
  "Write 16 bits of DATA to the trace ram at the current address,
then increment the address.  Error response if TRACE mode is on."
  (spi-command nil "W2 ~x" data))

(defmethod (ti-serial-access-path :spi-write-cr1) (data)
  "Write 16 bits of DATA to the SPI board control register 1.
No error is possible."
  (spi-command nil "W3 ~x" data))

(defmethod (ti-serial-access-path :spi-write-cr2) (data)
  "Write 16 bits of DATA to the SPI board control register 2.
No error is possible."
  (spi-command nil "W4 ~x" data))

(defmethod (ti-serial-access-path :spi-write-stop-on-pc-address) (adr)
  "Write 14 bit micro-pc address to stop on.
No error is possible."
  (spi-command nil "W5 ~x" adr))

(defmethod (ti-serial-access-path :spi-read-nth-previous-pc) (nth)
  "Read the PC that is NTH locations back in the trace ram,
then restore the trace ram address.  Error if in TRACE mode."
  (spi-command 16. "W6 ~x" (logand #o1777 nth)))

;;;W7 undefined

(defmethod (ti-serial-access-path :spi-write-obus) (data)
  "Write 32 bits of DATA to the explorer OBUS.  SPIPROG
doesn't have any error checks on this one."
  (spi-command nil "W8 ~x" data))

(defun compute-raven-cram-parity (data)
  (setq data (dpb 0 rav-ir-parity data))
  (let ((parity 1))
    (dotimes (bit 56.)
      (setq parity (logxor parity (ldb (byte 1 bit) data))))
    (dpb parity rav-ir-parity data)))

(defmethod (ti-serial-access-path :spi-write-ir) (data)
  "Write 56 bits to explorer IREG.  No error checks on this one."
  (spi-command nil "W9 ~x" (compute-raven-cram-parity data)))

(defmethod (ti-serial-access-path :spi-write-ir-fixnums) (low middle high top)
  "Write 56 bits, passed as 4 16 bit fixnums to IR."
  (ferror nil "not used")
  (spi-command nil "W9 ~4,'0x~4,'0x~4,'0x~4,'0x" top high middle low))


;;;action:
;;;  error if running bit is on
;;; error if shifter is busy
;;; select PC for shifter
;;; assert PCFORCE.L
;;; shift given address left by 2 to align it and write to shifter
;;; loop until shifter not busy
;;; assert FORCENOP.L
;;; assert SINGLESTEP.L
;;; deassert SINGLESTEP.L
;;; deassert PCFORCE.L
;;; deassert FORCENOP.L
(defmethod (ti-serial-access-path :spi-write-pc) (adr)
  "Write 14 bits to explorer PC.  Error response if in TRACE mode
or if shifter is busy."
  (spi-command nil "WA ~x" adr))

;;;action:
;;; assert FORCENOP.L
;;; ... SHIFT IR SUBROUTINE ...
;;;  error if RUNNING
;;;  error if shifter BUSY
;;;  select IR for shifter
;;;  write the shifter and wait for it to finish 4 times
;;; ... end ...
;;; assert CSRAMDIS.L and CSPROMDIS.L
;;; assert IRSHFTEN.L
;;; assert CS.RAM.WE.L
;;; deassert CS.RAM.WE.L
;;; deassert CS.RAM.DISABLE.L
;;; assert CS.RAM.DISABLE.L
;;; deassert CS.RAM.WE.L
;;; deassert IRSHFTEN.L
;;; deassert CSRAMDIS.L and CSPROMDIS.L
;;; deassert FORCENOP.L
(defmethod (ti-serial-access-path :spi-write-cram) (data)
  "Write 56 bits into CRAM at location addressed by current PC.
Error if RUNNING or TRACE mode on."
  (spi-command nil "WB ~x" (compute-raven-cram-parity data)))

;;;action:
;;; ... subroutine to write OBUS ...
;;;  error if running
;;;  error if shifter BUSY
;;;  select OBUS for shifter
;;;  write data to shifter and wait until done
;;; ... end ...
;;; assert OBSHFTEN.L
;;; assert MDLOAD.L
;;; deassert MDLOAD.L
;;; deassert OBSHFTEN.L
(defmethod (ti-serial-access-path :spi-write-md) (data)
  "Write 32 bits into MD.  Error if running or TRACE mode."
  (spi-command nil "WC ~x" data))

(defun spi-write-990-adr (adr)
  "Write 16 bit address of place to hack in 990 micro's memory.
No error checks."
  (spi-command nil "WD ~x" adr))

(defun spi-write-990-data (data)
  "Write 16 bits to current 990 address.  No error checks."
  (spi-command nil "WE ~x" data))

(defun spi-write-990-data-and-increment-address (data)
  "Write 16 bits to current 990 address, then increment the address."
  (spi-command nil "WF ~x" data))

;;;action:
;;; error if running
;;; error if busy
;;; read shift register and print it
(defmethod (ti-serial-access-path :spi-read-shift-register) ()
  "Read 16 bit contents of the shift register.  Error if running or busy."
  (spi-command 16. "R0"))

;;;action:
;;; error if TRACE on
;;; read and print low 12 bits of trace address
(defmethod (ti-serial-access-path :spi-read-trace-ram-adr) ()
  "Read 12 bit trace ram address.  Error if trace on."
  (spi-command 12. "R1"))

;;;action:
;;; error if TRACE on
;;; read and print 16 bits of trace data
(defmethod (ti-serial-access-path :spi-read-trace-ram-data) ()
  (spi-command 16. "R2"))

(defun spi-read-cr1 ()
  "Read software copy of control register 1."
  (spi-command 16. "R3"))

(defun spi-read-cr2 ()
  "Read software copy of control register 2."
  (spi-command 16. "R4"))

(defmethod (ti-serial-access-path :spi-read-stop-on-pc-address) ()
  "Read software copy of stop on pc address."
  (spi-command 14. "R5"))

(defun spi-read-spi-status ()
  "Read status register from spi board."
  (spi-command 16. "R6"))

;;; R7 undefined

;;;action:
;;; error if running
;;; error if busy
;;; select OBUS for shifter
;;; do two shift operations to get 32 bits, and print them
(defmethod (ti-serial-access-path :spi-read-obus) ()
  "Read OBUS.  Error if running or shifter busy."
  (spi-command 32. "R8"))

;;;action:
;;; error if running
;;; error if busy
;;; assert FORCENOP.L
;;; select IR for shifter
;;; shift it out in 4 chunks, and print it
;;; deassert FORCENOP.L
(defmethod (ti-serial-access-path :spi-read-ir) ()
  "Read IR.  Error if running or shifter busy."
  (spi-command 56. "R9"))

;;;action:
;;; error if running
;;; read PC directly from TRACE buffers, and print 14 bits worth.
(defmethod (ti-serial-access-path :spi-read-pc) ()
  "Read 14 bits of PC.  Error if running."
  (spi-command 14. "RA"))

;;; RB undefined
;;; RC undefined

(defun spi-read-990-adr ()
  (spi-command 16. "RD"))

(defun spi-read-990-data ()
  (spi-command 16. "RE"))

(defun spi-read-990-data-and-increment-address ()
  (spi-command 16. "RF"))

(defmethod (ti-serial-access-path :spi-load-ibuf) (ibuf-num data)
  "Make IBUF-NUM contain the instruction DATA."
  (check-type ibuf-num (fixnum 0 7))
  (spi-command nil "L~x ~x" ibuf-num data))

(defmethod (ti-serial-access-path :spi-load-ir-from-ibuf) (ibuf-num)
  "Do SPI-WRITE-IR with the data in IBUF-NUM."
  (check-type ibuf-num (fixnum 0 7))
  (spi-command nil "E~x" ibuf-num))

(defmethod (ti-serial-access-path :spi-read-ibuf) (ibuf-num)
  "Print the contents of IBUF-NUM."
  (check-type ibuf-num (fixnum 0 7))
  (spi-command 56. "I~x" ibuf-num))

(defmethod (ti-serial-access-path :spi-run) ()
  (spi-command nil "S0 1"))

(defmethod (ti-serial-access-path :spi-stop) ()
  (spi-command nil "S0 0"))

;action:
; assert SINGLE.STEP.L
; deassert SINGLE.STEP.L
(defmethod (ti-serial-access-path :spi-single-step) ()
  (spi-command nil "S1 0"))

;action:
; assert RELEASE.HALT.L
; deassert RELEASE.HALT.L
(defmethod (ti-serial-access-path :spi-release-halt) ()
  (spi-command nil "S2 0"))

; assert LONGCLOCK.L
(defmethod (ti-serial-access-path :spi-long-clock) ()
  (spi-command nil "S3 0"))

; deassert LONGCLOCK.L
(defmethod (ti-serial-access-path :spi-normal-clock) ()
  (spi-command nil "S3 1"))

; assert FORCENOP.L
(defmethod (ti-serial-access-path :spi-force-noop) ()
  (spi-command nil "S4 0"))

; deassert FORCENOP.L
(defmethod (ti-serial-access-path :spi-dont-force-noop) ()
  "Don't NOOP next instruction."
  (spi-command nil "S4 1"))

;assert CSPARDIS.L
(defmethod (ti-serial-access-path :spi-disable-cram-parity) ()
  (spi-command nil "S5 0"))

;deassert CSPARDIS.L
(defmethod (ti-serial-access-path :spi-enable-cram-parity) ()
  (spi-command nil "S5 1"))

(defmethod (ti-serial-access-path :spi-mdr-enable-mode) (n)
  (spi-command nil "SA ~s" n))

(defmethod (ti-serial-access-path :spi-vma-enable-mode) (n)
  (spi-command nil "SB ~s" n))

(defmethod (ti-serial-access-path :spi-force-pc) (n)
  (spi-command nil "S8 ~s" n))

;(defun spi-disable-cs-ram (n)
;  (spi-command nil "SD ~s" n))

;(defun spi-disable-cs-rom (n)
;  (spi-command nil "SE ~s" n))

;also takes care of CSRAMDIS.L and CSROMDIS.L
(defmethod (ti-serial-access-path :spi-enable-ir-shifter-l) (n)
  (spi-command nil "S6 ~s" n))

;;; These directly control various control register bits.
;;; We probably don't need them.
;;;
;;;  S7 OB shifter output enable  OBSHFTEN.L
;;;  S9 MDLOAD.L
;;;  SC CS.RAM.WE.L

;assert RAVEN.RESET.L
(defmethod (ti-serial-access-path :spi-reset) ()
  (spi-command nil "SF 0"))

;deassert RAVEN.RESET.L
(defmethod (ti-serial-access-path :spi-enable) ()
  (spi-command nil "SF 1"))

(defmethod (ti-serial-access-path :spi-trace-on) ()
  (spi-command nil "C0 0"))

(defmethod (ti-serial-access-path :spi-trace-off) ()
  (spi-command nil "C0 1"))

(defmethod (ti-serial-access-path :spi-enable-stop-on-pc) ()
  (spi-command nil "C1 0"))

(defmethod (ti-serial-access-path :spi-disable-stop-on-pc) ()
  (spi-command nil "C1 1"))

(defmethod (ti-serial-access-path :spi-select-pc-shifter) ()
  (spi-command nil "C3 0"))

(defmethod (ti-serial-access-path :spi-select-ir-shifter) ()
  (spi-command nil "C4 0"))


;;; don't need
;;;
;;;  C2 select TEST shifter
;;;  C5 select OB shifter
;;;  C6 start shifter
;;;  C7 next 16 bits from shifter
;;;  C8 reset shifter
;;;  C9 undefined
;;;  CA undefined
;;;  CB undefined
;;;  CC undefined
;;;  CD undefined
;;;  CE undefined
;;;  CF 0 = Echo off, use AUX port
;;;     1 = Echo on, use MAIN port

(defun spi-test-0 ()
  (spi-command nil "T0"))

(defun spi-test-1 ()
  (spi-command nil "T1"))

;------------------------------------------------------------------------

(defvar spi-baud-rate 2400.)

(defun exp-serial-setup ()
  (cond ((null *stream*)
         (setq *stream* (open "SDU-SERIAL-B:"))))
  (send *stream* :reset)
  (send *stream* :set-baud-rate spi-baud-rate)
  (send *stream* :tyo #o15)
  (process-sleep 30.)
  (do ()
      ((null (send *stream* :tyi-no-hang)))
    (do ()
        ((null (send *stream* :tyi-no-hang))))
    (process-sleep 30.))
  (print-spi-status-data (spi-read-spi-status))
  )

(defun trace-on ()
  (setq *spi-trace* (make-syn-stream 'terminal-io)))

(defun trace-off ()
  (setq *spi-trace* nil))

(defun print-spi-status-data (data)
  (format t "~&------------------------------------------------")
  (format t "~&Status = #o~o #x~:*~x" data)
  (format t "~&running ~s" (ldb (byte 1 1) data))
  (format t "~&trace overflow ~s" (ldb (byte 1 2) data))
  (format t "~&-MDR En ~s" (ldb (byte 1 3) data))
  (format t "~&-VMA En ~s" (ldb (byte 1 4) data))
  (format t "~&-Test Sync bit ~s" (ldb (byte 1 5) data))
  (format t "~&-jump taken last ~s" (ldb (byte 1 6) data))
  (format t "~&-next noop ~s" (ldb (byte 1 7) data))
  (format t "~&~:[~;IMODLO this instruction~]" (ldb-test (byte 1 8) data))
  (format t "~&~:[~;IMODHI this instruction~]" (ldb-test (byte 1 9) data))
  (format t "~&-page fault pending ~s" (ldb (byte 1 10.) data))
  (format t "~:[~&Control store parity error~]" (ldb-test (byte 1 11.) data))
  (format t "~&-Halt FF ~s" (ldb (byte 1 12.) data))
  (format t "~&-bus error pending ~s" (ldb (byte 1 13.) data))
  (format t "~&Prom ~:[enabled~;disabled~]" (ldb-test (byte 1 14.) data))
  (format t "~&Shifter ~:[not ~]busy" (ldb-test (byte 1 15.) data))
  (format t "~&------------------------------------------------")
  )

(defun print-spi-status ()
  (print-spi-status-data (spi-read-spi-status)))


(defun print-cr1-data (data)
  (format t "~&-Reset ~s" (ldb (byte 1 0) data))
  (format t "~&-MDLoad ~s" (ldb (byte 1 3) data))
  (format t "~&-OB Shift En ~s" (ldb (byte 1 4) data))
  (format t "~&-ir shift En ~s" (ldb (byte 1 5) data))
  (format t "~&-pc force ~s" (ldb (byte 1 6) data))
  (format t "~&-cs parity disable ~s" (ldb (byte 1 7) data))
  (format t "~&-cs ram we ~s" (ldb (byte 1 8) data))
  (format t "~&-cs prom disable ~s" (ldb (byte 1 9) data))
  (format t "~&-cs ram disable ~s" (ldb (byte 1 10.) data))
  (format t "~&-force noop ~s" (ldb (byte 1 11.) data))
  (format t "~&-long clock ~s" (ldb (byte 1 12.) data))
  (format t "~&-release halt ~s" (ldb (byte 1 13.) data))
  (format t "~&-single step ~s" (ldb (byte 1 14.) data))
  (format t "~&Run ~s" (ldb (byte 1 15.) data)))

(defun print-cr1 ()
  (print-cr1-data (spi-read-cr1)))

(defun print-cr2-data (data)
  (format t "~&-MDR set ~s" (ldb (byte 1 6) data))
  (format t "~&-VMA set ~s" (ldb (byte 1 7) data))
  (format t "~&-Reset shifter ~s" (ldb (byte 1 11.) data))
  (format t "~&Shifter select: ~[Test~;PC~;IR~;OB~]" (ldb (byte 2 12.) data))
  (format t "~&-stop on pc ~s" (ldb (byte 1 14.) data))
  (format t "~&-trace enable ~s" (ldb (byte 1 15.) data)))

(defun print-cr2 ()
  (print-cr2-data (spi-read-cr2)))

(defun spi-connect ()
  (do-forever
    (process-wait "Kbd or SPI"
                  #'(lambda (keyboard stream)
                      (or (send keyboard :listen)
                          (send stream :listen)))
                  terminal-io *stream*)
    (do ((c (send terminal-io :tyi-no-hang)
            (send terminal-io :tyi-no-hang)))
        ((null c))
      (setq c (int-char (char-upcase c)))
      (if (char-equal c #/end) (return-from spi-connect nil))
      (send *stream* :tyo
            (selectq c
              (#/return 15)
              (t c))))
    (do ((c (send *stream* :tyi-no-hang)
            (send *stream* :tyi-no-hang)))
        ((null c))
      (setq c (logand 177 (char-int c)))
      (send standard-output :tyo
            (selectq c
              (15 #/return)
              (#/space #/ )
              (t c))))))


;interesting bits:

;control register 1
;  0 reset.raven.l
;  1 undef
;  2 undef
;  3 mdload.l
;  4 obshften.l
;  5 irshften.l
;  6 pcforce.l
;  7 cs.parity.disable.l
; 10 cs.ram.we.l
; 11 cs.prom.disable.l
; 12 cs.ram.disable.l
; 13 forcenop.l
; 14 longclock.l
; 15 release.halt.l
; 16 single.step.l
; 17 run

;control register 2
;  0 undef
;  1 undef
;  2 undef
;  3 undef
;  4 undef
;  5 undef
;  6 mdrset.l
;  7 vmaset.l
; 10 undef
; 11 undef
; 12 undef
; 13 reset.shifter.l
; 14 shift.sel.0
; 15 shift.sel.1
; 16 stop.on.pc.enable.l
; 17 trace.enable.l

;status reg
;  0 undef
;  1 running
;  2 trace.overflow
;  3 mdren.l
;  4 vmaen.l
;  5 testsync.l
;  6 jtakenlast.l
;  7 nop.l
; 10 imodlo
; 11 imodhi
; 12 page.fault.l
; 13 cs.parity.error
; 14 halt.l
; 15 buserr.l
; 16 prom.enabled.l
; 17 shifter.busy
(defconst rav-noop-bit (byte 1 7))


(defun raven-execute-constant-p (x)
  (or (numberp x)
      (and (symbolp x)
           (get x 'constant))))

(defmacro raven-execute (options &body fields-and-values)
  (let ((inst 0))
    (do ((tail fields-and-values (cddr tail)))
        ((null tail))
      (cond ((raven-execute-constant-p (cadr tail))
             (setq inst (dpb (eval (cadr tail)) (symeval (car tail)) inst)))))
    (do ((tail fields-and-values (cddr tail)))
        ((null tail))
      (cond ((not (raven-execute-constant-p (cadr tail)))
             (setq inst `(dpb ,(cadr tail) ,(symeval (car tail)) ,inst)))))
    (selectq (car options)
      (read `(raven-execute-read ,inst))
      (write `(raven-execute-write ,inst))
      (print `(raven-execute-print ,inst))
      (return inst)
      (test `(raven-execute-test ,inst))
      (t (ferror nil "bad option")))))

(defun raven-execute-read (inst)
  (send self :spi-write-ir inst))

;(defun raven-execute-test (inst)
;  (test-spi-write-ir inst))

(defun raven-execute-write (inst)
  (send self :spi-write-ir inst)
  (send self :spi-single-step)
  (send self :spi-force-noop)
  (send self :spi-single-step)
  (send self :spi-dont-force-noop))

(defun raven-execute-print (inst)
  (lam-print-uinst inst))

(defmacro rav-read-func-src (n)
  `(progn
     (raven-execute (read)
       rav-ir-op rav-op-alu
       rav-ir-ob rav-ob-alu
       rav-ir-aluf rav-alu-setm
       rav-ir-m-src ,n)
     (send self :spi-read-obus)))

(defmacro rav-write-func-dest (n val)
  `(progn
     (send self :spi-write-md ,val)
     (raven-execute (write)
       rav-ir-op rav-op-alu
       rav-ir-ob rav-ob-alu
       rav-ir-aluf rav-alu-setm
       rav-ir-m-src rav-m-src-md
       rav-ir-func-dest ,n)))

(defun spi-running-p ()
  (ldb-test (byte 1 1) (spi-read-spi-status)))

(defun spi-wait-for-shifter-ready ()
  (do ()
      ((zerop (ldb (byte 1 15.) (spi-read-spi-status))))))

(defun spi-write-ir-shifter-in-raven (data)
  (send self :spi-select-ir-shifter)
  (spi-write-shift-register (ldb (byte 8. 48.) data)) ;also tests for running and busy
  (spi-wait-for-shifter-ready)
  (spi-write-shift-register (ldb (byte 16. 32.) data))
  (spi-wait-for-shifter-ready)
  (spi-write-shift-register (ldb (byte 16. 16.) data))
  (spi-wait-for-shifter-ready)
  (spi-write-shift-register (ldb (byte 16. 0.) data))
  (spi-wait-for-shifter-ready)
  )

(defmethod (ti-serial-access-path :spi-execute-then-write-ireg) (data)
  (spi-write-ir-shifter-in-raven (compute-raven-cram-parity data))
  (send self :spi-enable-ir-shifter-l 0)
  (send self :spi-single-step)
  (send self :spi-enable-ir-shifter-l 1)
  )

(defmethod (ti-serial-access-path :spi-execute-ireg-at-full-speed) ()
  (spi-write-ir-shifter-in-raven (raven-execute (return)
                                   rav-ir-op rav-op-alu
                                   rav-ir-halt 1))
  (send self :spi-enable-ir-shifter-l 0)
  (send self :spi-run)
  (process-sleep 1)
  (send self :spi-stop)
  (send self :spi-enable-ir-shifter-l 1)
  )

(defun spi-cold-boot ()
  (send self :spi-reset)
  (send self :spi-enable)
  (send self :spi-trace-on)
  (send self :spi-run)
  (setq lam-full-save-valid nil)
  (setq lam-passive-save-valid nil)
  (qf-clear-cache t)
  )

;;;;;;;;;;;;;;;;

;moved from regint-explorer

;(regint-explorer :bus-quad-slot-read)
(defmethod (ti-serial-access-path :bus-quad-slot-read) (quad-slot byte-adr)
  (rav-phys-read (dpb quad-slot (byte 8 24.) byte-adr)))

(defmethod (ti-serial-access-path :bus-quad-slot-write) (quad-slot byte-adr data)
  (rav-phys-write (dpb quad-slot (byte 8 24.) byte-adr) data))

;;;;;;;;;;;;;;;;

(defmethod (ti-serial-access-path :spi-status-md-enable) ()
  (ldb (byte 1 3) (spi-read-spi-status)))

(defmethod (ti-serial-access-path :spi-status-vma-enable) ()
  (ldb (byte 1 4) (spi-read-spi-status)))

(defmethod (ti-serial-access-path :spi-status-bnop) ()
  (ldb (byte 1 7) (spi-read-spi-status)))

(defmethod (ti-serial-access-path :spi-status-imod-hi) ()
  (ldb (byte 1 9) (spi-read-spi-status)))

(defmethod (ti-serial-access-path :spi-status-imod-low) ()
  (ldb (byte 1 8) (spi-read-spi-status)))

(defmethod (ti-serial-access-path :spi-status-halted) ()
  (ldb (byte 1 12.) (spi-read-spi-status)))
