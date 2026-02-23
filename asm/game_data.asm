.setcpu "6502"

.segment "RODATA"
; Demo level metadata + tiny RLE blob placeholders
level0_rle:
.byte $10, $00, $10, $01, $00

music_table:
.byte $00

sfx_table:
.byte $00
