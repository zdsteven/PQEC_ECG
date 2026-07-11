@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: sync_vivado.bat - Generate bitstream using Vivado
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "FPGA_DIR=%SCRIPT_DIR%fpga"
set "PROJECT_DIR=%FPGA_DIR%\project"
set "BITSTREAM_SOURCE=%PROJECT_DIR%\Loongson_Soc.runs\impl_1\soc_top.bit"
set "BITSTREAM_TARGET=%SCRIPT_DIR%rtl\soc_top.bit"

echo ============================================
echo Generate bitstream using Vivado...
echo Script directory: %SCRIPT_DIR%
echo FPGA directory: %FPGA_DIR%
echo Bitstream source: %BITSTREAM_SOURCE%
echo Bitstream target: %BITSTREAM_TARGET%
echo ============================================
echo.

:: Check if Vivado is available
where vivado >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Vivado not found in PATH!
    echo [INFO] Please run: source /opt/Xilinx/Vivado/2019.2/settings64.sh
    echo [INFO] Or add Vivado to your PATH
    pause
    exit /b 1
)

:: Check if project exists
if not exist "%PROJECT_DIR%\Loongson_Soc.xpr" (
    echo [ERROR] Vivado project not found: %PROJECT_DIR%\Loongson_Soc.xpr
    echo [INFO] Please run create_project.tcl first
    pause
    exit /b 1
)

:: Check if run_all.tcl exists
if not exist "%FPGA_DIR%\run_all.tcl" (
    echo [ERROR] run_all.tcl not found: %FPGA_DIR%\run_all.tcl
    pause
    exit /b 1
)

:: Run complete flow: synth -> impl -> bitstream -> copy
echo [INFO] Running complete flow (synthesis + implementation + bitstream)...
cd /d "%FPGA_DIR%"
vivado -mode batch -source run_all.tcl -log vivado_run_all.log -journal vivado_run_all.jou

if errorlevel 1 (
    echo [ERROR] Vivado flow failed!
    echo [INFO] Check %FPGA_DIR%\vivado_run_all.log for details
    pause
    exit /b 1
)

:: Check if bitstream was generated and copied
if not exist "%BITSTREAM_TARGET%" (
    echo [WARNING] Bitstream not found at target: %BITSTREAM_TARGET%
    echo [INFO] Check if bitstream was generated correctly
    if exist "%BITSTREAM_SOURCE%" (
        echo [INFO] Bitstream exists at source, copying manually...
        copy "%BITSTREAM_SOURCE%" "%BITSTREAM_TARGET%"
    ) else (
        echo [ERROR] Bitstream not found at source either!
        pause
        exit /b 1
    )
)

echo.
echo ============================================
echo [SUCCESS] Bitstream generated and copied!
echo Source: %BITSTREAM_SOURCE%
echo Target: %BITSTREAM_TARGET%
echo ============================================
