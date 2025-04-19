; File:      timer-m48-lc204.asm
; Device:    ATmega48
; Assembler: Atmel avrasm2
; Created:   2023-10-09
; Version:   2025-04-19
; Author:    Johannes Fechner
;            https://www.mikrocontroller.net/user/show/jofe

.nolist
.include <m48def.inc>
.list

; == Some general macros ==
#define ROUND(X) (int(1.0*(X)+0.5))
#define CEIL(X) (frac(X) > 0 ? int(X)+1 : int(X))

.macro xout ; eXtended "out"
.if @0 > 0x3F
    sts @0, @1
.else
    out @0, @1
.endif
.endmacro

.macro xin ; eXtended "in"
.if @1 > 0x3F
    lds @0, @1
.else
    in  @0, @1
.endif
.endmacro

.macro ldiz ; Load immediate into Z double register.
    ldi     ZH, high(@0)
    ldi     ZL, low(@0)
.endmacro

.macro addz ; Add register to Z double register; register 'zero' must contain 0x00.
    add     ZL, @0
    adc     ZH, zero
.endmacro

; == IR configuration ==
; Currently implemented IR codecs, values following <https://www.mikrocontroller.net/articles/IRMP>:
.equ IR_NEC = 2
.equ IR_KASEIKYO = 5
.equ IR_SAMSUNG32 = 10
.equ IR_ONKYO = 56
.equ IR_NEC_EXT = 59 ; Not defined by IRMP.

; Choose the IR codec from the ones listed above:
.equ IR_PROTOCOL = IR_NEC

; Choose whether to recognize repetition frames, resulting in the IR_STATUS_REPETITION flag being set.
; Only available if the chosen protocol uses them.
; Set the following symbol to 0 in order to disable the recognition of repetition frames:
.equ IR_RECOGNIZE_REPETITION = 0

; Choose whether the IR_STATUS_DISCARDED flag is to be set when a reception was discarded,
; in addition to saving an error code and the counter values to RAM.
; Set the following symbol to 0 in order to disable that:
.equ IR_DEBUG = 0

; Set the admissible time tolerance in %:
.equ IR_TOLERANCE = 30

; Set the IR interrupt time distance in microseconds (us):
.equ IR_SET_DIST = 50

; Set the denominator of the IR timer prescaler:
.equ IR_TIMER_PRESC = 1

; == IR definitions ==
; === The register ir_status ===
; Bit positions are assigned as follows:
.equ IR_STATUS_PREV_bp = 0 ; previous state of IR RX input
.equ IR_STATUS_DATA_bp = 1 ; event flag, received valid data frame
.if IR_RECOGNIZE_REPETITION
.equ IR_STATUS_REPETITION_bp = 2 ; event flag, received repetition frame
.endif
.if IR_DEBUG
.equ IR_STATUS_DISCARDED_bp = 3 ; event flag, discarded reception
.endif

; === Possible values of register ir_pulseCntr ===
; Pulse/pause # within a frame, incremented at each falling edge (= begin of pulse):
; 0 = no edge received yet, waiting for begin of start pulse; or pulse already too long -> to be discarded
; 1 = after start edge, start pulse or pause ongoing
; 2 = first data pulse or pause ongoing, after reception of start pulse+pause
; 3 = second data pulse or pause ongoing, after reception of first data pulse+pause
; .
; .
; .
; 33 = last data pulse or pause ongoing (NEC or similar)
; 34 = stop pulse ongoing (NEC or similar)
.equ IR_DATA_START = 3 ; value of ir_pulseCntr when first data pulse+pause has been received
.equ IR_REPETITION_PAUSE_RECEIVED = 200 ; = repetition pause received, possible repetition frame stop bit ongoing

; === Debug message codes ===
.equ IR_PULSE_TOO_SHORT = $00
.equ IR_PULSE_TOO_LONG = $01
.equ IR_PAUSE_TOO_SHORT = $02
.equ IR_PAUSE_BETWEEN_0_1 = $03
.equ IR_PAUSE_TOO_LONG = $04
.equ IR_PAUSE_START_TOO_SHORT = $05
.equ IR_PAUSE_START_BETWEEN_R_D = $06
.equ IR_PAUSE_START_TOO_LONG = $07
.equ IR_PULSE_START_TOO_SHORT = $08
.equ IR_PULSE_START_TOO_LONG = $09
.equ IR_DATA_INVALID = $0A

; === IR code definitions ===
; Time values must be in ascending order, otherwise the corresponding comparisons must be modified.
.if IR_PROTOCOL == IR_NEC || IR_PROTOCOL == IR_NEC_EXT || IR_PROTOCOL == IR_ONKYO
; Time distances in microseconds (us):
.equ IR_PULSE = 560
.equ IR_PAUSE_0 = 560
.equ IR_PAUSE_1 = 1690
.equ IR_PAUSE_START_REPETITION = 2250
.equ IR_PAUSE_START_DATA = 4500
.equ IR_PULSE_START = 9000
; Data bit count:
.equ IR_DATA_BIT_CNT = 32
; Pulse count including start and stop bit:
.equ IR_PULSE_COUNT = IR_DATA_BIT_CNT + 2
.equ IR_DATA_BYTE_CNT = CEIL(IR_DATA_BIT_CNT / 8)

.elif IR_PROTOCOL == IR_SAMSUNG32
; Time distances in microseconds (us):
.equ IR_PULSE = 550
.equ IR_PAUSE_0 = 550
.equ IR_PAUSE_1 = 1650
.equ IR_PAUSE_START_DATA = 4500
.equ IR_PULSE_START = 4500
; Data bit count:
.equ IR_DATA_BIT_CNT = 32
; Pulse count including start and stop bit:
.equ IR_PULSE_COUNT = IR_DATA_BIT_CNT + 2
.equ IR_DATA_BYTE_CNT = CEIL(IR_DATA_BIT_CNT / 8)

.elif IR_PROTOCOL == IR_KASEIKYO
; Time distances in microseconds (us):
.equ IR_PULSE = 423
.equ IR_PAUSE_0 = 423
.equ IR_PAUSE_1 = 1269
.equ IR_PAUSE_START_DATA = 1690
.equ IR_PULSE_START = 3380
; Data bit count:
.equ IR_DATA_BIT_CNT = 48
; Pulse count including start and stop bit:
.equ IR_PULSE_COUNT = IR_DATA_BIT_CNT + 2
.equ IR_DATA_BYTE_CNT = CEIL(IR_DATA_BIT_CNT / 8)
.else
.error "Missing protocol definitions in irRxPulseDistance.asm."
.endif

; === Calculations ===
#define IR_TIMER_OCR ROUND(F_CPU*IR_SET_DIST*(1.0e-6)/IR_TIMER_PRESC-1)
; Calculate the resulting time distance between IR interrupts in microseconds (us):
#define IR_REAL_DIST (1.0e6*IR_TIMER_PRESC*(IR_TIMER_OCR+1)/F_CPU)
; Calculate the approximate ISR call counts of time constants (T is time in microseconds):
#define IR_MIN_CALLS(T) ROUND((100.0-IR_TOLERANCE)*(T)/IR_REAL_DIST/100.0)
#define IR_MAX_CALLS(T) ROUND((100.0+IR_TOLERANCE)*(T)/IR_REAL_DIST/100.0)

; === For testing ===
.equ IR_PAUSE_0_MAX = IR_MAX_CALLS(IR_PAUSE_0)
.equ IR_PAUSE_1_MIN = IR_MIN_CALLS(IR_PAUSE_1)
.if IR_PAUSE_0_MAX >= IR_PAUSE_1_MIN
.error "Range overlap: IR_PAUSE_0_MAX >= IR_PAUSE_1_MIN."
.endif

; == Hardware definitions ==
; === CPU clock frequency ===
.equ F_CPU = 4_000_000 ; Hz

; === LED 7-segment display ===
; ==== Segments ====
.equ LED_S_DDR = DDRD
.equ LED_S_PORT = PORTD
.equ SEGM_A_bm = 1<<5
.equ SEGM_B_bm = 1<<3
.equ SEGM_C_bm = 1<<7
.equ SEGM_D_bm = 1<<4
.equ SEGM_E_bm = 1<<1
.equ SEGM_F_bm = 1<<2
.equ SEGM_G_bm = 1<<0
.equ DOT1_bm = 1<<0
.equ DOT2_bm = 1<<2
.equ DOT3_bm = 1<<1
.equ DOT4_bm = 1<<4
.equ DOT5_bm = 1<<3
.equ DOT6_bm = 1<<6
.equ DOT7_bm = 1<<5
.equ DOT8_bm = 1<<7

; ==== Common cathodes ====
.equ LED_C_DDR = DDRB
.equ LED_C_PORT = PORTB
.equ LED_C_DIGIT0_bm = 1<<0     ; rightmost (least significant) digit
.equ LED_C_DIGIT1_bm = 1<<1
.equ LED_C_DIGIT2_bm = 1<<2
.equ LED_C_DIGIT3_bm = 1<<3     ; leftmost (most significant) digit
.equ LED_C_DOTS_bm = 1<<4       ; dots on LED display

; === RELAY_bp ===
.equ RELAY_DDR = DDRC
.equ RELAY_PORT = PORTC
.equ RELAY_bp = PC4

; === IR receiver ===
.equ IRRX_IN = PINC
.equ IRRX_bp = PC5

; == Register definitions ==
; === General registers ===
.def zero  = r2
.def wri0 = r16
.def wri1 = r17
.def wri2 = r18

; === Clock registers ===
.def seconds = r19
.def minutes = r20
.def digit0 = r6            ; Contains 7-segment code of rightmost (least significant) digit.
.def digit1 = r7            ; These digit registers (digit0..3) and dots are directly applied to LED_S_PORT.
.def digit2 = r8
.def digit3 = r9            ; Contains 7-segment code of leftmost (most significant) digit.
.def dots = r10             ; Contains dots code.
.def timerState = r21
.def displayMode = r22

; === IR receiver registers ===
.def ir_status = r11

; == RAM usage ==
.dseg
.org SRAM_START
irRx_callCntrL_ds:      .byte 1
irRx_callCntrH_ds:      .byte 1
irRx_pulseCntr_ds:      .byte 1
irRx_mask_ds:           .byte 1
irRx_data_ds:           .byte IR_DATA_BYTE_CNT ; The received data (address and command).

; == EEPROM usage ==
.eseg
seconds_ee: .byte 1
minutes_ee: .byte 1

.cseg
.org 0
    rjmp    reset

.org OC2Aaddr          ; Timer2 Compare Match A
    rjmp    irRx       ; IR receiver

.org OC1Aaddr          ; Timer1 Compare Match A
    rjmp    secondsIsr ; seconds tick

.org OC0Aaddr          ; Timer0 Compare Match A
    rjmp    displayIsr ; LED display multiplexing

.org INT_VECTORS_SIZE

; === 7-Segment Code Table ===
sevenSegmentTable:
.db SEGM_A_bm | SEGM_B_bm | SEGM_C_bm | SEGM_D_bm | SEGM_E_bm | SEGM_F_bm, SEGM_B_bm | SEGM_C_bm ; 0, 1
.db SEGM_A_bm | SEGM_B_bm | SEGM_D_bm | SEGM_E_bm | SEGM_G_bm, SEGM_A_bm | SEGM_B_bm | SEGM_C_bm | SEGM_D_bm | SEGM_G_bm ; 2, 3
.db SEGM_B_bm | SEGM_C_bm | SEGM_F_bm | SEGM_G_bm, SEGM_A_bm | SEGM_C_bm | SEGM_D_bm | SEGM_F_bm | SEGM_G_bm ; 4, 5
.db SEGM_A_bm | SEGM_C_bm | SEGM_D_bm | SEGM_E_bm | SEGM_F_bm | SEGM_G_bm, SEGM_A_bm | SEGM_B_bm | SEGM_C_bm ; 6, 7
.db SEGM_A_bm | SEGM_B_bm | SEGM_C_bm | SEGM_D_bm | SEGM_E_bm | SEGM_F_bm | SEGM_G_bm, SEGM_A_bm | SEGM_B_bm | SEGM_C_bm | SEGM_D_bm | SEGM_F_bm | SEGM_G_bm ; 8, 9

; === Remote Control Table ===
; The address sent by the remote control:
.equ RC_ADDRESS = 0x00
; Total count of buttons (commands):
.equ RC_COMMANDS = 20

rcCmdIdTable:
.db 20, 20, 20, 20, 20, 20, 20, 15,  4, 17, 20, 20,  1, 19, 20, 20
.db 20, 20, 20, 20, 20, 16,  0, 20,  2, 18, 20, 20,  5, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 13, 20,  7, 14, 12, 10, 20, 11, 20, 20,  9, 20, 20, 20, 20, 20
.db 20, 20,  8, 20, 20, 20, 20, 20, 20, 20,  6, 20, 20, 20,  3, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20
.db 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20

; Buttons "0".."9" -> 0..9.
.equ RC_CMD_POWER = 10
.equ RC_CMD_MENU = 11
.equ RC_CMD_TEST = 12
.equ RC_CMD_PLUS = 13
.equ RC_CMD_BACK = 14
.equ RC_CMD_SKIP_LEFT = 15
.equ RC_CMD_PLAY = 16
.equ RC_CMD_SKIP_RIGHT = 17
.equ RC_CMD_MINUS = 18
.equ RC_CMD_CANCEL = 19

; === Register displayMode ===
; Bit positions of register displayMode:
.equ DISPLAY_MODE_TEST_bp = 0   ; PSU test (all display segments and dots driven; 0: normal, 1: test)

; === Register timerState ===
;   Value       Description
;       0       display shows remaining time
;       1       set tens of minutes
;       2       set units of minutes
;       3       set tens of seconds
;       4       set units of seconds

; === Convenience macros ===
.macro clearSecondsTick
    ldi     wri0, (1<<PSRSYNC)
    xout    GTCCR, wri0 ; Reset Timer0/1 prescaler.
    xout    TCNT1H, zero ; Clear Timer1 counter registers.
    xout    TCNT1L, zero
.endmacro

.macro startSecondsTick
    xin     wri0, TCCR1B
    ori     wri0, (1<<CS11) | (1<<CS10) ; prescaling 1/64
    xout    TCCR1B, wri0
.endmacro

.macro stopSecondsTick
    xin     wri0, TCCR1B
    andi    wri0, ~((1<<CS11) | (1<<CS10))
    xout    TCCR1B, wri0
.endmacro

reset:
; Initialize general registers:
    clr     zero
    clr     timerState
    clr     displayMode
; Initialize stack pointer:
    ldi     wri0, high(RAMEND)
    xout    SPH, wri0
    ldi     wri0, low(RAMEND)
    xout    SPL, wri0
; Initialize outputs:
    xin     wri0, RELAY_PORT
    andi    wri0, ~(1<<RELAY_bp)
    xout    RELAY_PORT, wri0
    xin     wri0, RELAY_DDR
    ori     wri0, (1<<RELAY_bp)
    xout    RELAY_DDR, wri0
; Initialize Timer0 (LED display multiplexing):
    ldi     wri0, 250-1 ; 50 Hz multiplex frequency
    xout    OCR0A, wri0
    ldi     wri0, (1<<WGM01) ; CTC mode
    xout    TCCR0A, wri0
    ldi     wri0, (1<<OCIE0A) ; enable compare match A interrupt
    xout    TIMSK0, wri0
; Initialize Timer1 (seconds tick):
    ldi     wri0, high(F_CPU/64-1) ; delay of 1s between compare matches
    xout    OCR1AH, wri0
    ldi     wri0, low(F_CPU/64-1)
    xout    OCR1AL, wri0
    ldi     wri0, (1<<WGM12) ; CTC mode
    xout    TCCR1B, wri0
    ldi     wri0, (1<<OCIE1A) ; enable compare match A interrupt
    xout    TIMSK1, wri0
; Initialize Timer2 (IR receiver):
    ldi     wri0, IR_TIMER_OCR
    xout    OCR2A, wri0
    ldi     wri0, (1<<WGM21) ; CTC mode
    xout    TCCR2A, wri0
    ldi     wri0, (1<<OCIE2A) ; enable compare match A interrupt
    xout    TIMSK2, wri0

; == Initialize IR receiver ==
    clr     ir_status
; Set IR_STATUS_PREV_bp bit (low-active):
    set
    bld     ir_status, IR_STATUS_PREV_bp
; Clear call and pulse counters:
    sts     irRx_callCntrL_ds, zero
    sts     irRx_callCntrH_ds, zero
    sts     irRx_pulseCntr_ds, zero

; == Initialize timer ==
    rcall   loadSavedTime

; == Enable interrupts ==
    sei

; == Start Timer0 and Timer2 ==
    ldi     wri0, (1<<CS01) | (1<<CS00) ; prescaling 1/64
    xout    TCCR0B, wri0
    ldi     wri0, (1<<CS20) ; no prescaling
    xout    TCCR2B, wri0

loop:
    sbrs    ir_status, IR_STATUS_DATA_bp
    rjmp    loop
; Valid IR data frame received.
    cli
; Check the RC address, ignore reception if it does not match:
    lds     wri0, irRx_data_ds
    cpi     wri0, RC_ADDRESS
    breq    loop_addrOK
    rjmp    loop_end
loop_addrOK:
; Copy the received command:
    lds     wri0, irRx_data_ds+2
; Convert command to ID:
    ldiz    2*rcCmdIdTable
    addz    wri0
    lpm     wri0, Z
; Check for TEST button:
    cpi     wri0, RC_CMD_TEST
    brne    loop_2
    ldi     wri0, 1<<DISPLAY_MODE_TEST_bp
    eor     displayMode, wri0 ; toggle DISPLAY_MODE_TEST_bp
    rjmp    loop_end
loop_2:
; Make sure timerState is in allowed range:
    cpi     timerState, 5 ; total count of states (highest state index +1)
    brlo    loop_3
; timerState is out of bounds.
; Get the timer into initial state:
    clr     timerState
    cbi     RELAY_PORT, RELAY_bp
    stopSecondsTick
    rcall   loadSavedTime
    rjmp    loop_end
loop_3:
; Branch according to timerState:
    ldiz    loop_jmpTbl
    addz    timerState
    ijmp
loop_jmpTbl:
    rjmp    loop_state0
    rjmp    loop_state1
    rjmp    loop_state2
    rjmp    loop_state3
    rjmp    loop_state4
loop_state0:
; Branch according to whether Timer1 is running or not:
    xin     wri1, TCCR1B
    sbrc    wri1, CS10
    rjmp    loop_state0_tr ; Timer1 is running.
; Timer1 is not running.
    cpi     wri0, RC_CMD_MENU
    brne    loop_state0_1
    rcall   timeSetup
    rjmp    loop_end
loop_state0_1:
    cpi     wri0, RC_CMD_PLUS
    brne    loop_state0_2
    sbi     RELAY_PORT, RELAY_bp
    rjmp    loop_end
loop_state0_2:
    cpi     wri0, RC_CMD_MINUS
    brne    loop_state0_3
    cbi     RELAY_PORT, RELAY_bp
    rjmp    loop_end
loop_state0_3:
    cpi     wri0, RC_CMD_PLAY
    brne    loop_state0_4
    sbi     RELAY_PORT, RELAY_bp
    clearSecondsTick
    startSecondsTick
    rjmp    loop_end
loop_state0_4:
    cpi     wri0, RC_CMD_BACK
    brne    loop_end
    rcall   loadSavedTime
    rjmp    loop_end
loop_state0_tr:
    cpi     wri0, RC_CMD_CANCEL
    brne    loop_end
    cbi     RELAY_PORT, RELAY_bp
    stopSecondsTick
    rjmp    loop_end
loop_state1:
    cpi     wri0, 10
    brsh    loop_state1_inv ; invalid command
; Button 0..9 was pressed.
    ldi     wri1, 10
    mul     wri0, wri1
    mov     minutes, r0
    rcall   to7segm
    mov     digit3, wri1
    inc     timerState
loop_state1_inv:
    rjmp    loop_end
loop_state2:
    cpi     wri0, 10
    brsh    loop_state2_inv ; invalid command
; Button 0..9 was pressed.
    add     minutes, wri0
    rcall   to7segm
    mov     digit2, wri1
    inc     timerState
loop_state2_inv:
    rjmp    loop_end
loop_state3:
    cpi     wri0, 6
    brsh    loop_state3_inv ; invalid command
; Button 0..5 was pressed.
    ldi     wri1, 10
    mul     wri0, wri1
    mov     seconds, r0
    rcall   to7segm
    mov     digit1, wri1
    inc     timerState
loop_state3_inv:
    rjmp    loop_end
loop_state4:
    cpi     wri0, 10
    brsh    loop_end ; invalid command
; Button 0..9 was pressed.
    add     seconds, wri0
    rcall   to7segm
    mov     digit0, wri1
; Store chosen time to EEPROM:
    rcall   storeTime
    clr     timerState
loop_end:
; Clear IR_STATUS_DATA_bp flag:
    mov     wri0, ir_status
    andi    wri0, ~(1<<IR_STATUS_DATA_bp)
    mov     ir_status, wri0
; Re-enable interrupts:
    sei
    rjmp    loop

; === Routine: start time setup ===
timeSetup:
    push    wri0
    ldi     timerState, 1
    clr     seconds
    clr     minutes
    ldi     wri0, 0b0000_0001 ; '-' (segment g)
    mov     digit0, wri0
    mov     digit1, wri0
    mov     digit2, wri0
    mov     digit3, wri0
    ldi     wri0, 0b0001_1000 ; ':' (dots D4, D5)
    mov     dots, wri0
    clt ; display leading zero
    pop     wri0
    ret

; === Routine: load saved time from EEPROM ===
; Interrupts must be globally disabled before calling this routine.
loadSavedTime:
    push    wri0
; Wait for completion of previous EEPROM write:
loadSavedTime_wait:
    sbic    EECR, EEPE
    rjmp    loadSavedTime_wait
; Set up address:
    ldi     wri0, seconds_ee
    xout    EEARL, wri0
; Start EEPROM read:
    sbi     EECR, EERE
    xin     seconds, EEDR
; Set up address:
    ldi     wri0, minutes_ee
    xout    EEARL, wri0
; Start EEPROM read:
    sbi     EECR, EERE
    xin     minutes, EEDR
; Display minutes:
    mov     wri0, minutes
    set ; suppress leading zero
    rcall   to7segm
    mov     digit3, wri2
    mov     digit2, wri1
; Display seconds:
    mov     wri0, seconds
    clt ; display leading zero
    rcall   to7segm
    mov     digit1, wri2
    mov     digit0, wri1
; Display colon separator:
    ldi     wri0, 0b0001_1000 ; ':'
    mov     dots, wri0
    pop     wri0
    ret

; === Routine: store time setting to EEPROM ===
; Interrupts must be globally disabled before calling this routine.
storeTime:
    push    wri0
; Wait for completion of previous EEPROM write:
storeTime_wait0:
    sbic    EECR, EEPE
    rjmp    storeTime_wait0
; Set up address:
    ldi     wri0, seconds_ee
    xout    EEARL, wri0
; Load data into EEPROM data register:
    xout    EEDR, seconds
; Start EEPROM write:
    sbi     EECR, EEMPE
    sbi     EECR, EEPE
; Wait for completion of previous EEPROM write:
storeTime_wait1:
    sbic    EECR, EEPE
    rjmp    storeTime_wait1
; Set up address:
    ldi     wri0, minutes_ee
    xout    EEARL, wri0
; Load data into EEPROM data register:
    xout    EEDR, minutes
; Start EEPROM write:
    sbi     EECR, EEMPE
    sbi     EECR, EEPE
    pop     wri0
    ret

; === Interrupt routine: display multiplex ===
displayIsr:
    push    wri0
    push    wri1
    xin     wri0, SREG
    push    wri0
    xin     wri0, LED_C_DDR
    xout    LED_C_DDR, zero
    andi    wri0, LED_C_DIGIT3_bm | LED_C_DIGIT2_bm | LED_C_DIGIT1_bm | LED_C_DIGIT0_bm | LED_C_DOTS_bm
    cpi     wri0, LED_C_DIGIT3_bm
    breq    displayIsr2
    cpi     wri0, LED_C_DIGIT2_bm
    breq    displayIsr1
    cpi     wri0, LED_C_DIGIT1_bm
    breq    displayIsr0
    cpi     wri0, LED_C_DIGIT0_bm
    breq    displayIsrD
; Drive DIGIT3
    mov     wri0, digit3
    sbrc    displayMode, DISPLAY_MODE_TEST_bp
    ldi     wri0, 0xFF
    xout    LED_S_PORT, wri0
    xout    LED_S_DDR, wri0
    ldi     wri0, LED_C_DIGIT3_bm
    xout    LED_C_DDR, wri0
    rjmp    displayIsrEnd
displayIsr2:
; drive DIGIT2
    mov     wri0, digit2
    sbrc    displayMode, DISPLAY_MODE_TEST_bp
    ldi     wri0, 0xFF
    xout    LED_S_PORT, wri0
    xout    LED_S_DDR, wri0
    ldi     wri0, LED_C_DIGIT2_bm
    xout    LED_C_DDR, wri0
    rjmp    displayIsrEnd
displayIsr1:
; drive DIGIT1
    mov     wri0, digit1
    sbrc    displayMode, DISPLAY_MODE_TEST_bp
    ldi     wri0, 0xFF
    xout    LED_S_PORT, wri0
    xout    LED_S_DDR, wri0
    ldi     wri0, LED_C_DIGIT1_bm
    xout    LED_C_DDR, wri0
    rjmp    displayIsrEnd
displayIsr0:
; drive DIGIT0
    mov     wri0, digit0
    sbrc    displayMode, DISPLAY_MODE_TEST_bp
    ldi     wri0, 0xFF
    xout    LED_S_PORT, wri0
    xout    LED_S_DDR, wri0
    ldi     wri0, LED_C_DIGIT0_bm
    xout    LED_C_DDR, wri0
    rjmp    displayIsrEnd
displayIsrD:
; drive DOTS
    mov     wri0, dots
    sbic    RELAY_PORT, RELAY_bp
    ori     wri0, DOT1_bm | DOT2_bm | DOT3_bm
    xin     wri1, TCCR1B
    sbrc    wri1, CS10
    ori     wri0, DOT7_bm | DOT8_bm
    sbrc    displayMode, DISPLAY_MODE_TEST_bp
    ldi     wri0, 0xFF
    xout    LED_S_PORT, wri0
    xout    LED_S_DDR, wri0
    ldi     wri0, LED_C_DOTS_bm
    xout    LED_C_DDR, wri0
displayIsrEnd:
    pop     wri0
    xout    SREG, wri0
    pop     wri1
    pop     wri0
    reti

; === Routine: convert register to 2-digits decimal 7-segment code ===
; Input:  wri0: Number to be converted, will be destroyed.
;               If T bit is set, the leading zero will be suppressed.
; Output: wri1: units in 7-segment code
;         wri2: tens in 7-segment code
to7segm:
    ldi     wri2, 0
to7segm_tens:
    subi    wri0, 10
    brcs    to7segm_units
    inc     wri2
    rjmp    to7segm_tens
to7segm_units:
; wri2 now contains the tens.
    subi    wri0, -10                       ; Add 10, because the previous loop subtracted 10 once too much.
; wri0 now contains the units, convert to 7-segment code:
    ldiz    2*sevenSegmentTable
    addz    wri0
    lpm     wri1, Z
    brtc    to7segm_convTens                ; Skip tens testing if T bit is cleared.
    tst     wri2
    breq    to7segm_end                     ; Skip converting if tens are zero.
to7segm_convTens:
; Convert the tens to 7-segment code:
    ldiz    2*sevenSegmentTable
    addz    wri2
    lpm     wri2, Z
to7segm_end:
    ret

; === Interrupt routine: seconds "tick" ===
secondsIsr:
    push    wri0
    push    wri1
    push    wri2
    xin     wri0, SREG
    push    wri0
    tst     minutes
    breq    secondsIsr_min0
    tst     seconds
    breq    secondsIsr_secUndfl
secondsIsr_decSec:
    dec     seconds
    rjmp    secondsIsr_convert
secondsIsr_min0:
    cpi     seconds, 1
    breq    secondsIsr_stop
    rjmp    secondsIsr_decSec
secondsIsr_secUndfl:
    dec     minutes
    ldi     seconds, 59
    rjmp    secondsIsr_convert
secondsIsr_stop:
    clr     seconds
    cbi     RELAY_PORT, RELAY_bp
    stopSecondsTick ; Stop Timer1 (seconds tick).
secondsIsr_convert:
; Convert minutes:
    mov     wri0, minutes
    set ; suppress leading zero
    rcall   to7segm
    mov     digit3, wri2
    mov     digit2, wri1
; Convert seconds:
    mov     wri0, seconds
    clt ; display leading zero
    rcall   to7segm
    mov     digit1, wri2
    mov     digit0, wri1
; Blink colon separator:
    ldi     wri0, 0b0001_1000
    eor     dots, wri0
; Restore SREG, wri2, wri1, wri0:
    pop     wri0
    xout    SREG, wri0
    pop     wri2
    pop     wri1
    pop     wri0
    reti

; == Interrupt routine: IR receiving ==
irRx:
; Save temporary registers and SREG:
    push    wri0
    push    wri1
    push    wri2
    push    ZL
    push    ZH
    xin     wri0, SREG
    push    wri0
; Increment interrupt counter, preventing overflow:
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
    subi    wri0, 0xFF
    sbci    wri1, 0xFF
    breq    irRx_noInc ; Maximum counter value reached.
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
    subi    wri0, low(-1)
    sbci    wri1, high(-1)
    sts     irRx_callCntrL_ds, wri0
    sts     irRx_callCntrH_ds, wri1
irRx_noInc:
; Detect whether IRRX value has changed:
    bst     ir_status, IR_STATUS_PREV_bp
    bld     wri0, IRRX_bp
    xin     wri1, IRRX_IN
    eor     wri0, wri1
    sbrs    wri0, IRRX_bp
    rjmp    irRx_end ; No change.
; IRRX has changed.
    bst     wri1, IRRX_bp ; Store current IR state into T flag.
    bld     ir_status, IR_STATUS_PREV_bp ; Update previous state.
    brts    irRx_risingEdge
    rjmp    irRx_fallingEdge
irRx_risingEdge:
; Rising edge.
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
    lds     wri2, irRx_pulseCntr_ds
    cpi     wri2, 1
    breq    irRx_1stRisingEdge
; Data or stop rising edge.
.if IR_DEBUG
    ldi     wri2, IR_PULSE_TOO_SHORT
.endif ; IR_DEBUG
    subi    wri0, low(IR_MIN_CALLS(IR_PULSE))
    sbci    wri1, high(IR_MIN_CALLS(IR_PULSE))
    brlo    irRx_discard                    ; Pulse was too short.
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
.if IR_DEBUG
    ldi     wri2, IR_PULSE_TOO_LONG
.endif ; IR_DEBUG
    subi    wri0, low(IR_MAX_CALLS(IR_PULSE)+1)
    sbci    wri1, high(IR_MAX_CALLS(IR_PULSE)+1)
    brsh    irRx_discard                    ; Pulse was too long.
; Data or stop pulse was within bounds.
; Stop pulse received?
    lds     wri0, irRx_pulseCntr_ds
    cpi     wri0, IR_PULSE_COUNT
    breq    irRx_eot                        ; Yes, end of transmission.
.if IR_RECOGNIZE_REPETITION
    cpi     wri0, IR_REPETITION_PAUSE_RECEIVED
    breq    irRx_repetition                 ; Repetition frame received.
.endif ; IR_RECOGNIZE_REPETITION
    rjmp    irRx_clrCallCntr
irRx_eot:
; Regular (non-repetition) frame received.
; If supported by chosen protocol, check integrity of address and command:
.if IR_DEBUG && (IR_PROTOCOL == IR_NEC || IR_PROTOCOL == IR_NEC_EXT)
    ldi     wri2, IR_DATA_INVALID
.endif
.if IR_PROTOCOL == IR_NEC
    lds     wri0, irRx_data_ds
    lds     wri1, irRx_data_ds+1
    com     wri1
    cp      wri0, wri1
    brne    irRx_discard
.endif
.if IR_PROTOCOL == IR_NEC || IR_PROTOCOL == IR_NEC_EXT
    lds     wri0, irRx_data_ds+2
    lds     wri1, irRx_data_ds+3
    com     wri1
    cp      wri0, wri1
    brne    irRx_discard
.endif
; Valid transmission received.
    mov     wri0, ir_status
    ori     wri0, (1<<IR_STATUS_DATA_bp)
    mov     ir_status, wri0
    rjmp    irRx_clrPulseCntr
.if IR_RECOGNIZE_REPETITION
irRx_repetition:
    mov     wri0, ir_status
    ori     wri0, (1<<IR_STATUS_REPETITION_bp)
    mov     ir_status, wri0
    rjmp    irRx_clrPulseCntr
.endif ; IR_RECOGNIZE_REPETITION
irRx_1stRisingEdge:
.if IR_DEBUG
    ldi     wri2, IR_PULSE_START_TOO_SHORT
.endif ; IR_DEBUG
    subi    wri0, low(IR_MIN_CALLS(IR_PULSE_START))
    sbci    wri1, high(IR_MIN_CALLS(IR_PULSE_START))
    brlo    irRx_discard                        ; Start pulse was too short.
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
.if IR_DEBUG
    ldi     wri2, IR_PULSE_START_TOO_LONG
.endif ; IR_DEBUG
    subi    wri0, low(IR_MAX_CALLS(IR_PULSE_START)+1)
    sbci    wri1, high(IR_MAX_CALLS(IR_PULSE_START)+1)
    brsh    irRx_discard                        ; Start pulse was too long.
; Start pulse was within bounds.
irRx_rjmpClrCallCntr:
    rjmp    irRx_clrCallCntr
irRx_discard:
.if IR_DEBUG
    sts     irRx_debugCode_ds, wri2
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
    sts     irRx_debugCallCntrL_ds, wri0
    sts     irRx_debugCallCntrH_ds, wri1
    lds     wri0, irRx_pulseCntr_ds
    sts     irRx_debugPulseCntr_ds, wri0
    mov     wri0, ir_status
    ori     wri0, (1<<IR_STATUS_DISCARDED_bp)
    mov     ir_status, wri0
    rjmp    irRx_clrPulseCntr
.endif ; IR_DEBUG
irRx_fallingEdge:
    lds     wri2, irRx_pulseCntr_ds
    inc     wri2
    sts     irRx_pulseCntr_ds, wri2
    cpi     wri2, 1
    breq    irRx_rjmpClrCallCntr                ; First falling edge, jump to end.
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
    cpi     wri2, 2
    breq    irRx_2ndFallingEdge                 ; Second falling edge (after start pause).
; Falling edge after data pause.
.if IR_DEBUG
    ldi     wri2, IR_PAUSE_TOO_SHORT
.endif ; IR_DEBUG
    subi    wri0, low(IR_MIN_CALLS(IR_PAUSE_0))
    sbci    wri1, high(IR_MIN_CALLS(IR_PAUSE_0))
    brlo    irRx_discard                        ; Pause was too short.
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
    subi    wri0, low(IR_MAX_CALLS(IR_PAUSE_0)+1)
    sbci    wri1, high(IR_MAX_CALLS(IR_PAUSE_0)+1)
    brlo    irRx_lsl                            ; '0' received, left-shift mask.
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
.if IR_DEBUG
    ldi     wri2, IR_PAUSE_BETWEEN_0_1
.endif ; IR_DEBUG
    subi    wri0, low(IR_MIN_CALLS(IR_PAUSE_1))
    sbci    wri1, high(IR_MIN_CALLS(IR_PAUSE_1))
    brlo    irRx_discard
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
    subi    wri0, low(IR_MAX_CALLS(IR_PAUSE_1)+1)
    sbci    wri1, high(IR_MAX_CALLS(IR_PAUSE_1)+1)
    brlo    irRx_setDataBit                     ; '1' received.
.if IR_DEBUG
    ldi     wri2, IR_PAUSE_TOO_LONG
.endif ; IR_DEBUG
    rjmp    irRx_discard                        ; Pause was too long.
irRx_2ndFallingEdge:
.if IR_DEBUG
    ldi     wri2, IR_PAUSE_START_TOO_SHORT
.endif ; IR_DEBUG
.if IR_RECOGNIZE_REPETITION
    subi    wri0, low(IR_MIN_CALLS(IR_PAUSE_START_REPETITION))
    sbci    wri1, high(IR_MIN_CALLS(IR_PAUSE_START_REPETITION))
    brlo    irRx_discard
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
    subi    wri0, low(IR_MAX_CALLS(IR_PAUSE_START_REPETITION)+1)
    sbci    wri1, high(IR_MAX_CALLS(IR_PAUSE_START_REPETITION)+1)
    brlo    irRx_afterRepPause
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
.if IR_DEBUG
    ldi     wri2, IR_PAUSE_START_BETWEEN_R_D
.endif ; IR_DEBUG
.endif ; IR_RECOGNIZE_REPETITION
    subi    wri0, low(IR_MIN_CALLS(IR_PAUSE_START_DATA))
    sbci    wri1, high(IR_MIN_CALLS(IR_PAUSE_START_DATA))
    brlo    irRx_discard
    lds     wri0, irRx_callCntrL_ds
    lds     wri1, irRx_callCntrH_ds
.if IR_DEBUG
    ldi     wri2, IR_PAUSE_START_TOO_LONG
.endif ; IR_DEBUG
    subi    wri0, low(IR_MAX_CALLS(IR_PAUSE_START_DATA)+1)
    sbci    wri1, high(IR_MAX_CALLS(IR_PAUSE_START_DATA)+1)
    brlo    irRx_spwb
    rjmp    irRx_discard
irRx_spwb:
; Start pause was within bounds.
; Clear the data buffer:
    clr     wri0
    ldiz    irRx_data_ds
irRx_clrDataLoop:
    st      Z+, zero
    inc     wri0
    cpi     wri0, IR_DATA_BYTE_CNT
    brlo    irRx_clrDataLoop
; Initialize the bit mask:
    ldi     wri0, 1
    sts     irRx_mask_ds, wri0
    rjmp    irRx_clrCallCntr
irRx_setDataBit:
; Get the current data bit index:
    lds     wri0, irRx_pulseCntr_ds
    subi    wri0, IR_DATA_START
; Determine the data byte index:
    lsr     wri0                            ; Divide ...
    lsr     wri0
    lsr     wri0                            ; ... by 8.
    cpi     wri0, IR_DATA_BYTE_CNT          ; Make sure that ...
    brsh    irRx_clrPulseCntr           ; ... data byte index is within bounds.
; Load the Z pointer with data byte address:
    ldiz    irRx_data_ds
    addz    wri0
; Load the data byte:
    ld      wri0, Z
; Set the bit in the data byte:
    lds     wri1, irRx_mask_ds
    or      wri0, wri1
; Write back:
    st      Z, wri0
;   rjmp    irRx_lsl
irRx_lsl:
; Prepare the bit mask for the next bit:
    lds     wri0, irRx_mask_ds
    lsl     wri0
    brcc    irRx_skipInc
    inc     wri0
irRx_skipInc:
    sts     irRx_mask_ds, wri0
    rjmp    irRx_clrCallCntr
.if IR_RECOGNIZE_REPETITION
irRx_afterRepPause:
    ldi     wri0, IR_REPETITION_PAUSE_RECEIVED
    sts     irRx_pulseCntr_ds, wri0
    rjmp    irRx_clrCallCntr
.endif ; IR_RECOGNIZE_REPETITION
irRx_clrPulseCntr:
    sts     irRx_pulseCntr_ds, zero
irRx_clrCallCntr:
    sts     irRx_callCntrL_ds, zero
    sts     irRx_callCntrH_ds, zero
; ### DEVICE-DEPENDENT ###
;.if DEVICE == ATMEGA88A && IR_TIMER_PRESC > 1
; Reset Timer2 prescaler, ATmega88A
;   ldi     wri0, 1<<PSRASY
;   xout    GTCCR, wri0
;.endif
; ### END OF DEVICE-DEPENDENT ###
irRx_end:
; Restore modified registers:
    pop     wri0
    xout    SREG, wri0
    pop     ZH
    pop     ZL
    pop     wri2
    pop     wri1
    pop     wri0
    reti
