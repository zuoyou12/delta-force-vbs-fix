@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
title 三角洲行动 CPU 虚拟化修复工具

rem ============================================================
rem   fix-vbs.bat  对齐 gamesafe.qq.com/article/1181.shtml
rem   菜单：
rem     0 退出
rem     1 关闭 VBS（情况二）            bcdedit /set hypervisorlaunchtype off
rem     2 关闭 WindowsHello VBS（情况四-a） 注册表 WindowsHello Enabled=0
rem     3 关闭 HVCI 内存完整性（情况一）   注册表 HypervisorEnforcedCodeIntegrity Enabled=0
rem     4 关闭 Hyper-V（情况三）          DISM + Disable-WindowsOptionalFeature
rem     5 一键自动修复（推荐）            依次执行 1+2+3+4，跳过已禁用项
rem     6 关闭 DeviceGuard 注册表残留（情况四-c/d）
rem     7 重启电脑
rem ============================================================

set "LOG=%~dp0fix-vbs.log"
echo 修复日志 - %date% %time% > "%LOG%"

:chkadmin
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
        call :pause
    )
    exit /b 1
)

:menu
cls
echo ============================================================
echo   三角洲行动 CPU 虚拟化修复工具
echo   官方指引：https://gamesafe.qq.com/article/1181.shtml
echo ------------------------------------------------------------
echo   0. 退出
echo   1. 关闭 VBS（情况二）                bcdedit hypervisorlaunchtype off
echo   2. 关闭 WindowsHello VBS（情况四-a）  注册表 WindowsHello=0
echo   3. 关闭 HVCI 内存完整性（情况一）      注册表 HVCI=0
echo   4. 关闭 Hyper-V（情况三）             DISM Disable Feature
echo   5. 一键自动修复（推荐）              执行 1+2+3+4，跳过已禁用项
echo   6. 关闭 DeviceGuard 残留（情况四-c/d） 注册表批量归零
echo   7. 重启电脑
echo ============================================================
set /p choice=请输入选项 [0-7]:
echo.

if "%choice%"=="0" goto :end
if "%choice%"=="1" call :fix_vbs       & goto :after
if "%choice%"=="2" call :fix_hello     & goto :after
if "%choice%"=="3" call :fix_hvci      & goto :after
if "%choice%"=="4" call :fix_hyperv    & goto :after
if "%choice%"=="5" call :fix_auto      & goto :after
if "%choice%"=="6" call :fix_dg        & goto :after
if "%choice%"=="7" call :reboot        & goto :end
echo 无效选项，请重新输入。
timeout /t 2 >nul
goto :menu

:after
echo.
echo   --------------------------------------------------------
echo   操作完成。强烈建议执行菜单 7 重启电脑后再次运行
echo   diagnose-vbs.bat 复查状态。
echo   --------------------------------------------------------
echo.
call :pause
goto :menu

rem ============== 子例程 ==============

rem -- 不会因 redirected stdin 而闪退的暂停
:pause
set /p "_=按回车继续..."
goto :eof

:fix_vbs
echo [情况二] 关闭 VBS（bcdedit /set hypervisorlaunchtype off）...
echo [情况二] 关闭 VBS（bcdedit hypervisorlaunchtype off） >> "%LOG%"
bcdedit /set hypervisorlaunchtype off >> "%LOG%" 2>&1
if %errorlevel% equ 0 ( echo       成功。 & echo       成功。 >> "%LOG%" ) else ( echo       失败，errorlevel=%errorlevel% & echo       失败 errorlevel=%errorlevel% >> "%LOG%" )
goto :eof

:fix_hello
echo [情况四-a] 关闭 WindowsHello VBS（注册表 WindowsHello Enabled=0）...
echo [情况四-a] 关闭 WindowsHello VBS >> "%LOG%"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\WindowsHello" /v Enabled /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
if %errorlevel% equ 0 ( echo       成功。 & echo       成功。 >> "%LOG%" ) else ( echo       失败，errorlevel=%errorlevel% & echo       失败 >> "%LOG%" )
echo       提示：若仍无法关闭 Hyper-V，请先在「设置 -> 账户 -> 登录」中关闭面部/指纹识别并删除 PIN。
goto :eof

:fix_hvci
echo [情况一] 关闭 HVCI 内存完整性（注册表 HypervisorEnforcedCodeIntegrity Enabled=0）...
echo [情况一] 关闭 HVCI 内存完整性 >> "%LOG%"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
if %errorlevel% equ 0 ( echo       成功。 & echo       成功。 >> "%LOG%" ) else ( echo       失败，errorlevel=%errorlevel% & echo       失败 >> "%LOG%" )
echo       也可在「Windows 安全中心 -> 设备安全性 -> 内核隔离详细信息 -> 关闭内存完整性」手动操作。
goto :eof

:fix_hyperv
echo [情况三] 关闭 Hyper-V（DISM + PowerShell Disable-WindowsOptionalFeature）...
echo [情况三] 关闭 Hyper-V >> "%LOG%"
powershell -NoProfile -Command "Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -match 'Hyper-V|VirtualMachinePlatform|HypervisorPlatform' -and $_.State -eq 'Enabled' } | ForEach-Object { Write-Output ('禁用: ' + $_.FeatureName); Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -ErrorAction SilentlyContinue | Out-Null }; Write-Output 'PowerShell 部分完成'" >> "%LOG%" 2>&1
dism /online /disable-feature /featurename:Microsoft-Hyper-V-All /quiet /norestart >> "%LOG%" 2>&1
echo       DISM 完成（如本机未启用 Hyper-V 则无影响）。
goto :eof

:fix_auto
echo [一键自动修复] 检测当前状态并依次执行 1+2+3+4...
echo [一键自动修复] 开始 >> "%LOG%"
rem --- VBS ---
powershell -NoProfile -Command "$d = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue; if ($d.VirtualizationBasedSecurityStatus -ne 0) { 'VBS_OCCUPIED' } else { 'VBS_OK' }" > "%TEMP%\vbschk.txt" 2>&1
findstr /c:"VBS_OCCUPIED" "%TEMP%\vbschk.txt" >nul
if %errorlevel% equ 0 ( call :fix_vbs ) else ( echo [跳过] VBS 已是关闭状态。 )
rem --- WindowsHello ---
powershell -NoProfile -Command "$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\WindowsHello' -ErrorAction SilentlyContinue).Enabled; if ($v -ne 0) { 'HELLO_ON' } else { 'HELLO_OK' }" > "%TEMP%\hellochk.txt" 2>&1
findstr /c:"HELLO_ON" "%TEMP%\hellochk.txt" >nul
if %errorlevel% equ 0 ( call :fix_hello ) else ( echo [跳过] WindowsHello 已关闭。 )
rem --- HVCI ---
powershell -NoProfile -Command "$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction SilentlyContinue).Enabled; if ($v -ne 0) { 'HVCI_ON' } else { 'HVCI_OK' }" > "%TEMP%\hvcichk.txt" 2>&1
findstr /c:"HVCI_ON" "%TEMP%\hvcichk.txt" >nul
if %errorlevel% equ 0 ( call :fix_hvci ) else ( echo [跳过] HVCI 已关闭。 )
rem --- Hyper-V ---
powershell -NoProfile -Command "$f = Get-WindowsOptionalFeature -Online | Where-Object { $_.FeatureName -match 'Hyper-V|VirtualMachinePlatform|HypervisorPlatform' -and $_.State -eq 'Enabled' }; if ($f) { 'HYPERV_ON' } else { 'HYPERV_OK' }" > "%TEMP%\hypervchk.txt" 2>&1
findstr /c:"HYPERV_ON" "%TEMP%\hypervchk.txt" >nul
if %errorlevel% equ 0 ( call :fix_hyperv ) else ( echo [跳过] Hyper-V 等已禁用。 )
call :fix_dg
echo [一键自动修复] 完成 >> "%LOG%"
del /q "%TEMP%\vbschk.txt" "%TEMP%\hellochk.txt" "%TEMP%\hvcichk.txt" "%TEMP%\hypervchk.txt" 2>nul
goto :eof

:fix_dg
echo [情况四-c/d] 关闭 DeviceGuard 注册表残留...
echo [情况四-c/d] DeviceGuard 残留归零 >> "%LOG%"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v LsaCfgFlags /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\SystemGuard" /v Enabled /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard" /v Enabled /t REG_DWORD /d 0 /f >> "%LOG%" 2>&1
echo       DeviceGuard 相关注册表已批量归零。
echo       组策略路径「计算机配置 -> 管理模板 -> 系统 -> Device Guard -> 基于虚拟化的安全 -> 已禁用」也等效。
goto :eof

:reboot
echo 即将重启电脑以使修改生效...
set /p ans=确认重启？(Y/N):
if /i "%ans%"=="Y" shutdown /r /t 5 /c "CPU 虚拟化修复完成，5 秒后重启"
goto :eof

:end
endlocal
exit /b 0
