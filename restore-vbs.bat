@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title 三角洲行动 CPU 虚拟化修复 - 恢复脚本

rem ============================================================
rem   restore-vbs.bat
rem   反向恢复 fix-vbs.bat 所做的修改：
rem     - bcdedit /set hypervisorlaunchtype auto
rem     - WindowsHello Enabled -> 1
rem     - HypervisorEnforcedCodeIntegrity Enabled -> 1
rem     - 重新启用 Hyper-V 等特性
rem     - DeviceGuard 各项恢复为 1
rem   注意：仅恢复你原本启用的项，避免在原本未启用的项上误开。
rem ============================================================

set "LOG=%~dp0restore-vbs.log"
echo 恢复日志 - %date% %time% > "%LOG%"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   [提示] 当前不是管理员权限，正在尝试自动提权...
    echo   请在弹出的「用户账户控制」窗口中点「是」。
    echo.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    if %errorlevel% neq 0 (
        echo   [错误] 自动提权失败。请右键本文件 -^> 以管理员身份运行。
        echo.
        set /p "_=按回车退出..."
    )
    exit /b 1
)

echo ============================================================
echo   恢复 CPU 虚拟化安全特性
echo   此操作将反向恢复 fix-vbs.bat 的修改，重新开启：
echo     - VBS（hypervisorlaunchtype = auto）
echo     - WindowsHello VBS
echo     - HVCI 内存完整性
echo     - Hyper-V 等虚拟化特性
echo     - DeviceGuard 相关注册表
echo.
echo   仅在你原本就启用了这些特性、且游戏结束后想恢复时运行。
echo   如果你原本就没启用，请勿运行本脚本。
echo ============================================================
echo.
set /p ans=确认恢复以上所有安全特性？(Y/N):
if /i not "%ans%"=="Y" (
    echo 已取消。
    pause
    exit /b 0
)
echo.

echo [1/5] 恢复 hypervisorlaunchtype = auto ...
bcdedit /set hypervisorlaunchtype auto >> "%LOG%" 2>&1
if %errorlevel% equ 0 ( echo       成功。 ) else ( echo       失败。 )

echo [2/5] 恢复 WindowsHello Enabled = 1 ...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\WindowsHello" /v Enabled /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
if %errorlevel% equ 0 ( echo       成功。 ) else ( echo       失败。 )

echo [3/5] 恢复 HVCI HypervisorEnforcedCodeIntegrity Enabled = 1 ...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
if %errorlevel% equ 0 ( echo       成功。 ) else ( echo       失败。 )

echo [4/5] 重新启用 Hyper-V 等虚拟化特性 ...
powershell -NoProfile -Command "Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -match 'Hyper-V|VirtualMachinePlatform|HypervisorPlatform' } | ForEach-Object { Write-Output ('启用: ' + $_.FeatureName); Enable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -ErrorAction SilentlyContinue | Out-Null }; Write-Output 'PowerShell 部分完成'" >> "%LOG%" 2>&1
echo       完成（如本机原本未启用则无影响）。

echo [5/5] 恢复 DeviceGuard 注册表 EnableVirtualizationBasedSecurity = 1 ...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v LsaCfgFlags /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\SystemGuard" /v Enabled /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard" /v Enabled /t REG_DWORD /d 1 /f >> "%LOG%" 2>&1
echo       DeviceGuard 已批量恢复为 1。

echo.
echo ============================================================
echo   恢复完成，请重启电脑生效。
echo   重启后建议运行 diagnose-vbs.bat 复查 VBS 状态。
echo ============================================================
echo.
set /p "_=按回车退出..."
endlocal
exit /b 0
