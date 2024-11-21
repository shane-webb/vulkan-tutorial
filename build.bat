@echo off

if not exist bin mkdir .\bin
if not exist src mkdir .\src

set "odin_args=%*"

if defined odin_args (
  if "%odin_args%"=="debug" (
    echo compiling shaders
    .\bin\glslc.exe shaders\shader.vert -o bin\vert.spv
    .\bin\glslc.exe shaders\shader.frag -o bin\frag.spv
    echo running odin run src -debug -out:bin/app.exe -pdb-name:/debug/app.pdb
    odin run src -debug -out:./bin/app.exe -pdb-name:./debug/app.pdb
  ) else (
    echo Invalid argument: %odin_args%
    echo Available arguments: [-debug, -o:size]
  )
) else (
  echo compiling shaders
    .\bin\glslc.exe shaders\shader.vert -o bin\vert.spv
    .\bin\glslc.exe shaders\shader.frag -o bin\frag.spv
  echo running app
  odin run src -out=bin/app.exe
)

