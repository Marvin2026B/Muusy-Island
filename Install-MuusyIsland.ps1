[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA 'Muusy Island'),
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$sourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$installRoot = [IO.Path]::GetFullPath($InstallPath)
$sourceFull = $sourceRoot.TrimEnd('\')
$installFull = $installRoot.TrimEnd('\')

if ($sourceFull -ieq $installFull) {
    throw 'Run this installer from the extracted release folder, not from the installed folder.'
}

$requiredFiles = @(
    'dynamic_island.ps1',
    'NativeMediaThumbnail.dll',
    'start-muusy-island.bat'
)

foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $file) -PathType Leaf)) {
        throw "Required release file is missing: $file"
    }
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

$excludedNames = @(
    '.git',
    'release',
    'island-settings.json',
    'SHA256SUMS.txt'
)

Get-ChildItem -LiteralPath $sourceRoot -Force |
    Where-Object { $excludedNames -notcontains $_.Name } |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $installRoot -Recurse -Force
    }

$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$mainScript = Join-Path $installRoot 'dynamic_island.ps1'
$startArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $mainScript + '"'

$startMenuRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Muusy Island'
New-Item -ItemType Directory -Path $startMenuRoot -Force | Out-Null

$shell = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path $startMenuRoot 'Muusy Island.lnk'
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = $startArguments
$shortcut.WorkingDirectory = $installRoot
$shortcut.Description = 'Start Muusy Island'
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
$shortcut.Save()

if (-not $NoStart) {
    Start-Process -FilePath $powershellPath -ArgumentList $startArguments -WorkingDirectory $installRoot -WindowStyle Hidden
}

Write-Host "Muusy Island installed to: $installRoot"
Write-Host "Start Menu shortcut: $shortcutPath"
if (-not $NoStart) {
    Write-Host 'Muusy Island has been started.'
}
