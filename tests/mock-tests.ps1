#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '..\scripts\VbsToolkit.psm1') -Force -PassThru
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('vbs-toolkit-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    & $module {
        param($Folder)
        $script:Store = $Folder
        $script:ActiveFile = Join-Path $Folder 'active.json'
        $script:Passed = 0
        $script:ReadBootParser = ${function:Get-BootState}
        function script:Assert($Condition, $Message) {
            if (-not $Condition) { throw "ASSERT: $Message" }
        }
        function script:Expect-Failure([scriptblock]$Action, [string]$Pattern) {
            $failed = $false
            try { & $Action } catch {
                $failed = $true
                if ($_.Exception.Message -notmatch $Pattern) { throw }
            }
            Assert $failed "Expected failure: $Pattern"
        }
        function script:Reset-Fixture {
            Get-ChildItem -LiteralPath $script:Store -File | Remove-Item
            $script:Registry = @{}
            $script:Boot = [pscustomobject]@{ BootId = '{12345678-1234-1234-1234-123456789012}'; Exists = $false; Value = $null }
            $script:Features = @(
                [pscustomobject]@{ Name = 'Microsoft-Hyper-V-All'; State = 'Enabled' },
                [pscustomobject]@{ Name = 'Microsoft-Hyper-V-Hypervisor'; State = 'Enabled' },
                [pscustomobject]@{ Name = 'VirtualMachinePlatform'; State = 'Disabled' },
                [pscustomobject]@{ Name = 'HypervisorPlatform'; State = 'DisabledWithPayloadRemoved' },
                [pscustomobject]@{ Name = 'Microsoft-Windows-Subsystem-Linux'; State = 'Enabled' }
            )
            $script:Mutations = 0
            $script:FailWrite = $false
            $script:FailDiagnostic = $false
            $script:PendingFeatures = $false
            $script:VbsStatus = 2
            $script:Hypervisor = $true
            $script:BcdText = "Windows Boot Loader`n-------------------`nidentifier              {12345678-1234-1234-1234-123456789012}`nhypervisorlaunchtype    Auto"
        }
        function script:Get-MachineIdentity { return 'test-machine' }
        function script:Test-Administrator { return $true }
        function script:Read-RegistryValue($Path, $Name) {
            $key = "$Path|$Name"
            if ($script:Registry.ContainsKey($key)) { return $script:Registry[$key] }
            return [pscustomobject]@{ Exists = $false; Type = $null; Value = $null }
        }
        function script:Assert-PersistedBeforeWrite {
            Assert (Test-Path -LiteralPath $script:ActiveFile) 'backup must exist before a mutation'
            $saved = Get-Content -LiteralPath $script:ActiveFile -Raw | ConvertFrom-Json
            Assert (@($saved.Entries).Count -gt 0) 'persisted backup must contain entries'
            $script:Mutations++
            if ($script:FailWrite) { throw 'simulated write failure' }
        }
        function script:Write-RegistryValue($Path, $Name, $State) {
            Assert-PersistedBeforeWrite
            $script:Registry["$Path|$Name"] = $State
        }
        function script:Get-BootState { return $script:Boot.PSObject.Copy() }
        function script:Invoke-Bcd($Arguments) {
            Assert (($Arguments -join ' ') -eq '/enum {current} /v') 'unexpected BCDEdit read command'
            return $script:BcdText
        }
        function script:Set-BootState($State) {
            Assert-PersistedBeforeWrite
            $script:Boot = $State.PSObject.Copy()
        }
        function script:Get-FeatureStates { return $script:Features | ForEach-Object { $_.PSObject.Copy() } }
        function script:Set-FeatureState($Name, $State) {
            Assert-PersistedBeforeWrite
            foreach ($feature in $script:Features) {
                if ($feature.Name -eq $Name) {
                    if ($script:PendingFeatures) { $feature.State = if ($State -eq 'Enabled') { 'EnablePending' } else { 'DisablePending' } }
                    else { $feature.State = $State }
                }
            }
        }
        function script:Get-CimInstance {
            param([Parameter(Position=0)]$ClassName, $Namespace)
            if ($script:FailDiagnostic) { throw 'simulated unavailable provider' }
            if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ HypervisorPresent = $script:Hypervisor } }
            if ($ClassName -eq 'Win32_Processor') { return [pscustomobject]@{ Name = 'Fake CPU'; VirtualizationFirmwareEnabled = $false; VMMonitorModeExtensions = $false } }
            if ($ClassName -eq 'AntiVirusProduct') { return [pscustomobject]@{ displayName = 'Fake AV'; productState = 0 } }
            return [pscustomobject]@{ VirtualizationBasedSecurityStatus = $script:VbsStatus; SecurityServicesConfigured = @(1,2); SecurityServicesRunning = @(1,2) }
        }
        function script:Test-Case($Name, [scriptblock]$Run) {
            Reset-Fixture
            & $Run
            $script:Passed++
            Write-Host "PASS $Name"
        }
        Test-Case 'BCD parser reads GUID and explicit launch value' {
            $parsed = & $script:ReadBootParser
            Assert ($parsed.BootId -eq $script:Boot.BootId -and $parsed.Exists -and $parsed.Value -eq 'Auto') 'BCD parser'
        }
        Test-Case 'BCD parser preserves absence and rejects malformed native output' {
            $script:BcdText = "identifier              {12345678-1234-1234-1234-123456789012}`npath                    \\Windows\\system32\\winload.efi"
            $parsed = & $script:ReadBootParser
            Assert (-not $parsed.Exists -and $null -eq $parsed.Value) 'missing BCD option'
            $script:BcdText = 'Access is denied.'
            Expect-Failure { & $script:ReadBootParser } 'GUID'
        }
        Test-Case 'BCD absent value is preserved and removed on restore' {
            Invoke-RepairAction '1'
            Assert ($script:Boot.Value -eq 'Off') 'boot repair'
            $baseline = Read-Journal
            Assert (-not $baseline.Entries[0].Before.Exists) 'absent baseline'
            Invoke-ToolkitRestore
            Assert (-not $script:Boot.Exists) 'must restore absence, not explicit Auto'
            Assert (-not (Test-Path $script:ActiveFile)) 'completed backup archived'
        }
        Test-Case 'Repeated repair keeps the initial baseline' {
            Invoke-RepairAction '1'
            $script:Boot.Value = 'Auto'
            Invoke-RepairAction '1'
            $journal = Read-Journal
            Assert ($journal.Entries.Count -eq 1) 'duplicate entry'
            Assert (-not $journal.Entries[0].Before.Exists) 'baseline replaced'
        }
        Test-Case 'HVCI originally absent is removed on restore' {
            Invoke-RepairAction '3'
            Invoke-ToolkitRestore
            Assert (-not (Read-RegistryValue $script:Targets[1].Path 'Enabled').Exists) 'missing value must be removed'
        }
        Test-Case 'Restore preserves explicit original value and type' {
            $target = $script:Targets[1]
            $script:Registry["$($target.Path)|Enabled"] = [pscustomobject]@{ Exists = $true; Type = 'DWord'; Value = 1 }
            Invoke-RepairAction '3'
            Invoke-ToolkitRestore
            Assert ((Read-RegistryValue $target.Path 'Enabled').Value -eq 1) 'restore original DWORD'
        }
        Test-Case 'Advanced action skips absent values and uses correct LSA path' {
            $target = $script:Targets[2]
            $script:Registry["$($target.Path)|LsaCfgFlags"] = [pscustomobject]@{ Exists = $true; Type = 'DWord'; Value = 2 }
            Invoke-RepairAction '6'
            Assert ($script:Mutations -eq 1) 'must not create other missing values'
            Assert ((Read-Journal).Entries[0].Path -eq 'SYSTEM\CurrentControlSet\Control\Lsa') 'wrong LSA path'
        }
        Test-Case 'Automatic repair changes only boot setting' {
            Invoke-RepairAction '5'
            Assert ($script:Mutations -eq 1) 'auto repair must be minimal'
            Assert ((Read-Journal).Entries[0].Kind -eq 'Bcd') 'auto changes wrong setting'
        }
        Test-Case 'Automatic repair skips when runtime evidence is clear' {
            $script:VbsStatus = 0; $script:Hypervisor = $false
            Invoke-RepairAction '5'
            Assert ($script:Mutations -eq 0) 'should skip'
        }
        Test-Case 'Unknown diagnostic is not interpreted as disabled' {
            $script:FailDiagnostic = $true
            Expect-Failure { Invoke-RepairAction '5' } 'unavailable provider'
            Assert ($script:Mutations -eq 0) 'unknown status must not mutate'
            $report = Get-ToolkitDiagnostic
            Assert (@($report.Checks | Where-Object { $_.Status -eq 'Unknown' }).Count -gt 0) 'unknown missing from report'
        }
        Test-Case 'Unknown VBS value blocks automatic repair' {
            $script:VbsStatus = $null
            Expect-Failure { Invoke-RepairAction '5' } '无法确认'
            Assert ($script:Mutations -eq 0) 'unknown VBS'
        }
        Test-Case 'Write failure leaves a readable baseline' {
            $script:FailWrite = $true
            Expect-Failure { Invoke-RepairAction '1' } 'simulated write failure'
            Assert ((Read-Journal).Entries.Count -eq 1) 'failed operation lost backup'
            Assert (-not $script:Boot.Exists) 'failed write altered boot'
        }
        Test-Case 'Feature restore does not enable originally disabled features' {
            Invoke-RepairAction '4'
            Assert ($script:Mutations -eq 1) 'only hypervisor should be disabled'
            Invoke-ToolkitRestore
            Assert (@($script:Features | Where-Object { $_.Name -eq 'VirtualMachinePlatform' -and $_.State -eq 'Disabled' }).Count -eq 1) 'enabled previously disabled VMP'
            Assert (@($script:Features | Where-Object { $_.Name -eq 'HypervisorPlatform' -and $_.State -eq 'DisabledWithPayloadRemoved' }).Count -eq 1) 'changed payload state'
        }
        Test-Case 'Feature pending state blocks modification before backup' {
            $script:Features[0].State = 'EnablePending'
            Expect-Failure { Invoke-RepairAction '4' } '待重启'
            Assert ($script:Mutations -eq 0) 'pending must not mutate'
        }
        Test-Case 'Partial restore remains retryable and blocks new repairs' {
            Invoke-RepairAction '1'
            $script:FailWrite = $true
            Expect-Failure { Invoke-ToolkitRestore } 'simulated write failure'
            Assert ((Read-Journal).Phase -eq 'Restore') 'phase lost'
            Expect-Failure { Invoke-RepairAction '3' } '完成上一次恢复'
            $script:FailWrite = $false
            Invoke-ToolkitRestore
            Assert (-not $script:Boot.Exists) 'retry failed'
        }
        Test-Case 'Restore with pending features keeps backup until reboot verification' {
            Invoke-RepairAction '4'
            $script:PendingFeatures = $true
            Expect-Failure { Invoke-ToolkitRestore } '最终校验'
            Assert (Test-Path $script:ActiveFile) 'pending restore lost backup'
            foreach ($feature in $script:Features) { if ($feature.State -eq 'EnablePending') { $feature.State = 'Enabled' } }
            $script:PendingFeatures = $false
            Invoke-ToolkitRestore
            Assert (-not (Test-Path $script:ActiveFile)) 'reboot verification did not finish'
        }
        Test-Case 'No backup causes no mutation' {
            Invoke-ToolkitRestore
            Assert ($script:Mutations -eq 0) 'restore without baseline'
        }
        Test-Case 'Managed policy blocks repair' {
            $script:Registry['SOFTWARE\Policies\Microsoft\Windows\DeviceGuard|EnableVirtualizationBasedSecurity'] = [pscustomobject]@{ Exists = $true; Type = 'DWord'; Value = 1 }
            Expect-Failure { Invoke-RepairAction '1' } '策略或 UEFI 锁'
            Assert ($script:Mutations -eq 0) 'policy bypass'
        }
        Test-Case 'UEFI locked credential guard blocks repair' {
            $script:Registry['SYSTEM\CurrentControlSet\Control\Lsa|LsaCfgFlags'] = [pscustomobject]@{ Exists = $true; Type = 'DWord'; Value = 1 }
            Expect-Failure { Invoke-RepairAction '1' } 'UEFI 锁'
            Assert ($script:Mutations -eq 0) 'UEFI lock bypass'
        }
        Test-Case 'Wrong machine, wrong boot and arbitrary registry targets are rejected' {
            Invoke-RepairAction '1'
            $journal = Read-Journal
            $journal.Machine = 'another-machine'
            Expect-Failure { Assert-Journal $journal } '不属于本机'
            $journal.Machine = 'test-machine'
            $journal.Entries[0].Before.BootId = '{99999999-9999-9999-9999-999999999999}'
            Expect-Failure { Assert-Journal $journal } '启动项不匹配'
            $journal.Entries = @([pscustomobject]@{ Kind = 'Registry'; Path = 'SOFTWARE\Anything'; Name = 'Bad'; Before = [pscustomobject]@{ Exists = $false } })
            Expect-Failure { Assert-Journal $journal } '未允许'
        }
        Test-Case 'Corrupted JSON stops before system mutation' {
            Set-Content -LiteralPath $script:ActiveFile -Value 'invalid json'
            Expect-Failure { Invoke-RepairAction '1' } '.'
            Assert ($script:Mutations -eq 0) 'corrupted backup'
        }
        Test-Case 'Backup failure prevents the write' {
            $realActive = $script:ActiveFile
            $script:ActiveFile = Join-Path (Join-Path $Folder 'missing') 'active.json'
            try {
                Expect-Failure { Invoke-RepairAction '1' } '.'
                Assert ($script:Mutations -eq 0) 'backup failure must stop mutation'
            } finally { $script:ActiveFile = $realActive }
        }
        Test-Case 'Exclusive process lock rejects concurrent mutation sessions' {
            $one = Open-ToolkitLock
            try { Expect-Failure { $two = Open-ToolkitLock; $two.Dispose() } '.' }
            finally { $one.Dispose() }
        }
        Write-Host "`n$script:Passed mock regression tests passed. No real system settings were modified."
    } $testRoot
} finally {
    Remove-Module $module
    # This suite creates only flat files. No recursive deletion is required.
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item
    Remove-Item -LiteralPath $testRoot
}
