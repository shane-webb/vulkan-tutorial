@echo off

if not exist bin mkdir .\bin
if not exist src mkdir .\src

set "odin_args=%*"

if defined odin_args (
  if "%odin_args%"=="debug" (
    echo odin run src -debug -out:bin/app.exe
    odin run src -debug -out:./bin/app.exe
  ) else (
    echo Invalid argument: %odin_args%
    echo Available arguments: [-debug, -o:size]
  )
) else (
  odin run src -out=bin/app.exe
)

