# ============================================================
# Makefile - 同步脚本管理器
# ============================================================

.PHONY: help gitlab wsl all

help:
	@echo ============================================
	@echo Available targets:
	@echo   make gitlab  - Sync to GitLab repository
	@echo   make wsl     - Sync to WSL and build
	@echo   make all     - Run both gitlab and wsl
	@echo   make help    - Show this help
	@echo ============================================

gitlab:
	powershell -Command ".\sync_gitlab.bat"

wsl:
	powershell -Command ".\sync_wsl.bat"

all: gitlab wsl
	@echo Both sync tasks completed!