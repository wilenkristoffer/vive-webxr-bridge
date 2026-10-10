# Builds "VIVE WebXR Bridge.exe" from launcher\Launcher.cs, using the C# compiler included with the
# .NET Framework on every Windows 10/11 PC. Nothing needs to be installed.
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "C# compiler not found at $csc" }

$out = Join-Path $PSScriptRoot 'VIVE WebXR Bridge.exe'
& $csc /nologo /target:winexe /optimize+ "/win32icon:$(Join-Path $PSScriptRoot 'assets\icon.ico')" `
    /reference:System.Windows.Forms.dll "/out:$out" (Join-Path $PSScriptRoot 'launcher\Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
Write-Host "Built $out"
