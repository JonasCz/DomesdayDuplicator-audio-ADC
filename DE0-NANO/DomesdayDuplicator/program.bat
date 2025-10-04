@echo off
REM Program script for Domesday Duplicator FPGA
REM Requires Intel Quartus Prime Lite and USB Blaster driver

REM Change to the directory where this script is located
cd /d "%~dp0"

echo ========================================
echo Domesday Duplicator FPGA Programmer
echo ========================================
echo Working directory: %CD%
echo.

REM Check if quartus_pgm is in PATH
where quartus_pgm >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: quartus_pgm not found in PATH
    echo Please add Quartus bin directory to PATH
    exit /b 1
)

REM Check if .sof file exists
if not exist "DomesdayDuplicator.sof" (
    echo ERROR: DomesdayDuplicator.sof not found
    echo Please run build.bat first
    exit /b 1
)

echo Detecting USB Blaster...
quartus_pgm -l
echo.

echo Programming FPGA (SRAM configuration - volatile)...
echo This will be lost on power cycle.
echo.
quartus_pgm -c USB-Blaster -m JTAG -o "p;DomesdayDuplicator.sof@1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: Programming failed
    echo.
    echo Troubleshooting:
    echo 1. Check USB Blaster is connected
    echo 2. Check DE0-Nano is powered on
    echo 3. Check USB Blaster driver is installed
    echo 4. Try running Quartus Programmer GUI
    exit /b 1
)

echo.
echo ========================================
echo PROGRAMMING SUCCESSFUL!
echo ========================================
echo.
echo The FPGA is now running with audio ADC support.
echo Note: This is volatile - will be lost on power cycle.
echo.
echo To make it permanent, use program_flash.bat instead.
echo.

exit /b 0

