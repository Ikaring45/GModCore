param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$Url = "https://www.lua.org/tests/lua5.1-tests.tar.gz"
$ExpectedSha256 = "49e4ca6561f82ea605908c5041ab5fad66ed9930fa0686675bd51b02767f18ad"
$ExpectedSourceNoticeSha256 = "920dc883f2f498c6c1ae6ac2d802d1be6bc8f2906ce501016bdb9ee4018af498"
$ExpectedLicenseNoticeSha256 = "628b32719907ab28d2e22031a9388e1e90c4ab3da5d45f3c1fb106d4dd9f078e"
$ExpectedLuaNames = @(
    "all.lua",
    "api.lua",
    "attrib.lua",
    "big.lua",
    "calls.lua",
    "checktable.lua",
    "closure.lua",
    "code.lua",
    "constructs.lua",
    "db.lua",
    "errors.lua",
    "events.lua",
    "files.lua",
    "gc.lua",
    "literals.lua",
    "locals.lua",
    "main.lua",
    "math.lua",
    "nextvar.lua",
    "pm.lua",
    "sort.lua",
    "strings.lua",
    "vararg.lua",
    "verybig.lua"
)
$ExpectedBundleNames = @(
    $ExpectedLuaNames + @(
        "LUA_LICENSE.txt",
        "OFFICIAL_README.txt",
        "SOURCE.txt"
    ) | Sort-Object
)
$Target = Join-Path $RepoRoot "Sources\GModEngine\Resources\Lua51Tests"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gmod-lua51-tests-" + [guid]::NewGuid().ToString("N"))
$Archive = Join-Path $TempRoot "lua5.1-tests.tar.gz"
$Extract = Join-Path $TempRoot "extract"
$StagedBundle = Join-Path $TempRoot "bundle"

function Write-Utf8NoBomLF([string]$Path, [string]$Content) {
    $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not $normalized.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        $normalized += "`n"
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Get-RecursiveBundleEntries([string]$Root) {
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar

    Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse | ForEach-Object {
        $resolvedEntry = [System.IO.Path]::GetFullPath($_.FullName)
        if (-not $resolvedEntry.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Bundle entry escaped its expected root: $resolvedEntry"
        }

        [pscustomobject]@{
            RelativePath = $resolvedEntry.Substring($rootPrefix.Length).Replace('\', '/')
            IsDirectory = [bool]$_.PSIsContainer
            IsReparsePoint = [bool]($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        }
    }
}

function Assert-ExactBundleTree([string]$Root) {
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (
        -not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    ) {
        throw "Bundle root must be a real directory, not a file or reparse point: $Root"
    }

    $entries = @(Get-RecursiveBundleEntries -Root $Root)
    $unsafeEntries = @(
        $entries | Where-Object { $_.IsDirectory -or $_.IsReparsePoint }
    )
    if ($unsafeEntries.Count -ne 0) {
        $details = $unsafeEntries | ForEach-Object {
            if ($_.IsReparsePoint) { "$($_.RelativePath) [reparse point]" }
            else { "$($_.RelativePath) [directory]" }
        }
        throw "Staged bundle contains unexpected recursive entries: $($details -join ', ')"
    }

    $actualNames = @($entries | ForEach-Object RelativePath | Sort-Object)
    $nameDelta = @(
        Compare-Object -ReferenceObject $ExpectedBundleNames -DifferenceObject $actualNames -CaseSensitive
    )
    if ($nameDelta.Count -ne 0) {
        throw "Staged bundle file set is not exact: $($nameDelta | Out-String)"
    }
}

function Assert-FileSha256([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        throw "Byte-exact SHA-256 mismatch for $Path. Expected $Expected but got $actual"
    }
}

New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
New-Item -ItemType Directory -Force -Path $Extract | Out-Null
New-Item -ItemType Directory -Force -Path $StagedBundle | Out-Null

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

    $ArchiveLuaNames = @(
        Get-ChildItem -LiteralPath $SourceDir -Force -File -Filter "*.lua" |
            ForEach-Object Name |
            Sort-Object
    )
    $ArchiveNameDelta = @(
        Compare-Object -ReferenceObject $ExpectedLuaNames -DifferenceObject $ArchiveLuaNames -CaseSensitive
    )
    if ($ArchiveNameDelta.Count -ne 0) {
        throw "Authenticated archive has an unexpected top-level Lua file set: $($ArchiveNameDelta | Out-String)"
    }

    $ResolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $ResolvedTarget = [System.IO.Path]::GetFullPath($Target)
    $ExpectedPrefix = $ResolvedRepoRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $ResolvedTarget.StartsWith($ExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to replace a Lua test target outside the repository: $ResolvedTarget"
    }

    # The official basic suite (_U=true) is driven by the top-level Lua files.
    # Copy all top-level .lua files, including checktable.lua and all.lua.
    foreach ($name in $ExpectedLuaNames) {
        Copy-Item -LiteralPath (Join-Path $SourceDir $name) -Destination (Join-Path $StagedBundle $name) -Force
    }

    $Readme = Join-Path $SourceDir "README"
    if (-not (Test-Path -LiteralPath $Readme -PathType Leaf)) {
        throw "Authenticated archive is missing its top-level README"
    }
    Copy-Item -LiteralPath $Readme -Destination (Join-Path $StagedBundle "OFFICIAL_README.txt") -Force

    $sourceNotice = @"
Official Lua 5.1 test suite
Source: $Url
SHA-256: $ExpectedSha256
Official test-suite page: https://www.lua.org/tests/
Installed by: Tools/Install-Lua51OfficialTests.ps1

This bundle contains the byte-exact 24 top-level .lua files used by the basic
suite. The archive's libs/ and etc/ support trees are intentionally not bundled.
At execution time only, the embedded-core harness classifies the all.lua calls
to main.lua (standalone CLI) and api.lua (PUC C API); it does not edit the files.

The Lua test suite is distributed under the Lua MIT license. LUA_LICENSE.txt
reproduces the required notice.
See https://www.lua.org/license.html
"@
    Write-Utf8NoBomLF -Path (Join-Path $StagedBundle "SOURCE.txt") -Content $sourceNotice

    $licenseNotice = @"
Copyright (c) 1994-2026 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
"@
    Write-Utf8NoBomLF -Path (Join-Path $StagedBundle "LUA_LICENSE.txt") -Content $licenseNotice

    Assert-ExactBundleTree -Root $StagedBundle
    Assert-FileSha256 -Path (Join-Path $StagedBundle "SOURCE.txt") -Expected $ExpectedSourceNoticeSha256
    Assert-FileSha256 -Path (Join-Path $StagedBundle "LUA_LICENSE.txt") -Expected $ExpectedLicenseNoticeSha256

    # Validate the complete replacement before removing the prior bundle. The
    # staged copy is regenerated from the authenticated archive on every run.
    if (Test-Path -LiteralPath $ResolvedTarget) {
        $existingTarget = Get-Item -LiteralPath $ResolvedTarget -Force
        if (
            -not $existingTarget.PSIsContainer -or
            ($existingTarget.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        ) {
            throw "Refusing to replace a Lua test target that is not a real directory: $ResolvedTarget"
        }
        Remove-Item -LiteralPath $ResolvedTarget -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $ResolvedTarget | Out-Null
    Get-ChildItem -LiteralPath $StagedBundle -Force |
        Copy-Item -Destination $ResolvedTarget -Recurse -Force

    Assert-ExactBundleTree -Root $ResolvedTarget
    Assert-FileSha256 -Path (Join-Path $ResolvedTarget "SOURCE.txt") -Expected $ExpectedSourceNoticeSha256
    Assert-FileSha256 -Path (Join-Path $ResolvedTarget "LUA_LICENSE.txt") -Expected $ExpectedLicenseNoticeSha256

    $Count = (Get-ChildItem -LiteralPath $ResolvedTarget -Force -File -Filter "*.lua").Count
    Write-Host "Installed $Count Lua test files into:"
    Write-Host "  $ResolvedTarget"
    Write-Host "Done. Commit/push these files, create the next tag, and update Swift Playgrounds."
}
finally {
    if (Test-Path $TempRoot) {
        Remove-Item -Path $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
