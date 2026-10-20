#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root 'docs\downloads'
$null = New-Item -ItemType Directory -Path $output -Force
$name = 'delta-force-vbs-fix-2.0.0.zip'
$archivePath = Join-Path $output $name
$temporary = Join-Path $output ([guid]::NewGuid().ToString('N') + '.tmp')
$files = @('diagnose-vbs.bat', 'fix-vbs.bat', 'restore-vbs.bat', 'README.md', 'CHANGELOG.md', 'LICENSE', 'docs/index.html')
foreach ($folder in @('scripts', 'tests', 'docs/assets')) {
    $files += @(Get-ChildItem -LiteralPath (Join-Path $root $folder) -File -Recurse | ForEach-Object {
        $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    })
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
try {
    $zip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in ($files | Sort-Object -Unique)) {
            $source = Join-Path $root $relative
            if ($relative -match '\.ps(m)?1$') {
                $tokens = $null; $parseErrors = $null
                $null = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
                if ($parseErrors.Count) { throw "PowerShell syntax errors: $relative" }
                $bytes = [IO.File]::ReadAllBytes($source)
                if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw "UTF-8 BOM required: $relative" }
            }
            $entry = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2026, 10, 20, 0, 0, 0, [TimeSpan]::Zero)
            $sourceStream = [IO.File]::OpenRead($source)
            try {
                $targetStream = $entry.Open()
                try { $sourceStream.CopyTo($targetStream) } finally { $targetStream.Dispose() }
            } finally { $sourceStream.Dispose() }
        }
    } finally { $zip.Dispose() }
    if (Test-Path -LiteralPath $archivePath) { [IO.File]::Replace($temporary, $archivePath, [Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temporary, $archivePath) }
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $output 'delta-force-vbs-fix-2.0.0.sha256') -Value "$hash *$name" -Encoding ASCII
Write-Host "Built $archivePath"
Write-Host "SHA256 $hash"
