param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.5.0',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'release')
)

$ErrorActionPreference = 'Stop'

$manifestPaths = @(
    'manifest.json',
    'Chrome Bridge\manifest.json',
    'Opera Bridge\manifest.json',
    'Entpackte Browser-Erweiterung\manifest.json'
)

foreach ($relativePath in $manifestPaths) {
    $manifestPath = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest fehlt: $relativePath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.version -ne $Version) {
        throw "Versionskonflikt in ${relativePath}: $($manifest.version) statt $Version"
    }
}

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'dynamic_island.ps1'),
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "PowerShell-Parserfehler: $($parseErrors[0].Message)"
}

$releaseEntries = @(
    'Chrome Bridge',
    'Opera Bridge',
    'Entpackte Browser-Erweiterung',
    'AI_PROJECT_CONTEXT.md',
    'build-release.ps1',
    'CHANGELOG.md',
    'dynamic_island.ps1',
    'Install-MuusyIsland.bat',
    'Install-MuusyIsland.ps1',
    'LICENSE',
    'manifest.json',
    'NativeMediaThumbnail.cs',
    'NativeMediaThumbnail.dll',
    'README.md',
    "RELEASE_AUDIT_v$Version.md",
    "RELEASE_NOTES_v$Version.md",
    'SECURITY.md',
    'start-dynamic-island.bat',
    'start-muusy-island.bat'
)

$releasePaths = foreach ($entry in $releaseEntries) {
    $path = Join-Path $PSScriptRoot $entry
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Release-Datei fehlt: $entry"
    }
    $path
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

$zipName = "Muusy-Island-v$Version.zip"
$zipPath = Join-Path $OutputDirectory $zipName
Compress-Archive -LiteralPath $releasePaths -DestinationPath $zipPath -CompressionLevel Optimal -Force

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $blocked = @(
        $archive.Entries |
            Where-Object {
                $_.FullName -match '(^|[/\\])island-settings\.json$' -or
                $_.FullName -match '(^|[/\\])\.git([/\\]|$)' -or
                $_.FullName -match '__pycache__|\.pyc$'
            }
    )
    if ($blocked.Count -gt 0) {
        throw "Private oder unerlaubte Dateien im Archiv: $($blocked.FullName -join ', ')"
    }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = Join-Path $OutputDirectory 'SHA256SUMS.txt'
[IO.File]::WriteAllText(
    $checksumPath,
    "$hash *$zipName`n",
    [Text.UTF8Encoding]::new($false)
)

Write-Host "Release archive: $zipPath"
Write-Host "SHA256: $hash"
