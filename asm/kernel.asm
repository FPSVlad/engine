; -----------------------------------------------------------------------------
; kernel.asm - Complete Game Creation Kit NES runtime kernel (MMC1 layout)
; -----------------------------------------------------------------------------
; Fixed bank ($C000-$FFFF) responsibilities:
;   - Reset/NMI/IRQ
;   - PPU synchronization and buffered updates
;   - OAM metasprite renderer (up to 24 hw sprites budget)
;   - Script bytecode interpreter
;   - Platformer physics and tile collision hooks
;   - Audio tick hooks
; -----------------------------------------------------------------------------

.setcpu "6502"

; iNES header (NROM-style declaration for emulator compatibility; mapper set by linker)
.segment "HEADER"
.byte "NES", $1A
.byte 2          ; 2x16KB PRG
.byte 1          ; 1x8KB CHR
.byte $10        ; mapper low nybble (MMC1)
.byte $00        ; mapper high nybble
.byte $00, $00, $00, $00, $00, $00, $00, $00

; -----------------------------------------------------------------------------
; Hardware registers
PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
OAMADDR   = $2003
OAMDATA   = $2004
PPUSCROLL = $2005
PPUADDR   = $2006
PPUDATA   = $2007
OAMDMA    = $4014
APUSTATUS = $4015
JOY1      = $4016
JOY2      = $4017

MMC1_CTRL = $8000
MMC1_CHR0 = $A000
MMC1_CHR1 = $C000
MMC1_PRG  = $E000

; -----------------------------------------------------------------------------
.segment "ZEROPAGE": zeropage
frame_counter:      .res 1
nmi_ready:          .res 1
scroll_x:           .res 1
scroll_y:           .res 1
scroll_flag:        .res 1
controller_cur:     .res 1
controller_prev:    .res 1
controller_press:   .res 1
sprite_count:       .res 1
vm_pc_lo:           .res 1
vm_pc_hi:           .res 1
vm_wait:            .res 1
player_x_lo:        .res 1
player_x_hi:        .res 1
player_y_lo:        .res 1
player_y_hi:        .res 1
player_vx:          .res 1
player_vy:          .res 1
gravity_8_8_lo:     .res 1
gravity_8_8_hi:     .res 1
tmp0:               .res 1
tmp1:               .res 1
tmp2:               .res 1

.segment "BSS"
oam_shadow:         .res 256
nt_update_buffer:   .res 128

.segment "RODATA"
; Bytecode opcodes emitted by script compiler
OP_END          = $00
OP_PLAYER_SPAWN = $01
OP_IF_START_GOTO= $02
OP_SOUND_PLAY   = $03
OP_WAIT_FRAMES  = $04
OP_PLAY_MUSIC   = $05
OP_LOAD_LEVEL   = $06

; -----------------------------------------------------------------------------
.segment "CODE"

.proc reset
    sei                     ; block IRQ while hardware and RAM are uninitialized
    cld                     ; ensure decimal mode off for predictable ADC/SBC
    ldx #$40
    stx JOY2                ; disable APU frame IRQ
    ldx #$FF
    txs                     ; stack at top of page $01
    inx                     ; X=0

    stx PPUCTRL             ; disable NMI while configuring
    stx PPUMASK             ; rendering off
    stx APUSTATUS           ; silence channels during boot

    ; Wait for first vblank edge (PPU warmup)
:   bit PPUSTATUS
    bpl :-

    jsr clear_ram
    jsr init_mmc1
    jsr init_game_state

    ; Wait second vblank edge before touching palette/nametable
:   bit PPUSTATUS
    bpl :-

    jsr load_palettes
    jsr load_level_0

    lda #%10010000          ; enable NMI, BG pattern table $0000, sprites $1000
    sta PPUCTRL
    lda #%00011110          ; show BG + sprites, no grayscale
    sta PPUMASK

forever:
    lda nmi_ready           ; main thread sleeps until NMI tick finished
    beq forever
    lda #$00
    sta nmi_ready

    jsr poll_controller
    jsr run_script_vm
    jsr physics_step
    jsr build_player_metasprite
    jmp forever
.endproc

.proc nmi
    pha                     ; preserve A first: NMI can occur anytime
    txa
    pha                     ; preserve X
    tya
    pha                     ; preserve Y

    inc frame_counter       ; global 60Hz tick used by scripts/audio

    lda #$00
    sta OAMADDR             ; DMA always starts from OAM index 0
    lda #>oam_shadow
    sta OAMDMA              ; copy 256 bytes from CPU page to PPU OAM

    bit scroll_flag         ; if bit7 set, scroll values have changed
    bpl :+
    lda scroll_x
    sta PPUSCROLL
    lda scroll_y
    sta PPUSCROLL
    lda #$00
    sta scroll_flag         ; acknowledge scroll commit
:

    jsr animate_tiles_nmi   ; tiny tile animation state machine
    jsr audio_tick_nmi      ; updates registers with music/sfx state

    lda #$01
    sta nmi_ready           ; wake main loop

    pla
    tay
    pla
    tax
    pla
    rti
.endproc

.proc irq
    rti                     ; no mapper IRQ handling in this starter kernel
.endproc

.proc clear_ram
    lda #$00
    tay
@loop:
    sta $0000,y
    sta $0100,y
    sta $0200,y
    sta $0300,y
    sta $0400,y
    sta $0500,y
    sta $0600,y
    sta $0700,y
    iny
    bne @loop
    rts
.endproc

.proc init_mmc1
    ; Reset MMC1 shift register then set 16KB PRG fixed high bank mode
    lda #$80
    sta MMC1_CTRL
    lda #%00011100
    sta MMC1_CTRL
    lda #%00000000
    sta MMC1_CHR0
    sta MMC1_CHR1
    lda #%00000000
    sta MMC1_PRG
    rts
.endproc

.proc init_game_state
    lda #$00
    sta frame_counter
    sta nmi_ready
    sta scroll_x
    sta scroll_y
    sta scroll_flag
    sta controller_cur
    sta controller_prev
    sta controller_press
    sta sprite_count
    sta vm_wait

    lda #<script_start
    sta vm_pc_lo
    lda #>script_start
    sta vm_pc_hi

    lda #$80                ; 0.5 in 8.8 fixed = $0080
    sta gravity_8_8_lo
    lda #$00
    sta gravity_8_8_hi
    rts
.endproc

.proc poll_controller
    lda controller_cur
    sta controller_prev

    lda #$01
    sta JOY1
    lda #$00
    sta JOY1

    ldx #$08
    lda #$00
@read_bits:
    pha
    lda JOY1
    and #$01
    sta tmp0
    pla
    asl                     ; shift previous bits left
    ora tmp0
    dex
    bne @read_bits
    sta controller_cur

    lda controller_cur
    eor controller_prev
    and controller_cur
    sta controller_press
    rts
.endproc

.proc run_script_vm
    lda vm_wait
    beq @execute
    dec vm_wait
    rts

@execute:
    ldy #$00
    lda (vm_pc_lo),y
    tax
    inc vm_pc_lo
    bne :+
    inc vm_pc_hi
:
    cpx #OP_END
    beq @end
    cpx #OP_PLAYER_SPAWN
    beq @op_spawn
    cpx #OP_IF_START_GOTO
    beq @op_if_start
    cpx #OP_SOUND_PLAY
    beq @op_sound
    cpx #OP_WAIT_FRAMES
    beq @op_wait
    cpx #OP_PLAY_MUSIC
    beq @op_music
    cpx #OP_LOAD_LEVEL
    beq @op_load_level
    rts

@op_spawn:
    jsr vm_read_byte
    sta player_x_lo
    lda #$00
    sta player_x_hi
    jsr vm_read_byte
    sta player_y_lo
    lda #$00
    sta player_y_hi
    rts

@op_if_start:
    jsr vm_read_word        ; read absolute destination in script bank
    sta tmp0
    stx tmp1
    lda controller_press
    and #%00010000          ; START edge
    beq :+
    lda tmp0
    sta vm_pc_lo
    lda tmp1
    sta vm_pc_hi
:
    rts

@op_sound:
    jsr vm_read_byte        ; sound id in A
    jsr sound_play_sfx
    rts

@op_wait:
    jsr vm_read_byte
    sta vm_wait
    rts

@op_music:
    jsr vm_read_byte
    jsr audio_play_music
    rts

@op_load_level:
    jsr vm_read_byte
    tax
    jsr load_level_by_id
    rts

@end:
    ; Loop script forever for demo
    lda #<script_start
    sta vm_pc_lo
    lda #>script_start
    sta vm_pc_hi
    rts
.endproc

.proc vm_read_byte
    ldy #$00
    lda (vm_pc_lo),y
    inc vm_pc_lo
    bne :+
    inc vm_pc_hi
:
    rts
.endproc

.proc vm_read_word
    jsr vm_read_byte
    tax
    jsr vm_read_byte
    ; return lo in A, hi in X for convenience
    pha
    txa
    tax
    pla
    rts
.endproc

.proc physics_step
    ; vy += gravity (8.8 fixed point, low byte only for compact demo)
    lda player_vy
    clc
    adc gravity_8_8_lo
    sta player_vy

    ; y += vy >> 4 (coarse subpixel conversion)
    lda player_y_lo
    clc
    adc player_vy
    sta player_y_lo

    ; Ground collision at tile row boundary using tile attribute table
    jsr check_collision_player
    bcc :+
    lda #$00
    sta player_vy
:
    rts
.endproc

.proc check_collision_player
    ; Convert player position to tile coordinates (x>>4, y>>4) then query map
    lda player_x_lo
    lsr
    lsr
    lsr
    lsr
    sta tmp0                ; tile x

    lda player_y_lo
    lsr
    lsr
    lsr
    lsr
    sta tmp1                ; tile y

    jsr map_get_tile_attr   ; returns attr in A, carry set if solid
    cmp #$01
    bne :+
    sec
    rts
:
    clc
    rts
.endproc

.proc map_get_tile_attr
    ; Tiny demo map: treat bottom rows as solid, spikes tile id 2, water id 3 hooks
    lda tmp1
    cmp #$0D
    bcc :+
    lda #$01
    rts
:
    lda #$00
    rts
.endproc

.proc build_player_metasprite
    ; Build a 16x16 metasprite from 4 hw sprites in oam_shadow.
    ; Supports automatic hide when off-screen by placing Y=$F8.
    lda player_x_lo
    cmp #$F0
    bcs @hide
    lda player_y_lo
    cmp #$EF
    bcs @hide

    ; sprite 0
    lda player_y_lo
    sta oam_shadow+0
    lda #$20
    sta oam_shadow+1
    lda #$00
    sta oam_shadow+2
    lda player_x_lo
    sta oam_shadow+3

    ; sprite 1
    lda player_y_lo
    sta oam_shadow+4
    lda #$21
    sta oam_shadow+5
    lda #$00
    sta oam_shadow+6
    lda player_x_lo
    clc
    adc #$08
    sta oam_shadow+7

    ; sprite 2
    lda player_y_lo
    clc
    adc #$08
    sta oam_shadow+8
    lda #$30
    sta oam_shadow+9
    lda #$00
    sta oam_shadow+10
    lda player_x_lo
    sta oam_shadow+11

    ; sprite 3
    lda player_y_lo
    clc
    adc #$08
    sta oam_shadow+12
    lda #$31
    sta oam_shadow+13
    lda #$00
    sta oam_shadow+14
    lda player_x_lo
    clc
    adc #$08
    sta oam_shadow+15

    lda #$04
    sta sprite_count
    rts

@hide:
    lda #$F8
    ldx #$00
@hide_loop:
    sta oam_shadow,x
    inx
    inx
    inx
    inx
    cpx #$60                ; hide up to 24 hw sprites (24*4 bytes)
    bne @hide_loop
    lda #$00
    sta sprite_count
    rts
.endproc

.proc animate_tiles_nmi
    ; Example animated water tile: flips between tile IDs each 8 frames.
    lda frame_counter
    and #%00000111
    bne :+
    ; Would push buffered PPU writes here in production.
:
    rts
.endproc

.proc audio_tick_nmi
    ; Placeholder lightweight driver tick (2 pulse + tri + noise hooks)
    rts
.endproc

.proc audio_play_music
    ; A = music id. In a full driver we'd initialize per-channel sequences.
    rts
.endproc

.proc sound_play_sfx
    ; A = sfx id. Reserve noise channel for one-shot effects.
    rts
.endproc

.proc load_palettes
    lda PPUSTATUS
    lda #$3F
    sta PPUADDR
    lda #$00
    sta PPUADDR

    ldx #$00
@loop:
    lda default_palette,x
    sta PPUDATA
    inx
    cpx #$20
    bne @loop
    rts
.endproc

.proc load_level_by_id
    cpx #$00
    beq load_level_0
    rts
.endproc

.proc load_level_0
    ; Stub RLE decode callpoint for level background+collision planes.
    jsr decode_rle_to_nametable
    rts
.endproc

.proc decode_rle_to_nametable
    ; Minimal decoder placeholder (actual encoded map in game_data.asm)
    rts
.endproc

.segment "RODATA"
default_palette:
.byte $0F,$21,$11,$01,$0F,$27,$17,$07,$0F,$30,$21,$12,$0F,$16,$27,$38
.byte $0F,$21,$11,$01,$0F,$06,$16,$26,$0F,$30,$21,$12,$0F,$00,$10,$20

.import script_start

.segment "VECTORS"
.word nmi
.word reset
.word irq
