param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$Url = "https://www.lua.org/tests/lua5.1-tests.tar.gz"
$ExpectedSha256 = "49e4ca6561f82ea605908c5041ab5fad66ed9930fa0686675bd51b02767f18ad"
$Target = Join-Path $RepoRoot "Sources\GModApp\Resources\Lua51Tests"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gmod-lua51-tests-" + [guid]::NewGuid().ToString("N"))
$Archive = Join-Path $TempRoot "lua5.1-tests.tar.gz"
$Extract = Join-Path $TempRoot "extract"

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
New-Item -ItemType Directory -Force -Path $Extract | Out-Null

try {
    Write-Host "Downloading official Lua 5.1 test suite..."
    Invoke-WebRequest -Uri $Url -OutFile $Archive

    $ActualSha256 = (Get-FileHash -Path $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "SHA-256 mismatch. Expected $ExpectedSha256 but got $ActualSha256"
    }

    Write-Host "SHA-256 OK: $ActualSha256"
    Write-Host "Extracting..."
    & tar.exe -xzf $Archive -C $Extract
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed with exit code $LASTEXITCODE"
    }

    $AllLua = Get-ChildItem -Path $Extract -Filter "all.lua" -File -Recurse | Select-Object -First 1
    if (-not $AllLua) {
        throw "Could not locate all.lua in the official test archive"
    }

    $SourceDir = $AllLua.Directory.FullName

    if (Test-Path $Target) {
        Remove-Item -Path $Target -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Target | Out-Null

    # The official basic suite (_U=true) is driven by the top-level Lua files.
    # Copy all top-level .lua files, including checktable.lua and all.lua.
    Get-ChildItem -Path $SourceDir -File -Filter "*.lua" |
        Copy-Item -Destination $Target -Force

    $Readme = Join-Path $SourceDir "README"
    if (Test-Path $Readme) {
        Copy-Item -Path $Readme -Destination (Join-Path $Target "OFFICIAL_README.txt") -Force
    }

    @"
Official Lua 5.1 test suite
Source: $Url
SHA-256: $ExpectedSha256
Official test-suite page: https://www.lua.org/tests/
Installed by: Tools/Install-Lua51OfficialTests.ps1

The Lua test suite is distributed under the Lua MIT license.
See https://www.lua.org/license.html
"@ | Set-Content -Path (Join-Path $Target "SOURCE.txt") -Encoding UTF8

    $Count = (Get-ChildItem -Path $Target -File -Filter "*.lua").Count
    Write-Host "Installed $Count Lua test files into:"
    Write-Host "  $Target"
    Write-Host "Done. Commit/push these files, create the next tag, and update Swift Playgrounds."
}
finally {
    if (Test-Path $TempRoot) {
        Remove-Item -Path $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
