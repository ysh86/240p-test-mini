;
; FDS backend for 240p test suite (replaces mmc1.s)
;
; The cartridge bankswitch is emulated with the FDS BIOS: the
; switchable 16K bank lives in PRG RAM at $6000-$9FFF and switching
; banks loads the corresponding file from disk with LoadFiles
; ($E1F8).  The fixed bank lives at $A000-$DFFF.  CHR is RAM, as on
; the SGROM build.  Nametable arrangement does NOT stay at the BIOS
; reset default: the BIOS leaves $4025 = $2E (bit 3 set = vertical
; arrangement, i.e. "horizontal mirroring" in cartridge terms), but
; every mapper build of the suite selects vertical mirroring, so
; fds_boot writes the resting value with bit 3 cleared (see there).
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
.import unpb53_shadow_loop
.export rf_vwfClearPuts, rf_load_layout
.export rtl, mmc_bank_a, unpb53_shadow_batch
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
  ; Park the drive in its resting state and set the nametable
  ; arrangement, with the BIOS reset stub's own value: the stub
  ; writes $FA = $4025 = $2E before dispatching to the game on a
  ; warm reset; $26 is that value with bit 3 cleared (horizontal
  ; arrangement = "vertical mirroring"), which is what mmc1.s /
  ; mmc3.s select at init and what the suite's scroll tests are
  ; built for (SMB2 likewise clears bit 3 of the stub's value at
  ; its entry).  On the warm path this merely re-states the stub's
  ; state with bit 3 adjusted.  On the cold path it matters more:
  ; the bypass entry interrupts the boot mid-skip with the drive
  ; still streaming, and on Hara's FDSKey the first runtime load
  ; after such an entry never syncs (the disk spins forever),
  ; while every warm boot -- which passes through the stub's stop
  ; write and the firmware's rewind-to-zero reaction to it --
  ; works.  Writing the resting value here gives the cold entry
  ; the same drive state the stub gives a warm one.  This is a
  ; single state write at entry, not a stop/start cycle: the
  ; motor is started later by LoadFiles itself, exactly as after
  ; a warm reset.  LoadFiles derives its $4025 values from $FA
  ; with bit 3 included in its masks, so the arrangement setting
  ; survives every later disk call.
  lda #$26
  sta $FA
  sta $4025
  ; And no motor cycling anywhere.  Earlier builds cycled the
  ; motor (stop, ~0.2 s, start) at boot and before every LoadFiles
  ; attempt; those builds all failed their first runtime load on
  ; hardware (v5-v9), though in hindsight they also lacked the
  ; reserved-area hygiene, so the cycle was never cleanly
  ; isolated as the cause.  What is certain from the commercial
  ; reference: SMB2's only $4025 write is a single bit-3 mirror
  ; RMW at entry, the motor is otherwise left to the BIOS and the
  ; drive, and per-attempt drive manipulation has no commercial
  ; precedent; see SMB2-LOADER-ANALYSIS.md.
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
  bne @go
  rts
@go:
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
  ; applies): NMI off, VRAM increment +1.  $FF is the game's own
  ; PPUCTRL mirror, shared with the BIOS by design, so setting it
  ; here is the documented pre-LoadFiles protocol, not a repair.
  lda #$00
  sta $FF
  ; No mirror repairs here.  Earlier builds rewrote $FA ($4025
  ; shadow) and $F9 ($4026 mirror) per attempt because
  ; reset_handler's zero-page clear destroyed the values the BIOS
  ; reset seeded.  The reserved-area hygiene in init.s/fds.cfg
  ; (the game never writes $00-$0F or $F1-$FF at all) makes that
  ; unnecessary: BIOS state now survives from reset through the
  ; boot load into the game, as on a commercial FDS title, and
  ; LoadFiles maintains its own mirrors from there.
  jsr VINTWAIT  ; sync to vblank; applies $FF to $2000; leaves I set
  ; One-entry file list for the wanted bank's file ID.
  ldx bank_want
  lda bank_fileid,x
  sta filelist
  lda #$FF
  sta filelist+1
  ; Just call, the way the commercial reference does: no motor
  ; stop/start, no drive-state manipulation before the call
  ; (SMB2's loader reaches its JSR $E1F8 with nothing but the
  ; file-list pointer patched).  The BIOS scans forward from
  ; wherever the head is, exactly as it does for a commercial
  ; title whose disk has been spinning since boot.
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

; Batched gate for the drop shadow test's tile loop: upstream calls
; unpb53_gate once per 4-tile block (28 round trips for that test's
; entry), and each round trip here is two disk loads.  Worse, the
; loop's block counter lives at $02, inside the BIOS LoadFiles work
; area ($00-$0E), so with the real BIOS each load rewrites the
; counter and the loop cannot be trusted to terminate.  The FDS
; variant of the loop therefore runs entirely inside ONE gate
; session: switch to the data bank, decode/transform/copy all
; blocks (the loop in shadowsprite.s touches only PB53_outbuf and
; $2007 while gated), switch back once.
unpb53_shadow_batch:
  lda #GATE_DATA_BANK
  jsr mmc_bank_a
  jsr unpb53_shadow_loop
  jmp rtl

nmi_handler:
  inc nmis
irq_handler:
  rti

rf_vwfClearPuts = rf_vwfClearPuts_cb
