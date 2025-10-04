@echo off
REM Flash programming script for Domesday Duplicator
REM Programs the EPCS flash memory for permanent configuration

REM Change to the directory where this script is located
cd /d "%~dp0"

echo ========================================
echo Domesday Duplicator Flash Programmer
echo ========================================
echo Working directory: %CD%
echo.
echo WARNING: This will permanently program the
echo configuration flash memory on the DE0-Nano.
echo.
echo The configuration will persist across power cycles.
echo.

set /p confirm="Continue? (y/N): "
if /i not "%confirm%"=="y" (
    echo Cancelled.
    exit /b 0
)

REM Check if .sof file exists
if not exist "output_files\DomesdayDuplicator.sof" (
    echo ERROR: DomesdayDuplicator.sof not found
    echo Please run build.bat first
    exit /b 1
)

echo.
echo [1/2] Converting .sof to .jic format...
quartus_cpf -c DomesdayDuplicator.cof

if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Conversion failed
    exit /b 1
)

echo [2/2] Programming flash memory...
echo This may take 1-2 minutes...
quartus_pgm -c USB-Blaster DomesdayDuplicator_write_jic.cdf

if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Flash programming failed
    exit /b 1
)

echo.
echo ========================================
echo FLASH PROGRAMMING SUCCESSFUL!
echo ========================================
echo.
echo Power cycle the DE0-Nano to load the new configuration.
echo.

exit /b 0

