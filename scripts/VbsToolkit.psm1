# Windows PowerShell 5.1. Mutations are kept behind small functions for mock tests.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Version = '2.0.0'
$script:Store = Join-Path $env:ProgramData 'DeltaForceVbsFix'
$script:ActiveFile = Join-Path $script:Store 'active.json'
$script:Targets = @(
    [pscustomobject]@{ Path = 'SYSTEM\CurrentControlSet\Control\DeviceGuard'; Name = 'EnableVirtualizationBasedSecurity' },
    [pscustomobject]@{ Path = 'SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; Name = 'Enabled' },
    [pscustomobject]@{ Path = 'SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'LsaCfgFlags' }
)

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MachineIdentity {
    $id = [Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography', 'MachineGuid', $null)
    if ([string]::IsNullOrWhiteSpace($id)) { throw '无法读取本机标识，停止修改。' }
    return [string]$id
}

function Read-RegistryValue {
    param([string]$Path, [string]$Name)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Path, $false)
    try {
        if ($null -eq $key -or $key.GetValueNames() -notcontains $Name) {
            return [pscustomobject]@{ Exists = $false; Type = $null; Value = $null }
        }
        return [pscustomobject]@{ Exists = $true; Type = [string]$key.GetValueKind($Name); Value = $key.GetValue($Name) }
    } finally { if ($null -ne $key) { $key.Dispose() } }
}

function Write-RegistryValue {
    param([string]$Path, [string]$Name, $State)
    if ($State.Exists) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($Path)
        try { $key.SetValue($Name, [int]$State.Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
        finally { $key.Dispose() }
    } else {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Path, $true)
        if ($null -ne $key) {
            try { $key.DeleteValue($Name, $false) } finally { $key.Dispose() }
        }
    }
}

function Invoke-Bcd {
    param([string[]]$Arguments)
    $output = & "$env:SystemRoot\System32\bcdedit.exe" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "BCDEdit 失败 ($LASTEXITCODE)：$($output -join ' ')" }
    return ($output -join "`n")
}

function Get-BootState {
    $output = Invoke-Bcd -Arguments @('/enum', '{current}', '/v')
    $id = [regex]::Match($output, '(?im)^\S+\s+(\{[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\})\s*$')
    if (-not $id.Success) { throw '无法确认当前启动项 GUID，停止修改。' }
    $match = [regex]::Match($output, '(?im)^hypervisorlaunchtype\s+(\S+)\s*$')
    if ($match.Success -and $match.Groups[1].Value -notin @('Auto', 'Off')) { throw '无法识别 hypervisorlaunchtype。' }
    $value = $null
    if ($match.Success) { $value = $match.Groups[1].Value }
    return [pscustomobject]@{ BootId = $id.Groups[1].Value; Exists = $match.Success; Value = $value }
}

function Set-BootState {
    param($State)
    $current = Get-BootState
    if ($current.BootId -ne $State.BootId) { throw '启动项已改变，停止写入 BCD。' }
    if ($State.Exists) {
        $null = Invoke-Bcd -Arguments @('/set', $State.BootId, 'hypervisorlaunchtype', $State.Value)
    } elseif ($current.Exists) {
        $null = Invoke-Bcd -Arguments @('/deletevalue', $State.BootId, 'hypervisorlaunchtype')
    }
}

function Test-TrackedFeature {
    param([string]$Name)
    return $Name -match '^(Microsoft-Hyper-V($|-)|VirtualMachinePlatform$|HypervisorPlatform$|Containers-DisposableClientVM$|Microsoft-Windows-Subsystem-Linux$)'
}

function Get-FeatureStates {
    return @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { Test-TrackedFeature $_.FeatureName } |
        ForEach-Object { [pscustomobject]@{ Name = $_.FeatureName; State = [string]$_.State } })
}

function Set-FeatureState {
    param([string]$Name, [string]$State)
    if ($State -eq 'Enabled') {
        $null = Enable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop
    } else {
        $null = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop
    }
}

function Assert-StableFeatures {
    param([object[]]$Features)
    if (@($Features | Where-Object { $_.State -notin @('Enabled', 'Disabled', 'DisabledWithPayloadRemoved') }).Count) {
        throw 'Windows 功能状态为待重启或未知，请先重启后再操作。'
    }
}

function Assert-RepairAllowed {
    # Policies are inspected, never rewritten. An administrator must resolve managed configuration.
    foreach ($spec in @(
        @{ Path = 'SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'; Names = @('EnableVirtualizationBasedSecurity', 'LsaCfgFlags', 'HypervisorEnforcedCodeIntegrity') },
        @{ Path = 'SYSTEM\CurrentControlSet\Control\DeviceGuard'; Names = @('Locked') },
        @{ Path = 'SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'; Names = @('Locked') }
    )) {
        foreach ($name in $spec.Names) {
            $state = Read-RegistryValue $spec.Path $name
            if ($state.Exists -and $state.Value -ne 0) { throw "检测到策略或 UEFI 锁：$($spec.Path)\$name。请按官方指引或联系管理员处理。" }
        }
    }
    $lsa = Read-RegistryValue 'SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags'
    if ($lsa.Exists -and $lsa.Value -eq 1) { throw 'Credential Guard 配置了 UEFI 锁。请先按微软指引处理，脚本不会修改固件。' }
}

function Initialize-StateStore {
    if (-not (Test-Administrator)) { throw '修复和恢复需要以管理员身份运行。' }
    if (-not (Test-Path -LiteralPath $script:Store)) { $null = New-Item -ItemType Directory -Path $script:Store }
    if ((Get-Item -LiteralPath $script:Store).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '备份目录不能是链接。' }
    # Only SYSTEM and Administrators may alter the journal used by an elevated restore.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $adminOwner = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($adminOwner)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $script:Store -AclObject $acl
    foreach ($name in @('active.json', 'session.lock', 'operations.log')) {
        $path = Join-Path $script:Store $name
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "状态文件不能是链接：$name" }
            # Normalize ACLs of an existing file as well as the parent directory.
            $fileAcl = New-Object Security.AccessControl.FileSecurity
            $fileAcl.SetAccessRuleProtection($false, $false)
            $fileAcl.SetOwner($adminOwner)
            Set-Acl -LiteralPath $path -AclObject $fileAcl
        }
    }
}

function Open-ToolkitLock {
    return [IO.File]::Open((Join-Path $script:Store 'session.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Write-ToolkitLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath (Join-Path $script:Store 'operations.log') -Value $line -Encoding UTF8
}

function Assert-Journal {
    param($Journal)
    if ($Journal.Schema -ne 1 -or $Journal.Machine -ne (Get-MachineIdentity) -or $Journal.Phase -notin @('Repair', 'Restore')) {
        throw '备份格式无效或不属于本机。'
    }
    $seen = @{}
    foreach ($entry in $Journal.Entries) {
        if ($entry.Kind -eq 'Registry') {
            if (-not @($script:Targets | Where-Object { $_.Path -eq $entry.Path -and $_.Name -eq $entry.Name }).Count) { throw '备份含未允许的注册表项。' }
            if ($entry.Before.Exists -isnot [bool] -or ($entry.Before.Exists -and ($entry.Before.Type -ne 'DWord' -or $entry.Before.Value -notin @(0, 1, 2, 3)))) { throw '注册表备份值无效。' }
            $key = 'Registry:' + $entry.Path + ':' + $entry.Name
        } elseif ($entry.Kind -eq 'Bcd') {
            if ($entry.Before.BootId -ne (Get-BootState).BootId -or $entry.Before.Exists -isnot [bool] -or ($entry.Before.Exists -and $entry.Before.Value -notin @('Auto', 'Off'))) { throw 'BCD 备份与当前启动项不匹配。' }
            $key = 'Bcd'
        } elseif ($entry.Kind -eq 'Features') {
            $names = @{}
            foreach ($feature in $entry.Before) {
                if (-not (Test-TrackedFeature $feature.Name) -or $names.ContainsKey($feature.Name) -or $feature.State -notin @('Enabled', 'Disabled', 'DisabledWithPayloadRemoved')) { throw 'Windows 功能备份无效。' }
                $names[$feature.Name] = $true
            }
            $key = 'Features'
        } else { throw '备份含未知操作类型。' }
        if ($seen.ContainsKey($key)) { throw '备份含重复项。' }
        $seen[$key] = $true
    }
}

function Read-Journal {
    if (-not (Test-Path -LiteralPath $script:ActiveFile)) {
        return [pscustomobject]@{ Schema = 1; Version = $script:Version; Machine = (Get-MachineIdentity); Created = (Get-Date).ToString('o'); Phase = 'Repair'; Entries = @() }
    }
    $journal = Get-Content -LiteralPath $script:ActiveFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Journal $journal
    return $journal
}

function Save-Journal {
    param($Journal)
    $temporary = Join-Path $script:Store ([guid]::NewGuid().ToString() + '.tmp')
    try {
        $json = $Journal | ConvertTo-Json -Depth 12
        # Flush to disk before any system mutation; replace atomically on the same volume.
        $stream = [IO.File]::Open($temporary, 'CreateNew', 'Write', 'None')
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $script:ActiveFile) { [IO.File]::Replace($temporary, $script:ActiveFile, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $script:ActiveFile) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Add-Baseline {
    param($Journal, $Entry)
    if ($Journal.Phase -ne 'Repair') { throw '存在尚未完成的恢复，请先运行 restore-vbs.bat。' }
    $existing = @($Journal.Entries | Where-Object {
        $_.Kind -eq $Entry.Kind -and ($Entry.Kind -ne 'Registry' -or ($_.Path -eq $Entry.Path -and $_.Name -eq $Entry.Name))
    })
    if (-not $existing.Count) {
        $Journal.Entries = @($Journal.Entries) + @($Entry)
        Save-Journal $Journal
    }
}

function Test-RegistryEqual {
    param($A, $B)
    return $A.Exists -eq $B.Exists -and (-not $A.Exists -or ($A.Type -eq $B.Type -and $A.Value -eq $B.Value))
}

function Invoke-RegistryRepair {
    param($Journal, $Target, [switch]$OnlyExisting)
    $before = Read-RegistryValue $Target.Path $Target.Name
    if (($OnlyExisting -and -not $before.Exists) -or ($before.Exists -and $before.Value -eq 0)) {
        Write-Host "[跳过] $($Target.Name)：无需更改。"
        return
    }
    if ($before.Exists -and ($before.Type -ne 'DWord' -or $before.Value -notin @(0, 1, 2, 3))) { throw '注册表类型或数值异常，停止修改。' }
    Add-Baseline $Journal ([pscustomobject]@{ Kind = 'Registry'; Path = $Target.Path; Name = $Target.Name; Before = $before })
    $after = [pscustomobject]@{ Exists = $true; Type = 'DWord'; Value = 0 }
    Write-RegistryValue $Target.Path $Target.Name $after
    if (-not (Test-RegistryEqual (Read-RegistryValue $Target.Path $Target.Name) $after)) { throw '注册表写入后的校验失败。' }
    Write-ToolkitLog "SUCCESS Registry $($Target.Path)\$($Target.Name)=0"
    Write-Host "[成功] $($Target.Name) 已设为 0，重启后复查。"
}

function Invoke-BootRepair {
    param($Journal)
    $before = Get-BootState
    if ($before.Exists -and $before.Value -eq 'Off') { Write-Host '[跳过] hypervisorlaunchtype 已是 Off。'; return }
    Add-Baseline $Journal ([pscustomobject]@{ Kind = 'Bcd'; Before = $before })
    Set-BootState ([pscustomobject]@{ BootId = $before.BootId; Exists = $true; Value = 'Off' })
    $after = Get-BootState
    if (-not $after.Exists -or $after.Value -ne 'Off') { throw 'BCD 写入后的校验失败。' }
    Write-ToolkitLog 'SUCCESS Bcd hypervisorlaunchtype=Off'
    Write-Host '[成功] hypervisorlaunchtype 已设为 Off，重启后生效。'
}

function Invoke-FeatureRepair {
    param($Journal)
    $before = @(Get-FeatureStates)
    Assert-StableFeatures $before
    $targets = @($before | Where-Object { $_.Name -in @('Microsoft-Hyper-V-Hypervisor', 'VirtualMachinePlatform', 'HypervisorPlatform') -and $_.State -eq 'Enabled' })
    if (-not $targets.Count) { Write-Host '[跳过] 未发现已启用的目标虚拟化功能。'; return }
    Add-Baseline $Journal ([pscustomobject]@{ Kind = 'Features'; Before = $before })
    foreach ($feature in $targets) {
        Set-FeatureState $feature.Name 'Disabled'
        $state = @(Get-FeatureStates | Where-Object { $_.Name -eq $feature.Name })
        if ($state.Count -ne 1 -or $state[0].State -notin @('Disabled', 'DisablePending')) { throw "禁用校验失败：$($feature.Name)" }
        Write-ToolkitLog "SUCCESS Disable $($feature.Name) $($state[0].State)"
        Write-Host "[成功] $($feature.Name)：$($state[0].State)，请重启。"
    }
}

function Invoke-RepairAction {
    param([ValidateSet('1', '3', '4', '5', '6')][string]$Choice)
    Assert-RepairAllowed
    $journal = Read-Journal
    if ($journal.Phase -ne 'Repair') { throw '请先完成上一次恢复。' }
    switch ($Choice) {
        '1' { Invoke-BootRepair $journal }
        '3' { Invoke-RegistryRepair $journal $script:Targets[1] }
        '4' { Invoke-FeatureRepair $journal }
        '5' {
            # A successful read is required; unknown is never treated as disabled.
            $device = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
            $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            if ($null -eq $device -or $null -eq $computer) { throw '诊断信息不完整，请先运行诊断。' }
            if ($device.VirtualizationBasedSecurityStatus -notin @(0, 1, 2) -or $null -eq $computer.HypervisorPresent) { throw '无法确认虚拟化状态，请先运行诊断。' }
            if ($device.VirtualizationBasedSecurityStatus -ne 0 -or $computer.HypervisorPresent) { Invoke-BootRepair $journal }
            else { Write-Host '[跳过] 未检测到运行中的 hypervisor 或已配置的 VBS，请根据游戏弹框继续排查。' }
        }
        '6' { foreach ($target in $script:Targets) { Invoke-RegistryRepair $journal $target -OnlyExisting } }
    }
}

function Restore-FeatureBaseline {
    param([object[]]$Before)
    $current = @(Get-FeatureStates)
    Assert-StableFeatures $current
    if (@($Before | Where-Object { $_.Name -notin @($current.Name) }).Count -or @($current | Where-Object { $_.Name -notin @($Before.Name) }).Count) {
        throw 'Windows 功能列表已改变，请核对备份与系统版本。'
    }
    # Restore only features that were enabled; then enforce originally disabled values.
    foreach ($desired in @($Before | Where-Object { $_.State -eq 'Enabled' } | Sort-Object { $_.Name.Length })) {
        $now = @(Get-FeatureStates | Where-Object { $_.Name -eq $desired.Name })[0]
        if ($now.State -notin @('Enabled', 'EnablePending')) { Set-FeatureState $desired.Name 'Enabled' }
    }
    foreach ($desired in @($Before | Where-Object { $_.State -ne 'Enabled' } | Sort-Object { $_.Name.Length } -Descending)) {
        $now = @(Get-FeatureStates | Where-Object { $_.Name -eq $desired.Name })[0]
        if ($desired.State -eq 'DisabledWithPayloadRemoved' -and $now.State -ne $desired.State) { throw '功能负载状态已改变，请手动核对；备份已保留。' }
        if ($desired.State -eq 'Disabled' -and $now.State -ne 'Disabled') { Set-FeatureState $desired.Name 'Disabled' }
    }
    $after = @(Get-FeatureStates)
    foreach ($desired in $Before) {
        $now = @($after | Where-Object { $_.Name -eq $desired.Name })[0]
        if ($now.State -ne $desired.State) { throw '功能恢复尚未通过最终校验，可能需要重启。请重启后再次运行恢复，备份已保留。' }
    }
}

function Invoke-ToolkitRestore {
    if (-not (Test-Path -LiteralPath $script:ActiveFile)) { Write-Host '没有本工具 2.0 创建的活动备份，未修改任何系统设置。'; return }
    $journal = Read-Journal
    $journal.Phase = 'Restore'
    Save-Journal $journal
    # An interrupted restore is retryable; repair cannot replace this baseline.
    foreach ($entry in $journal.Entries) {
        switch ($entry.Kind) {
            'Registry' {
                Write-RegistryValue $entry.Path $entry.Name $entry.Before
                if (-not (Test-RegistryEqual (Read-RegistryValue $entry.Path $entry.Name) $entry.Before)) { throw '注册表恢复校验失败，备份已保留。' }
            }
            'Bcd' {
                Set-BootState $entry.Before
                $after = Get-BootState
                if ($after.Exists -ne $entry.Before.Exists -or ($after.Exists -and $after.Value -ne $entry.Before.Value)) { throw 'BCD 恢复校验失败，备份已保留。' }
            }
            'Features' { Restore-FeatureBaseline @($entry.Before) }
        }
        Write-ToolkitLog "RESTORE verified $($entry.Kind)"
    }
    $archive = Join-Path $script:Store ('restored-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::Move($script:ActiveFile, $archive)
    Write-Host '[成功] 已恢复备份中的原配置。请重启并重新诊断。'
    Write-Host "历史备份：$archive"
}

function Get-ToolkitDiagnostic {
    $checks = @()
    foreach ($probe in @(
        @{ Name = 'CPU'; Run = { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object Name, VirtualizationFirmwareEnabled, VMMonitorModeExtensions } },
        @{ Name = 'Hypervisor'; Run = { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Select-Object HypervisorPresent } },
        @{ Name = 'BCD'; Run = { Get-BootState } },
        @{ Name = 'VBS'; Run = { Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop | Select-Object VirtualizationBasedSecurityStatus, SecurityServicesConfigured, SecurityServicesRunning } },
        @{ Name = 'WindowsFeatures'; Run = { Get-FeatureStates } },
        @{ Name = 'Registry'; Run = { foreach ($target in $script:Targets) { [pscustomobject]@{ Path = $target.Path; Name = $target.Name; State = (Read-RegistryValue $target.Path $target.Name) } } } },
        @{ Name = 'PolicyAndLocks'; Run = { Assert-RepairAllowed; '未检测到列出的策略或 UEFI 锁；MDM / 固件状态仍需管理员核实。' } },
        @{ Name = 'Antivirus'; Run = { Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | Select-Object displayName, productState } }
    )) {
        try {
            $data = @(& $probe.Run)
            if (-not $data.Count) { throw '没有返回数据。' }
            $checks += [pscustomobject]@{ Name = $probe.Name; Status = 'OK'; Data = $data; Error = $null }
        } catch { $checks += [pscustomobject]@{ Name = $probe.Name; Status = 'Unknown'; Data = @(); Error = $_.Exception.Message } }
    }
    return [pscustomobject]@{ Version = $script:Version; Time = (Get-Date).ToString('o'); Administrator = (Test-Administrator); Checks = $checks }
}

function Show-ToolkitDiagnostic {
    $report = Get-ToolkitDiagnostic
    Write-Host "三角洲行动 CPU 虚拟化诊断 v$script:Version（只读系统设置）"
    foreach ($check in $report.Checks) {
        Write-Host "`n[$($check.Name)] $($check.Status)"
        if ($check.Status -eq 'Unknown') { Write-Host "未知 / 检查失败：$($check.Error)" }
        else { Write-Host ($check.Data | ConvertTo-Json -Depth 6) }
    }
    Write-Host @'

诊断解释
- VBS：0=未启用，1=已启用但未运行，2=正在运行；检查失败不等于关闭。
- HypervisorPresent=True 时，CPU 虚拟化属性可能被屏蔽，不能据此断言 BIOS 没开。
- CPU 检查不能确认 VT-d / IOMMU。请按主板文档核对 BIOS。
- Windows 功能 Enabled 只表示已安装启用，不证明它当前正在占用虚拟化。
- Windows Hello / 杀毒软件的存在不能证明它是弹框原因。菜单 2 提供登录设置指引。
- 默认先诊断，再按实际弹框选择修复；菜单 1 / 5 也会影响 WSL2、Docker 和依赖 hypervisor 的软件。
'@
    $folder = Join-Path $env:LOCALAPPDATA 'DeltaForceVbsFix\Reports'
    try {
        $null = New-Item -ItemType Directory -Path $folder -Force
        $path = Join-Path $folder ('diagnostic-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.json')
        $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
        Write-Host "`n诊断报告：$path"
    } catch { Write-Warning "报告无法保存：$($_.Exception.Message)；请查看上方结果。" }
}

Export-ModuleMember -Function Test-Administrator, Initialize-StateStore, Open-ToolkitLock, Write-ToolkitLog, Invoke-RepairAction, Invoke-ToolkitRestore, Show-ToolkitDiagnostic
