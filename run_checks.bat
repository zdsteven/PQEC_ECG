@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: run_checks.bat - Run HDL lint, DSP and timing checks
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "FPGA_DIR=%SCRIPT_DIR%fpga"
set "PROJECT_DIR=%FPGA_DIR%\project"
set "PROJECT_XPR=%PROJECT_DIR%\Loongson_Soc.xpr"
set "PYTHON_EXE=%SCRIPT_DIR%.venv\Scripts\python.exe"
set "DSP_REPORT=%PROJECT_DIR%\dsp_utilization.rpt"
set "TIMING_REPORT=%PROJECT_DIR%\Loongson_Soc.runs\impl_1\timing_summary.rpt"
set "DSP_MAX=0"

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
:: Step 1: Run HDL linter
:: ============================================================
echo.
echo ============================================
echo Step 1: Running HDL linter...
echo ============================================

if not exist "%PROJECT_XPR%" (
    echo [ERROR] Vivado project not found: %PROJECT_XPR%
    exit /b 1
)

"%PYTHON_EXE%" "%FPGA_DIR%\run-linter.py" "%PROJECT_XPR%"
if errorlevel 1 (
    echo [ERROR] HDL lint check failed!
    exit /b 1
)
echo [SUCCESS] HDL lint check passed.

:: ============================================================
:: Step 2: Run DSP utilization check
:: ============================================================
echo.
echo ============================================
echo Step 2: Running DSP utilization check...
echo ============================================

cd /d "%FPGA_DIR%"

if not exist "%DSP_REPORT%" (
    echo [ERROR] DSP report not found: %DSP_REPORT%
    echo [INFO] Run make vivado first to generate current implementation reports.
    exit /b 1
) else (
    "%PYTHON_EXE%" check_dsp.py "%DSP_REPORT%" %DSP_MAX%
    if errorlevel 1 (
        echo [ERROR] DSP utilization check failed!
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
    echo [ERROR] Timing report not found: %TIMING_REPORT%
    echo [INFO] Run make vivado first to generate current implementation reports.
    exit /b 1
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
