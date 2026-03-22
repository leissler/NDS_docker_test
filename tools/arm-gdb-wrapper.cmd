@echo off
setlocal EnableExtensions

set "GDB_BIN="

if defined NDS_GDB_BIN (
  if exist "%NDS_GDB_BIN%" (
    set "GDB_BIN=%NDS_GDB_BIN%"
  )
)

if not defined GDB_BIN (
  for %%I in (arm-none-eabi-gdb.exe gdb-multiarch.exe gdb.exe) do (
    for /f "delims=" %%P in ('where %%I 2^>nul') do (
      if not defined GDB_BIN set "GDB_BIN=%%P"
    )
  )
)

if not defined GDB_BIN (
  if exist "C:\Program Files\Arm GNU Toolchain\bin\arm-none-eabi-gdb.exe" (
    set "GDB_BIN=C:\Program Files\Arm GNU Toolchain\bin\arm-none-eabi-gdb.exe"
  )
)

if not defined GDB_BIN (
  if exist "C:\Program Files (x86)\Arm GNU Toolchain\bin\arm-none-eabi-gdb.exe" (
    set "GDB_BIN=C:\Program Files (x86)\Arm GNU Toolchain\bin\arm-none-eabi-gdb.exe"
  )
)

if not defined GDB_BIN (
  >&2 echo [nds-debug] Could not find an ARM GDB binary.
  >&2 echo [nds-debug] Install one of:
  >&2 echo   - Arm GNU Toolchain (arm-none-eabi-gdb.exe in PATH), or
  >&2 echo   - gdb-multiarch
  >&2 echo [nds-debug] Or set NDS_GDB_BIN to an explicit executable path.
  exit /b 127
)

set "GDB_EXTRA_ARGS="

if "%NDS_GDB_NO_INIT%"=="" (
  set "GDB_EXTRA_ARGS=%GDB_EXTRA_ARGS% -nx"
) else if not "%NDS_GDB_NO_INIT%"=="0" (
  set "GDB_EXTRA_ARGS=%GDB_EXTRA_ARGS% -nx"
)

if "%NDS_GDB_DISABLE_TRACE_STATUS_PACKET%"=="" (
  set "GDB_EXTRA_ARGS=%GDB_EXTRA_ARGS% -iex \"set remote trace-status-packet off\""
) else if not "%NDS_GDB_DISABLE_TRACE_STATUS_PACKET%"=="0" (
  set "GDB_EXTRA_ARGS=%GDB_EXTRA_ARGS% -iex \"set remote trace-status-packet off\""
)

call "%GDB_BIN%" %GDB_EXTRA_ARGS% %*
exit /b %ERRORLEVEL%
