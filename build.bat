@echo off
set PYTHON=python
set CA65=ca65
set LD65=ld65

echo Building NES ROM...
%PYTHON% tools\script_compiler.py scripts\game.script -o asm\generated_game.asm
if errorlevel 1 goto :error

if not exist build mkdir build

%CA65% asm\kernel.asm -o build\kernel.o
if errorlevel 1 goto :error

%CA65% asm\game_data.asm -o build\game_data.o
if errorlevel 1 goto :error

%CA65% asm\generated_game.asm -o build\generated_game.o
if errorlevel 1 goto :error

%LD65% build\kernel.o build\game_data.o build\generated_game.o -C nes_mmc1.cfg -o game.nes
if errorlevel 1 goto :error

echo Done! game.nes is ready to play.
goto :eof

:error
echo Build failed.
exit /b 1
