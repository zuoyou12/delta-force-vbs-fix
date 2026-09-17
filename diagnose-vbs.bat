@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
title 三角洲行动 CPU 虚拟化问题 - 诊断脚本

rem ============================================================
rem   diagnose-vbs.bat
rem   对齐腾讯游戏安全官方指引 gamesafe.qq.com/article/1181.shtml
rem   覆盖 Part1(BIOS) + 情况一 HVCI + 情况二 VBS + 情况三 Hyper-V + 情况四 其他
rem ============================================================

rem ---------- 管理员权限检测（不足时自动提权） ----------
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
echo   三角洲行动 CPU 虚拟化问题 - 诊断报告
echo   官方指引参考：https://gamesafe.qq.com/article/1181.shtml
echo ============================================================
echo.

rem ---------- [1/8] BIOS 层 CPU 虚拟化 ----------
echo [1/8] BIOS 层 CPU 虚拟化（VT-X/VT-D 或 SVM/IOMMU）...
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Processor; '{0,-32} {1}' -f '处理器名称:', $p.Name; '{0,-32} {1}' -f 'VirtualizationFirmwareEnabled:', $p.VirtualizationFirmwareEnabled; '{0,-32} {1}' -f 'VMMonitorModeExtensions:', $p.VMMonitorModeExtensions"
echo       ^> 若上述均为 false/0，请进 BIOS 开启：参考 README 第 5 节，或官方 Part1 图文指引。
echo.

rem ---------- [2/8] hypervisorlaunchtype ----------
echo [2/8] hypervisorlaunchtype（应目标为 Off）...
bcdedit /enum {current} 2>nul | findstr /i hypervisor
if %errorlevel% neq 0 echo       ^(未输出 hypervisor 项，说明是默认值 Auto^)
echo.

rem ---------- [3/8] VBS 状态 ----------
echo [3/8] VBS（基于虚拟化的安全性）状态...
echo       VirtualizationBasedSecurityStatus: 0=未启用  1=已启用未运行  2=已运行 ^<-- 2 即占用 VT-x
powershell -NoProfile -Command "Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue | Select-Object VirtualizationBasedSecurityStatus, SecurityServicesConfigured, SecurityServicesRunning | Format-List"
echo.

rem ---------- [4/8] HVCI 内存完整性 ----------
echo [4/8] HVCI 内存完整性（情况一）...
echo       SecurityServicesRunning 含 2 表示 HVCI 在跑；下面注册表 Enabled=1 表示已配置
powershell -NoProfile -Command "$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction SilentlyContinue).Enabled; 'HypervisorEnforcedCodeIntegrity.Enabled = {0}' -f $v"
echo.

rem ---------- [5/8] Hyper-V / 虚拟化平台 Windows 特性 ----------
echo [5/8] Hyper-V 等虚拟化相关 Windows 特性（情况三）...
powershell -NoProfile -Command "Get-WindowsOptionalFeature -Online 2>$null | Where-Object { $_.FeatureName -match 'Hyper-V|VirtualMachinePlatform|HypervisorPlatform|Containers-DisposableClientVM|Microsoft-Windows-Subsystem-Linux' } | Select-Object FeatureName, State | Format-Table -AutoSize"
echo.

rem ---------- [6/8] WindowsHello 生物识别 ----------
echo [6/8] WindowsHello 面部/指纹（情况四-a，可能阻止 Hyper-V 关闭）...
powershell -NoProfile -Command "$k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WinBio\Databases'; if (Test-Path $k) { 'WinBio Databases 存在 ^<-- 若启用了面部/指纹登录，请先在 设置->账户->登录 中关闭后再关 Hyper-V' } else { '未发现 WinBio Databases' }"
powershell -NoProfile -Command "$ngc = 'HKLM:\SOFTWARE\Microsoft\Windows Hello\Business\Ngc'; if (Test-Path $ngc) { $v = (Get-ItemProperty $ngc -ErrorAction SilentlyContinue).Enable; 'Windows Hello Business Ngc.Enable = {0}' -f $v } else { '未配置 Windows Hello for Business' }"
echo.

rem ---------- [7/8] 第三方杀软 ----------
echo [7/8] 已安装的杀毒软件（情况四-b，第三方杀软可能占用 VT-x）...
powershell -NoProfile -Command "Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Select-Object displayName, productState | Format-Table -AutoSize"
echo       ^> 若列出非 Windows Defender 的杀软，请尝试退出后再进游戏。
echo.

rem ---------- [8/8] DeviceGuard 注册表残留 ----------
echo [8/8] DeviceGuard 相关注册表（情况四-c/d）...
powershell -NoProfile -Command "$base = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'; $keys = @('EnableVirtualizationBasedSecurity','LsaCfgFlags'); foreach ($k in $keys) { $v = (Get-ItemProperty $base -ErrorAction SilentlyContinue).$k; '{0,-40} = {1}' -f $k, $v }; $scn = Join-Path $base 'Scenarios'; if (Test-Path $scn) { Get-ChildItem $scn | ForEach-Object { $e = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).Enabled; 'Scenarios\{0}\Enabled = {1}' -f $_.PSChildName, $e } }"
echo.

rem ---------- 诊断结论 ----------
echo ============================================================
echo   诊断结论与建议
echo ============================================================
echo   - 若 [1/8] 显示 false：请在 BIOS 开启 VT-X/VT-D 或 SVM/IOMMU（参考 README 第 5 节）
echo   - 若 [3/8] VirtualizationBasedSecurityStatus = 2：运行 fix-vbs.bat 菜单 1（情况二 VBS）
echo   - 若 [4/8] HVCI Enabled = 1：运行 fix-vbs.bat 菜单 3（情况一 内存完整性）
echo   - 若 [5/8] Hyper-V 等显示 Enabled：运行 fix-vbs.bat 菜单 4（情况三 Hyper-V）
echo   - 若 [6/8] 启用了面部/指纹：先手动关闭，或运行 fix-vbs.bat 菜单 2（情况四-a WindowsHello）
echo   - 若 [7/8] 有第三方杀软：退出后再进游戏（情况四-b）
echo   - 若 [8/8] DeviceGuard 各项非 0：运行 fix-vbs.bat 菜单 5（情况四-c/d 注册表残留）
echo   - 不确定？直接运行 fix-vbs.bat 菜单 5 一键自动修复
echo.
echo   修复后请重启电脑，再用本脚本复查。
echo ============================================================
echo.
set /p "_=按回车退出..."
endlocal
