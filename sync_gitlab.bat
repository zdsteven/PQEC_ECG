@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: Sync Script - Incremental sync and push to Git
:: ============================================================

set "SOURCE=%~dp0"
if "%SOURCE:~-1%"=="\" set "SOURCE=%SOURCE:~0,-1%"

set "TARGET=E:\Loongson\regional-submission-CICC1000627Rg"
set "BRANCH=dev/matmul"

echo ============================================
echo Incremental sync to target repository...
echo Source: %SOURCE%
echo Target: %TARGET%
echo Branch: %BRANCH%
echo ============================================
echo.

if not exist "%TARGET%\.git" (
    echo [ERROR] Target repository not found: %TARGET%
    pause
    exit /b 1
)

cd /d "%TARGET%" || (
    echo [ERROR] Cannot change to target directory: %TARGET%
    pause
    exit /b 1
)

echo [INFO] Pulling latest code...
git pull origin %BRANCH% --no-rebase 2>nul
if errorlevel 1 (
    echo [WARNING] git pull failed, continuing...
)
echo.

:: ============================================================
:: Use robocopy for incremental sync
:: ============================================================
echo [INFO] Starting incremental sync...

if exist "%SOURCE%\rtl" (
    echo Syncing: rtl
    robocopy "%SOURCE%\rtl" "%TARGET%\rtl" /MIR /NJH /NJS /NDL /NC /NS /NP
) else (
    echo [WARNING] Source not found: %SOURCE%\rtl
)

if exist "%SOURCE%\sdk\software\bsp" (
    echo Syncing: sdk\software\bsp
    robocopy "%SOURCE%\sdk\software\bsp" "%TARGET%\sdk\software\bsp" /MIR /NJH /NJS /NDL /NC /NS /NP
) else (
    echo [WARNING] Source not found: %SOURCE%\sdk\software\bsp
)

if exist "%SOURCE%\sdk\software\examples\asm" (
    echo Syncing: sdk\software\examples\asm
    robocopy "%SOURCE%\sdk\software\examples\asm" "%TARGET%\sdk\software\examples\asm" /MIR /NJH /NJS /NDL /NC /NS /NP
) else (
    echo [WARNING] Source not found: %SOURCE%\sdk\software\examples\asm
)

echo.
echo [INFO] Sync completed, checking changes...

git status --porcelain | findstr . >nul
if errorlevel 1 (
    echo [INFO] No changes detected, skip commit.
    goto :end
)

echo [INFO] Adding changes to stage...
git add -A

echo.
echo ============================================
echo Changes summary:
git status --short
echo ============================================
echo.

echo Enter commit message (press Enter for default):
set /p COMMIT_MSG="> "
echo.

if "!COMMIT_MSG!"=="" (
    set "COMMIT_MSG=Sync rtl, bsp, asm from source"
)

echo [INFO] Committing...
echo Commit message: !COMMIT_MSG!
git commit -m "!COMMIT_MSG!"
if errorlevel 1 (
    echo [ERROR] Commit failed!
    pause
    exit /b 1
)

echo.
echo [INFO] Pushing to branch %BRANCH%...
git push origin %BRANCH%
if errorlevel 1 (
    echo [ERROR] Push failed! Please check network or permissions.
    pause
    exit /b 1
)

echo.
echo ============================================
echo [SUCCESS] Sync completed!
echo Pushed to: %BRANCH%
echo Commit message: !COMMIT_MSG!
echo ============================================

:end
echo.
