PYTHON ?= python3
CA65 ?= ca65
LD65 ?= ld65

SCRIPT_IN := scripts/game.script
SCRIPT_OUT := asm/generated_game.asm

ASM_SRCS := asm/kernel.asm asm/game_data.asm $(SCRIPT_OUT)
OBJS := build/kernel.o build/game_data.o build/generated_game.o

all: game.nes

$(SCRIPT_OUT): $(SCRIPT_IN) tools/script_compiler.py
	$(PYTHON) tools/script_compiler.py $(SCRIPT_IN) -o $(SCRIPT_OUT)

build/kernel.o: asm/kernel.asm | build
	$(CA65) asm/kernel.asm -o $@

build/game_data.o: asm/game_data.asm | build
	$(CA65) asm/game_data.asm -o $@

build/generated_game.o: $(SCRIPT_OUT) | build
	$(CA65) $(SCRIPT_OUT) -o $@

build:
	mkdir -p build

game.nes: $(OBJS) nes_mmc1.cfg
	$(LD65) $(OBJS) -C nes_mmc1.cfg -o $@

clean:
	rm -rf build game.nes $(SCRIPT_OUT)

.PHONY: all clean
