;
; FDS backend for 240p test suite (replaces mmc1.s)
;
; The cartridge bankswitch is emulated with the FDS BIOS: the
; switchable 16K bank lives in PRG RAM at $6000-$9FFF and switching
; banks loads the corresponding file from disk with LoadFiles
; ($E1F8).  The fixed bank lives at $A000-$DFFF.  CHR is RAM, as on
; the SGROM build, and nametable arrangement stays at the BIOS reset
; default ($4025 = $2E: vertical mirroring), as on the UNROM build.
;
; Exports the same contract as mmc1.s/mmc3.s so the shared code
; (assembled with USE_MMC=1) links unchanged.  Register contract of
; mmc_bank_a matches the MMC1 original: only A and flags are
; clobbered (X and Y are preserved here explicitly because the BIOS
; call does not guarantee them).
;

.import reset_handler
.importzp nmis
.import unpb53_some, unpb53_file_cb, load_sb53_file_cb, load_iu53_file_cb
.export unpb53_gate, unpb53_file, load_sb53_file, load_iu53_file
.import rf_vwfClearPuts_cb, rf_load_layout_cb
.export rf_vwfClearPuts, rf_load_layout
.export rtl, mmc_bank_a
.export fds_boot, nmi_handler, irq_handler

MAIN_CODE_BANK = $02
GATE_DATA_BANK = $01

LOADFILES = $E1F8
VINTWAIT  = $E1B2

.segment "BSS"
cur_bank:  .res 1  ; bank resident in the $6000 window ($FF = unknown)
bank_want: .res 1
load_tries: .res 1  ; LoadFiles attempts left (see mmc_bank_a)
filelist:  .res 2  ; LoadFiles ID list: {id, $FF}

.segment "RODATA"
; Bank number -> file ID on the disk image.
; (bank 2 doubles as a boot file, hence the low ID)
bank_fileid:
  .byte 4, 5, 1
; Disk ID for LoadFiles: all checks skipped ($FF) except side/disk 0,
; mirroring what the BIOS itself uses at boot time.
disk_id:
  .byte $FF, $FF, $FF, $FF, $FF, $FF, $00, $00, $FF, $FF

.code
; Entry: reached via the $DFF6 vector table -- as NMI #3 on the first
; vblank after the -BYPASS- boot file enables NMIs (which skips the
; BIOS approval check), or via the RESET slot on later warm resets.
;
; The entry is DIRECT in both cases.  An earlier version handed the
; cold entry back to the BIOS reset handler (jmp ($FFFC)) to reset
; the drive state first, following the asm6f FDS example; on the
; FDSKey that leg never returns (the reset handler's drive handling
; stalls against the firmware's post-abort state: one load sweep,
; black screen, reset-proof).  The stage diagnostics proved the game
; side works from the hijack as-is (VINTWait, runtime LoadFiles and
; NMI cadence all pass), so we enter directly and instead:
;  - arm the reset-dispatch flags here (the interrupted boot never
;    lets the BIOS set them, so without this a warm reset would try
;    to reload the disk from a held read position), and
;  - retry bank loads in mmc_bank_a (the first LoadFiles after an
;    entry can fail while the drive position settles).
fds_boot:
  sei
  lda #$00
  sta $2000  ; NMIs off while taking over
  lda #$C0
  sta $0101  ; disk state: game mode, IRQ to game vector.  The boot
             ; was interrupted mid-skip, which would otherwise leave
             ; this at its skip-phase value; DupliFDS's Start and
             ; the NSF streaming player both set $C0 here.
  lda #$35
  sta $0102  ; RESET flag: boot files have loaded
  lda #$AC
  sta $0103  ; RESET type: first boot
  ; Cycle the motor (stop, wait, start) like DupliFDS does before
  ; its disk work: after the hijack interrupted the boot mid-skip
  ; this leaves the drive in a known, freshly-rewound state
  ; before the game starts asking the BIOS for loads.
  lda #$2E  ; $4025: read mode, motor off
  sta $4025
  ldx #0
  ldy #0
@rewind_wait:
  dex
  bne @rewind_wait
  dey
  bne @rewind_wait  ; ~0.2 s for the motor to stop
  lda #$2D  ; $4025: read mode, motor on
  sta $4025
  ; The boot vector file pointed NMI #3 at this entry so the bypass
  ; could reach it.  Repoint all NMI slots at the real handler now.
  lda #<nmi_handler
  sta $DFF6
  sta $DFF8
  sta $DFFA
  lda #>nmi_handler
  sta $DFF7
  sta $DFF9
  sta $DFFB
  ; Bank 2 was loaded by the boot process (cold boot) or is still
  ; resident (soft reset); the BIOS never clears PRG RAM.
  lda #MAIN_CODE_BANK
  sta cur_bank
  jmp reset_handler

; Call gates (same shape as mmc1.s) ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
unpb53_gate:
  lda #GATE_DATA_BANK
  jsr mmc_bank_a
  jsr unpb53_some
rtl:
  lda #MAIN_CODE_BANK
  ; fall through to mmc_bank_a
mmc_bank_a:
  cmp cur_bank
  beq @done
  sta bank_want
  txa
  pha
  tya
  pha
  lda #16
  sta load_tries
@attempt:
  ; Prepare for a BIOS disk call (documented preconditions):
  ; silence the FDS timer IRQ, APU frame IRQ and DMC IRQ.
  sei
  lda #$00
  sta $4022
  lda #$40
  sta $4017
  lda #$00
  sta $4010
  ; PPUCTRL for the transfer (via the $FF mirror that VINTWait
  ; applies): NMI off, VRAM increment +1.  The mirror cannot be
  ; trusted to hold the program's value -- reset_handler clears the
  ; whole zero page, this program included, and it never maintains
  ; the BIOS mirrors -- so set it explicitly.
  lda #$00
  sta $FF
  jsr VINTWAIT  ; sync to vblank; applies $FF to $2000; leaves I set
  ; One-entry file list for the wanted bank's file ID.
  ldx bank_want
  lda bank_fileid,x
  sta filelist
  lda #$FF
  sta filelist+1
  cli  ; the BIOS transfer is IRQ-driven
  jsr LOADFILES
  .addr disk_id
  .addr filelist
  sei
  cmp #$00
  beq @loaded
  ; Load failed.  Real FDS software retries disk reads, so do the
  ; same (a transient failure right after the boot hijack or a
  ; warm-reset dispatch was seen on Hara's FDSKey).  Note what is
  ; NOT a failure: a successful LoadFiles routinely takes ~6 s,
  ; because the BIOS scans forward from the head's current
  ; position at the disk's serial rate and a target file behind
  ; the head costs a near-full side pass.  Measured under FCEUX
  ; with the real BIOS (2026-10-25): every runtime load returned
  ; A=0 on the first attempt; the ~380-frame spacing between
  ; loads during startup is scan time, not retries.  Bank
  ; switches therefore pause for seconds -- inherent to the
  ; medium.  On a genuine error, wait ~1 s and try again.
  dec load_tries
  beq @giveup
  ldx #60
@settle:
  lda #$00
  sta $FF
  jsr VINTWAIT
  dex
  bne @settle
  jmp @attempt
@loaded:
  lda bank_want
  sta cur_bank
  jmp @restore
@giveup:
  lda #$FF  ; window contents unknown; next request reloads it
  sta cur_bank
@restore:
  ; Restore the program's drawing-state PPUCTRL (NMI on, increment
  ; +1).  The cartridge backend never touches PPUCTRL, and this
  ; program draws with NMI on -- its vblank waits spin on the NMI
  ; counter -- so the transfer value must not leak to the caller.
  ldx #$80
  stx $FF
  stx $2000
@out:
  pla
  tay
  pla
  tax
@done:
  rts

load_sb53_file:
  jsr load_sb53_file_cb
  jmp rtl

load_iu53_file:
  jsr load_iu53_file_cb
  jmp rtl

unpb53_file:
  jsr unpb53_file_cb
  jmp rtl

rf_load_layout:
  pha
  lda #GATE_DATA_BANK
  jsr mmc_bank_a
  pla
  jsr rf_load_layout_cb
  jmp rtl

nmi_handler:
  inc nmis
irq_handler:
  rti

rf_vwfClearPuts = rf_vwfClearPuts_cb
