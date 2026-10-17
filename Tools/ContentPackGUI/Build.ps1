$ErrorActionPreference = 'Stop'
$destination = Join-Path $PSScriptRoot 'dist/GarrysPAD-ZIP-Builder-1.1.0-Windows'
New-Item -ItemType Directory -Force -Path (Join-Path $destination 'Scripts') | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $compiler /nologo /target:winexe /optimize+ /codepage:65001 /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/out:$destination/GarrysPAD-ZIP-Builder.exe" (Join-Path $PSScriptRoot 'Program.cs')
if ($LASTEXITCODE -ne 0) { throw 'GUI compile failed' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../ContentPack/New-GarrysPADContentPack.ps1'), (Join-Path $PSScriptRoot '../ContentPack/Test-GarrysPADContentPack.ps1') -Destination (Join-Path $destination 'Scripts')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.txt') -Destination $destination
$check = Start-Process -FilePath (Join-Path $destination 'GarrysPAD-ZIP-Builder.exe') -ArgumentList '--self-test' -PassThru -Wait -WindowStyle Hidden
if ($check.ExitCode -ne 0) { throw "GUI self-test failed: $($check.ExitCode)" }
Compress-Archive -LiteralPath $destination -DestinationPath (Join-Path $PSScriptRoot 'dist/GarrysPAD-ZIP-Builder-1.1.0-Windows.zip') -Force
Get-FileHash (Join-Path $PSScriptRoot 'dist/GarrysPAD-ZIP-Builder-1.1.0-Windows.zip') -Algorithm SHA256
