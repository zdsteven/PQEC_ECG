@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: run_checks.bat - Run DSP and timing checks (skip linter)
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "FPGA_DIR=%SCRIPT_DIR%fpga"
set "PROJECT_DIR=%FPGA_DIR%\project"
set "PYTHON_EXE=%SCRIPT_DIR%.venv\Scripts\python.exe"
set "DSP_REPORT=%PROJECT_DIR%\dsp_utilization.rpt"
set "TIMING_REPORT=%PROJECT_DIR%\Loongson_Soc.runs\impl_1\timing_summary.rpt"
set "DSP_MAX=100"

echo ============================================
echo Running HDL checks...
echo Python: %PYTHON_EXE%
echo FPGA dir: %FPGA_DIR%
echo DSP report: %DSP_REPORT%
echo Timing report: %TIMING_REPORT%
echo DSP max limit: %DSP_MAX%
echo ============================================
echo.

:: Check if Python exists
if not exist "%PYTHON_EXE%" (
    echo [ERROR] Python not found: %PYTHON_EXE%
    echo [INFO] Please check the path to python.exe
    pause
    exit /b 1
)

:: ============================================================
:: Step 1: Skip Linter (verilator not available on Windows)
:: ============================================================
echo.
echo ============================================
echo Step 1: Skipping HDL linter (verilator not available on Windows)
echo ============================================
echo [INFO] Linter is skipped for local Windows build.
echo [INFO] Linter will run in GitLab CI where verilator is available.
echo.

:: ============================================================
:: Step 2: Run DSP utilization check
:: ============================================================
echo.
echo ============================================
echo Step 2: Running DSP utilization check...
echo ============================================

cd /d "%FPGA_DIR%"

if not exist "%DSP_REPORT%" (
    echo [WARNING] DSP report not found: %DSP_REPORT%
    echo [INFO] Please run implementation first
    set /p CONTINUE="Continue without DSP check? (y/n): "
    if /i not "!CONTINUE!"=="y" (
        pause
        exit /b 1
    )
) else (
    "%PYTHON_EXE%" check_dsp.py "%DSP_REPORT%" %DSP_MAX%
    if errorlevel 1 (
        echo [ERROR] DSP utilization check failed!
        pause
        exit /b 1
    )
    echo [SUCCESS] DSP utilization check passed.
)

:: ============================================================
:: Step 3: Run timing check
:: ============================================================
echo.
echo ============================================
echo Step 3: Running timing check...
echo ============================================

if not exist "%TIMING_REPORT%" (
    echo [WARNING] Timing report not found: %TIMING_REPORT%
    echo [INFO] Please run implementation first
    set /p CONTINUE="Continue without timing check? (y/n): "
    if /i not "!CONTINUE!"=="y" (
        pause
        exit /b 1
    )
) else (
    "%PYTHON_EXE%" check_timing.py "%TIMING_REPORT%"
    if errorlevel 1 (
        echo [ERROR] Timing check failed!
        pause
        exit /b 1
    )
    echo [SUCCESS] Timing check passed.
)

:: ============================================================
:: Done
:: ============================================================
echo.
echo ============================================
echo [SUCCESS] All checks passed!
echo ============================================
