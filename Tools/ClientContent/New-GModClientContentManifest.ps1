[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or newer is required for canonical JSON generation'
}
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resourceRoot = Join-Path $repositoryRoot 'Sources/GModGameAssets/Resources'
$contentRoot = Join-Path $resourceRoot 'ClientContent'
$manifestPath = Join-Path $resourceRoot 'GModClientContentManifest.json'
$sourceMaterialAllowlistPath = Join-Path $resourceRoot 'GModSourceMaterialAllowlist.json'
$sourceMaterialAllowlist = Get-Content -LiteralPath $sourceMaterialAllowlistPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$sourceScope = (
    "Project-authorized base Garry's Mod lua/, gamemodes/base/, " +
    "gamemodes/sandbox/, all materials/**/*.png entries, and the exact " +
    "generated GModSourceMaterialAllowlist.json VMT/VTF closure from " +
    "garrysmod/garrysmod_dir.vpk and platform/platform_misc_dir.vpk; " +
    "Workshop, cache, addons, downloads, and all other VPK content excluded."
)

if ([int] $sourceMaterialAllowlist.schemaVersion -ne 2 -or
    [int] $sourceMaterialAllowlist.fileCount -ne 118 -or
    [int64] $sourceMaterialAllowlist.byteCount -ne 3013414 -or
    [int] $sourceMaterialAllowlist.vmtCount -ne 72 -or
    [int] $sourceMaterialAllowlist.vtfCount -ne 46) {
    throw 'Unexpected Source material allowlist contract'
}
$sourceMaterialEntries = @($sourceMaterialAllowlist.assets)
$sourceMaterialPaths = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::Ordinal
)
foreach ($entry in $sourceMaterialEntries) {
    if (-not $sourceMaterialPaths.Add([string] $entry.logicalPath)) {
        throw "Duplicate Source material allowlist path: $($entry.logicalPath)"
    }
}

$logicalPaths = [string[]] @(
    Get-ChildItem -LiteralPath $contentRoot -Recurse -File | ForEach-Object {
        $_.FullName.Substring($contentRoot.Length + 1).Replace('\', '/')
    }
)
[Array]::Sort($logicalPaths, [StringComparer]::Ordinal)

$files = New-Object 'System.Collections.Generic.List[object]'
$seenCaseFolded = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::OrdinalIgnoreCase
)
$byteCount = [int64] 0
foreach ($logicalPath in $logicalPaths) {
    if (-not $seenCaseFolded.Add($logicalPath)) {
        throw "Content path collides under Source case folding: $logicalPath"
    }
    $allowed = (
        $logicalPath.StartsWith('lua/', [StringComparison]::Ordinal) -or
        $logicalPath.StartsWith('gamemodes/base/', [StringComparison]::Ordinal) -or
        $logicalPath.StartsWith('gamemodes/sandbox/', [StringComparison]::Ordinal) -or
        ($logicalPath.StartsWith('materials/', [StringComparison]::Ordinal) -and
            $logicalPath.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase)) -or
        $sourceMaterialPaths.Contains($logicalPath)
    )
    if (-not $allowed) {
        throw "Content is outside the authorized manifest scope: $logicalPath"
    }
    $path = Join-Path $contentRoot $logicalPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $files.Add([ordered] @{
        logicalPath = $logicalPath
        byteCount = [int64] $item.Length
        sha256 = $hash
    })
    $byteCount += $item.Length
}

foreach ($allowlisted in $sourceMaterialEntries) {
    $generated = @($files | Where-Object {
        $_.logicalPath -ceq [string] $allowlisted.logicalPath
    })
    if ($generated.Count -ne 1 -or
        [int64] $generated[0].byteCount -ne [int64] $allowlisted.byteCount -or
        [string] $generated[0].sha256 -cne [string] $allowlisted.sha256) {
        throw "Bundled Source material differs from exact allowlist: $($allowlisted.logicalPath)"
    }
}

$manifest = [ordered] @{
    formatVersion = 1
    sourceScope = $sourceScope
    fileCount = $files.Count
    byteCount = $byteCount
    files = $files
}
$json = $manifest | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText(
    $manifestPath,
    $json + [Environment]::NewLine,
    (New-Object Text.UTF8Encoding($false))
)
Write-Host "Wrote client-content manifest: files=$($files.Count) bytes=$byteCount"
