# Builds the exe and packs everything a user needs into dist\vive-webxr-bridge-<version>.zip,
# ready to attach to a GitHub release.
param([Parameter(Mandatory)][string]$Version)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
& (Join-Path $root 'build.ps1')

$name = "vive-webxr-bridge-$Version"
$stage = Join-Path $root "dist\$name"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force "$stage\src", "$stage\assets", "$stage\extensions", "$stage\docs" | Out-Null

Copy-Item (Join-Path $root 'VIVE WebXR Bridge.exe'), (Join-Path $root 'README.md'), (Join-Path $root 'LICENSE') $stage
Copy-Item (Join-Path $root 'src\*.ps1') "$stage\src"
Copy-Item (Join-Path $root 'src\webxr-fixes') "$stage\src" -Recurse
Copy-Item (Join-Path $root 'assets\icon.ico') "$stage\assets"
Copy-Item (Join-Path $root 'extensions\README.md') "$stage\extensions"
Copy-Item (Join-Path $root 'docs\*') "$stage\docs"

$zip = Join-Path $root "dist\$name.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $stage -DestinationPath $zip
Remove-Item $stage -Recurse -Force
Write-Host "Packed $zip"
