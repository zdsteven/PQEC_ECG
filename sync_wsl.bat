@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: Sync Script - Copy sdk\software to WSL and build with zsh
:: ============================================================

set "SOURCE=E:\Loongson\ciciec2026_loongson_regional\sdk\software"
set "WSL_DISTRO=Ubuntu-22.04"
set "WSL_USER=sapient610"
set "WSL_PATH=/home/!WSL_USER!/loongson/sdk/software"
set "WSL_TARGET=\\wsl.localhost\!WSL_DISTRO!!WSL_PATH!"

:: Toolchain path in WSL
set "TOOLCHAIN_PATH=/home/sapient610/loongson/sdk/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin"

:: LA32RSOC_WINDOWS_HOME path in WSL (where to copy the files)
set "LA32RSOC_WINDOWS_HOME=/mnt/e/Loongson/ciciec2026_loongson_regional"

echo ============================================
echo Sync sdk\software to WSL and build...
echo Source: %SOURCE%
echo Target: %WSL_TARGET%
echo Toolchain: %TOOLCHAIN_PATH%
echo LA32RSOC_WINDOWS_HOME: %LA32RSOC_WINDOWS_HOME%
echo ============================================
echo.

:: Check if source exists
if not exist "%SOURCE%" (
    echo [ERROR] Source not found: %SOURCE%
    pause
    exit /b 1
)

:: ============================================================
:: Check if WSL is running, start if not
:: ============================================================
echo [INFO] Checking WSL status...

wsl -d %WSL_DISTRO% echo "WSL is running" 2>nul >nul
if errorlevel 1 (
    echo [WARNING] WSL is not running. Starting...
    wsl -d %WSL_DISTRO% -u %WSL_USER% echo "Starting WSL..." 2>nul
    if errorlevel 1 (
        wsl -d %WSL_DISTRO% 2>nul
        if errorlevel 1 (
            echo [ERROR] Failed to start WSL.
            pause
            exit /b 1
        )
    )
    echo [SUCCESS] WSL started.
    timeout /t 2 /nobreak >nul 2>nul
) else (
    echo [INFO] WSL is already running.
)

echo.

:: ============================================================
:: Prepare WSL target directory
:: ============================================================
echo [INFO] Preparing WSL target directory...
wsl -d %WSL_DISTRO% -u %WSL_USER% mkdir -p %WSL_PATH% 2>nul
timeout /t 1 /nobreak >nul 2>nul

:: ============================================================
:: Sync using robocopy
:: ============================================================
echo [INFO] Starting sync...
robocopy "%SOURCE%" "%WSL_TARGET%" /MIR /NJH /NJS /NDL /NC /NS /NP

if errorlevel 8 (
    echo [ERROR] Copy failed!
    pause
    exit /b 1
)

echo [SUCCESS] Sync completed.
echo.

:: ============================================================
:: Show sync result
:: ============================================================
echo [INFO] Files in WSL target directory:
wsl -d %WSL_DISTRO% -u %WSL_USER% ls -la %WSL_PATH% 2>nul

echo.
echo ============================================
echo Starting build in WSL with zsh...
echo ============================================
echo.

:: ============================================================
:: Run make clean and make in asm directory using zsh
:: ============================================================
set "ASM_PATH=/home/%WSL_USER%/loongson/sdk/software/examples/asm"

echo [INFO] Working directory: %ASM_PATH%
echo [INFO] Using shell: zsh

:: Check if Makefile exists
echo [INFO] Checking Makefile...
wsl -d %WSL_DISTRO% -u %WSL_USER% zsh -c "cd %ASM_PATH% && test -f Makefile && echo 'Makefile found' || echo 'Makefile not found!'"

echo.
echo [INFO] Running make clean...
wsl -d %WSL_DISTRO% -u %WSL_USER% zsh -c "cd %ASM_PATH% && make clean"
set MAKE_CLEAN_RESULT=%errorlevel%

if %MAKE_CLEAN_RESULT% equ 0 (
    echo [INFO] make clean completed successfully.
) else (
    echo [WARNING] make clean returned error %MAKE_CLEAN_RESULT%
)

echo.

:: ============================================================
:: Run make with toolchain path and LA32RSOC_WINDOWS_HOME set
:: ============================================================
echo [INFO] Running make with toolchain PATH...
echo [INFO] Toolchain: %TOOLCHAIN_PATH%
echo [INFO] LA32RSOC_WINDOWS_HOME: %LA32RSOC_WINDOWS_HOME%

wsl -d %WSL_DISTRO% -u %WSL_USER% zsh -c "export PATH=%TOOLCHAIN_PATH%:\$PATH && export LA32RSOC_WINDOWS_HOME=%LA32RSOC_WINDOWS_HOME% && cd %ASM_PATH% && make MATMUL_GROUP_NUM=5000 COPY_OUTPUT=0"
set MAKE_RESULT=%errorlevel%

if %MAKE_RESULT% neq 0 (
    echo.
    echo [ERROR] make failed with error %MAKE_RESULT%!
    pause
    exit /b 1
)

echo.
echo ============================================
echo [SUCCESS] Build completed!
echo ============================================

