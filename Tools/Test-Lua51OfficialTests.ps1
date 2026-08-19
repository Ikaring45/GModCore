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
$Target = [System.IO.Path]::GetFullPath(
    (Join-Path $RepoRoot "Sources\GModEngine\Resources\Lua51Tests")
)
$TempRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ("gmod-lua51-verify-" + [guid]::NewGuid().ToString("N"))
$Archive = Join-Path $TempRoot "lua5.1-tests.tar.gz"
$Extract = Join-Path $TempRoot "extract"

function Get-TopLevelLuaHashMap([string]$Root) {
    $map = @{}
    Get-ChildItem -LiteralPath $Root -Force -File -Filter "*.lua" | ForEach-Object {
        $map[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $map
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
        throw "Bundled suite contains unexpected recursive entries: $($details -join ', ')"
    }

    $actualNames = @($entries | ForEach-Object RelativePath | Sort-Object)
    $nameDelta = @(
        Compare-Object -ReferenceObject $ExpectedBundleNames -DifferenceObject $actualNames -CaseSensitive
    )
    if ($nameDelta.Count -ne 0) {
        throw "Bundled suite file set is incomplete or unexpected: $($nameDelta | Out-String)"
    }
}

function Assert-FileSha256([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        throw "Byte-exact SHA-256 mismatch for $Path. Expected $Expected but got $actual"
    }
}

New-Item -ItemType Directory -Path $TempRoot | Out-Null
New-Item -ItemType Directory -Path $Extract | Out-Null

try {
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        throw "Bundled official Lua 5.1 suite is missing: $Target"
    }
    Assert-ExactBundleTree -Root $Target

    Invoke-WebRequest -Uri $Url -OutFile $Archive
    $actualArchiveSha = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualArchiveSha -ne $ExpectedSha256) {
        throw "Archive SHA-256 mismatch. Expected $ExpectedSha256 but got $actualArchiveSha"
    }

    & tar.exe -xzf $Archive -C $Extract
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed with exit code $LASTEXITCODE"
    }

    $officialAllLua = Get-ChildItem -LiteralPath $Extract -Filter "all.lua" -File -Recurse |
        Select-Object -First 1
    if (-not $officialAllLua) {
        throw "Could not locate all.lua in the authenticated official archive"
    }

    $officialMap = Get-TopLevelLuaHashMap -Root $officialAllLua.Directory.FullName
    $bundledMap = Get-TopLevelLuaHashMap -Root $Target
    if ($officialMap.Count -ne 24) {
        throw "Authenticated archive has an unexpected top-level Lua file count: $($officialMap.Count)"
    }

    $officialNames = @($officialMap.Keys | Sort-Object)
    $bundledNames = @($bundledMap.Keys | Sort-Object)
    $officialNameDelta = @(
        Compare-Object -ReferenceObject $ExpectedLuaNames -DifferenceObject $officialNames -CaseSensitive
    )
    if ($officialNameDelta.Count -ne 0) {
        throw "Authenticated archive has an unexpected top-level Lua file set: $($officialNameDelta | Out-String)"
    }
    $nameDelta = @(
        Compare-Object -ReferenceObject $officialNames -DifferenceObject $bundledNames -CaseSensitive
    )
    if ($nameDelta.Count -ne 0) {
        throw "Bundled Lua file set differs from the authenticated official archive: $($nameDelta | Out-String)"
    }

    foreach ($name in $officialNames) {
        if ($bundledMap[$name] -ne $officialMap[$name]) {
            throw "Bundled Lua file differs from the authenticated official archive: $name"
        }
    }

    $officialReadme = Join-Path $officialAllLua.Directory.FullName "README"
    $bundledReadme = Join-Path $Target "OFFICIAL_README.txt"
    if (-not (Test-Path -LiteralPath $officialReadme -PathType Leaf)) {
        throw "Authenticated archive is missing its top-level README"
    }
    if (-not (Test-Path -LiteralPath $bundledReadme -PathType Leaf)) {
        throw "Bundled suite is missing OFFICIAL_README.txt"
    }
    $officialReadmeSha = (Get-FileHash -LiteralPath $officialReadme -Algorithm SHA256).Hash
    $bundledReadmeSha = (Get-FileHash -LiteralPath $bundledReadme -Algorithm SHA256).Hash
    if ($officialReadmeSha -ne $bundledReadmeSha) {
        throw "OFFICIAL_README.txt differs from the authenticated archive README"
    }

    Assert-FileSha256 -Path (Join-Path $Target "SOURCE.txt") -Expected $ExpectedSourceNoticeSha256
    Assert-FileSha256 -Path (Join-Path $Target "LUA_LICENSE.txt") -Expected $ExpectedLicenseNoticeSha256

    Write-Host "Lua 5.1 official suite verifier: PASS"
    Write-Host "Archive SHA-256: $actualArchiveSha"
    Write-Host "Exact top-level Lua files: $($officialMap.Count)"
    Write-Host "Official README and byte-exact Lua license/provenance notices: PASS"
}
finally {
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($TempRoot)
    $systemTempPrefix = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    ).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (
        $resolvedTempRoot.StartsWith($systemTempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTempRoot).StartsWith("gmod-lua51-verify-", [System.StringComparison]::Ordinal)
    ) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
