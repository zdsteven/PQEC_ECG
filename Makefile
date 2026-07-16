# ============================================================
# Makefile - 同步脚本管理器 (PowerShell 兼容版)
# ============================================================

.PHONY: help gitlab wsl vivado check checks all clean status

help:
	powershell -Command "Write-Host '============================================'; Write-Host 'Available targets:'; Write-Host '  make gitlab    - Sync to GitLab repository'; Write-Host '  make wsl       - Sync to WSL and build'; Write-Host '  make vivado    - Generate Vivado bitstream'; Write-Host '  make check     - Run lint, DSP and timing checks'; Write-Host '  make checks    - Alias of make check'; Write-Host '  make all       - Run all tasks'; Write-Host '  make clean     - Clean build artifacts'; Write-Host '  make status    - Check script status'; Write-Host '  make help      - Show this help'; Write-Host '============================================'"

gitlab:
	powershell -Command "& '.\sync_gitlab.bat'"

wsl:
	powershell -Command "& '.\sync_wsl.bat'"

vivado:
	powershell -Command "& '.\sync_vivado.bat'"

check:
	powershell -Command "& '.\run_checks.bat'"

checks: check

all:
	powershell -Command "& '.\sync_gitlab.bat'; Write-Host ''; & '.\sync_wsl.bat'; Write-Host ''; & '.\sync_vivado.bat'; Write-Host ''; & '.\run_checks.bat'; Write-Host ''; Write-Host '============================================'; Write-Host 'All tasks completed!'; Write-Host '============================================'"

clean:
	powershell -Command "if (Test-Path 'sdk\software\examples\asm\obj') { Remove-Item -Recurse -Force 'sdk\software\examples\asm\obj' }"
	powershell -Command "if (Test-Path 'fpga\*.log') { Remove-Item -Force 'fpga\*.log' }"
	powershell -Command "if (Test-Path 'fpga\*.jou') { Remove-Item -Force 'fpga\*.jou' }"
	powershell -Command "if (Test-Path 'fpga\project\.lint') { Remove-Item -Recurse -Force 'fpga\project\.lint' }"
	@echo Clean completed!

status:
	powershell -Command "Write-Host '============================================'; Write-Host 'Script status:'; Write-Host '============================================'"
	powershell -Command "if (Test-Path 'sync_gitlab.bat') { Write-Host '[OK] sync_gitlab.bat' } else { Write-Host '[MISSING] sync_gitlab.bat' }"
	powershell -Command "if (Test-Path 'sync_wsl.bat') { Write-Host '[OK] sync_wsl.bat' } else { Write-Host '[MISSING] sync_wsl.bat' }"
	powershell -Command "if (Test-Path 'sync_vivado.bat') { Write-Host '[OK] sync_vivado.bat' } else { Write-Host '[MISSING] sync_vivado.bat' }"
	powershell -Command "if (Test-Path 'run_checks.bat') { Write-Host '[OK] run_checks.bat' } else { Write-Host '[MISSING] run_checks.bat' }"
	powershell -Command "if (Test-Path 'fpga\run_all.tcl') { Write-Host '[OK] fpga\run_all.tcl' } else { Write-Host '[MISSING] fpga\run_all.tcl' }"
	powershell -Command "if (Test-Path 'fpga\project\Loongson_Soc.xpr') { Write-Host '[OK] Vivado project exists' } else { Write-Host '[MISSING] Vivado project not found' }"
	powershell -Command "if (Test-Path 'rtl\soc_top.bit') { Write-Host '[OK] Bitstream exists at rtl\soc_top.bit' } else { Write-Host '[MISSING] Bitstream not found' }"
	powershell -Command "if (Test-Path 'fpga\project\dsp_utilization.rpt') { Write-Host '[OK] DSP report exists' } else { Write-Host '[MISSING] DSP report not found' }"
	powershell -Command "if (Test-Path 'fpga\project\Loongson_Soc.runs\impl_1\timing_summary.rpt') { Write-Host '[OK] Timing report exists' } else { Write-Host '[MISSING] Timing report not found' }"
