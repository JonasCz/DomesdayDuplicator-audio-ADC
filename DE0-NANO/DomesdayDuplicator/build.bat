@echo off
REM Build script for Domesday Duplicator FPGA
REM Requires Intel Quartus Prime Lite in PATH

REM Change to the directory where this script is located
cd /d "%~dp0"

echo ========================================
echo Domesday Duplicator FPGA Build Script
echo ========================================
echo Working directory: %CD%
echo.

REM Check if quartus_sh is in PATH
where quartus_sh >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: quartus_sh not found in PATH
    echo Please add Quartus bin directory to PATH, e.g.:
    echo set PATH=%%PATH%%;C:\intelFPGA_lite\23.1std\quartus\bin64
    exit /b 1
)

echo [1/4] Cleaning previous build...
if exist "output_files" rmdir /s /q output_files
if exist "db" rmdir /s /q db
if exist "incremental_db" rmdir /s /q incremental_db

echo [2/4] Running Analysis and Synthesis...
quartus_map --read_settings_files=on --write_settings_files=off DomesdayDuplicator -c DomesdayDuplicator
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Analysis and Synthesis failed
    exit /b 1
)

echo [3/4] Running Fitter (Place and Route)...
quartus_fit --read_settings_files=off --write_settings_files=off DomesdayDuplicator -c DomesdayDuplicator
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Fitter failed
    exit /b 1
)

echo [4/4] Running Assembler (Generate bitstream)...
quartus_asm --read_settings_files=off --write_settings_files=off DomesdayDuplicator -c DomesdayDuplicator
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Assembler failed
    exit /b 1
)

echo.
echo ========================================
echo BUILD SUCCESSFUL!
echo ========================================
echo Output file: output_files\DomesdayDuplicator.sof
echo.
echo To program the FPGA, run: program.bat
echo.

exit /b 0

