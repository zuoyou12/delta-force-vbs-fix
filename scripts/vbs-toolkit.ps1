#requires -Version 5.1
param([ValidateSet('Diagnose', 'Fix', 'Restore')][string]$Mode = 'Diagnose')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if (-not [Environment]::Is64BitProcess) {
    Write-Host '请在 64 位 Windows PowerShell 中运行本工具。'
    exit 1
}
Import-Module (Join-Path $PSScriptRoot 'VbsToolkit.psm1') -Force
$lock = $null
try {
    if ($Mode -eq 'Diagnose') { Show-ToolkitDiagnostic; exit 0 }
    Initialize-StateStore
    $lock = Open-ToolkitLock
    if ($Mode -eq 'Restore') {
        Write-Host '恢复仅使用本机 2.0 备份，恢复后需重启。它不能撤销旧版未备份的修改。'
        if ((Read-Host '输入 RESTORE 恢复原配置，其他输入取消') -ceq 'RESTORE') { Invoke-ToolkitRestore }
        exit 0
    }
    while ($true) {
        Write-Host @'

三角洲行动 CPU 虚拟化工具包 2.0
0. 退出
1. 禁止 hypervisor 随启动加载（会影响 WSL2 / Docker 等）
2. Windows Hello 手动设置指引（不修改登录凭据）
3. 关闭 HVCI 内存完整性（会降低内核保护）
4. 禁用 Hyper-V hypervisor / 虚拟机平台 / Windows hypervisor 平台
5. 按诊断执行基础修复（仅在必要时执行菜单 1）
6. 高级：关闭现有 VBS / HVCI / Credential Guard 注册表配置
7. 重启电脑（再次确认）
8. 只读诊断并导出报告
'@
        $choice = Read-Host '请选择 [0-8]'
        if ($choice -eq '0') { break }
        if ($choice -eq '2') {
            Write-Host '如官方指引要求检查 Windows Hello，请打开 设置 > 账户 > 登录选项。'
            Write-Host '先确认自己记得账户密码，按需手动调整指纹 / 面部 / PIN。脚本不会代删凭据，也不能恢复手动变更。'
            if ((Read-Host '输入 OPEN 打开登录选项，其他输入返回') -ceq 'OPEN') { Start-Process 'ms-settings:signinoptions' }
            continue
        }
        if ($choice -eq '7') {
            if ((Read-Host '请先保存文件。输入 REBOOT 在 30 秒后重启，其他输入取消') -ceq 'REBOOT') {
                & "$env:SystemRoot\System32\shutdown.exe" /r /t 30 /c 'VBS 工具包：应用系统配置。取消请运行 shutdown /a。'
                if ($LASTEXITCODE -ne 0) { throw '安排重启失败。' }
                Write-Host '已安排重启。取消请运行 shutdown /a。'
                break
            }
            continue
        }
        if ($choice -eq '8') { Show-ToolkitDiagnostic; continue }
        if ($choice -notin @('1', '3', '4', '5', '6')) { Write-Host '无效选项，请重新输入。'; continue }
        Write-Host '此操作将修改上面所选配置，降低相关保护或影响虚拟化软件。修改前自动保存原值。'
        if ((Read-Host '输入 APPLY 执行，其他输入返回') -cne 'APPLY') { continue }
        try { Invoke-RepairAction $choice }
        catch {
            Write-ToolkitLog "FAILED menu=$choice $($_.Exception.Message)"
            Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '可能有部分修改已完成。原配置备份会保留，可运行 restore-vbs.bat 恢复。'
        }
    }
} catch {
    Write-Host "[失败] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally { if ($null -ne $lock) { $lock.Dispose() } }
