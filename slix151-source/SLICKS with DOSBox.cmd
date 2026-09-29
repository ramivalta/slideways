@echo off

rem ** Start the game with DOSBox **

rem ** add DOSBox to path **
for /D %%f in ("%ProgramFiles(x86)%\dosbox*") do (
  echo DOSBox folder: %%f
  set dosboxpath=%%f
)

set PATH=%PATH%;%dosboxpath%

start dosbox slicks.exe -noconsole -exit

if errorlevel 1 pause