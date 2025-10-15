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
if not exist "DomesdayDuplicator.sof" (
    echo ERROR: DomesdayDuplicator.sof not found
    echo Please run build.bat first
    exit /b 1
)

echo.
echo Resetting JTAG server to clear stale connections...
jtagconfig --stop >nul 2>&1
timeout /t 1 /nobreak >nul
echo.

echo [1/2] Converting .sof to .jic format...
quartus_cpf -c DomesdayDuplicator.cof

if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Conversion failed
    exit /b 1
)

REM Retry loop to handle intermittent USB-Blaster detection
set MAX_RETRIES=10
set RETRY_COUNT=0

:retry_flash_programming
set /a RETRY_COUNT+=1

if %RETRY_COUNT% GTR 1 (
    echo Attempt %RETRY_COUNT% of %MAX_RETRIES%...
    timeout /t 1 /nobreak >nul
)

echo [2/2] Programming flash memory...
echo This may take 1-2 minutes...
quartus_pgm -c USB-Blaster DomesdayDuplicator_write_jic.cdf

if %ERRORLEVEL% EQU 0 goto flash_programming_success

REM Check if we should retry
if %RETRY_COUNT% LSS %MAX_RETRIES% (
    echo.
    echo Flash programming attempt failed, retrying...
    goto retry_flash_programming
)

REM All retries exhausted
echo ERROR: Flash programming failed after %MAX_RETRIES% attempts
echo Try unplugging and replugging the USB cable
exit /b 1

:flash_programming_success

echo.
echo ========================================
echo FLASH PROGRAMMING SUCCESSFUL!
echo ========================================
echo.
echo Power cycle the DE0-Nano to load the new configuration.
echo.

exit /b 0

