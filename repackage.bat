@echo off
chcp 65001 > nul
title Open Design Windows ARM64 Repackager
echo ===================================================
echo   Open Design Windows ARM64 Repackager Launcher
echo ===================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\repackage.ps1"
if %errorlevel% neq 0 (
    echo.
    echo [错误] 打包脚本执行失败！
) else (
    echo.
    echo [成功] 打包脚本执行完毕！
)
echo.
pause
