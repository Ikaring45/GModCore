[CmdletBinding()]
param(
    [string] $GModRoot
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resourceRoot = Join-Path $repositoryRoot 'Sources/GModGameAssets/Resources'
$contentRoot = Join-Path $resourceRoot 'ClientContent'
$manifestPath = Join-Path $resourceRoot 'GModClientContentManifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ([int] $manifest.formatVersion -ne 1) {
    throw "Unsupported GMod client-content manifest version: $($manifest.formatVersion)"
}
$files = @($manifest.files)
if ([int] $manifest.fileCount -ne $files.Count) {
    throw 'Manifest fileCount does not match its entries'
}
if ([int] $manifest.fileCount -ne 2044 -or [int64] $manifest.byteCount -ne 11675792) {
    throw 'Unexpected authorized client-content inventory size'
}
$scope = [string] $manifest.sourceScope
$expectedScope = (
    "Project-authorized base Garry's Mod lua/, gamemodes/base/, " +
    "gamemodes/sandbox/, and all materials/**/*.png entries from the base " +
    "garrysmod_dir.vpk; Workshop, cache, addons, downloads, and non-PNG " +
    "VPK material content excluded."
)
if ($scope -cne $expectedScope) {
    throw 'Manifest sourceScope does not match the authorized bundle boundary'
}

$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$seenCaseFolded = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::OrdinalIgnoreCase
)
$expectedRelativePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$totalBytes = [int64] 0
$materialBytes = [int64] 0
$materialCount = 0
$verifiedInstalled = 0
foreach ($entry in $files) {
    $logicalPath = [string] $entry.logicalPath
    if ([string]::IsNullOrWhiteSpace($logicalPath) -or
        $logicalPath.Contains('\') -or
        $logicalPath.Contains(':') -or
        $logicalPath.StartsWith('/', [StringComparison]::Ordinal) -or
        $logicalPath.Contains('/../') -or
        $logicalPath.StartsWith('../', [StringComparison]::Ordinal) -or
        $logicalPath.EndsWith('/..', [StringComparison]::Ordinal) -or
        $logicalPath.Contains('/./') -or
        $logicalPath.Contains('//')) {
        throw "Unsafe or non-canonical manifest path: $logicalPath"
    }
    if (-not $seen.Add($logicalPath)) {
        throw "Duplicate manifest path: $logicalPath"
    }
    if (-not $seenCaseFolded.Add($logicalPath)) {
        throw "Manifest path collides under Source case folding: $logicalPath"
    }
    $allowed = (
        $logicalPath.StartsWith('lua/', [StringComparison]::Ordinal) -or
        $logicalPath.StartsWith('gamemodes/base/', [StringComparison]::Ordinal) -or
        $logicalPath.StartsWith('gamemodes/sandbox/', [StringComparison]::Ordinal) -or
        ($logicalPath.StartsWith('materials/', [StringComparison]::Ordinal) -and
            $logicalPath.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase))
    )
    if (-not $allowed) {
        throw "Manifest path is outside the authorized client-content scope: $logicalPath"
    }
    $relativePath = $logicalPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    [void] $expectedRelativePaths.Add($relativePath)
    $bundledPath = Join-Path $contentRoot $relativePath
    $bundledFile = Get-Item -LiteralPath $bundledPath
    if (($bundledFile.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        throw "Manifest entry resolves to a directory: $logicalPath"
    }
    if ($bundledFile.Length -ne [int64] $entry.byteCount) {
        throw "Bundled byte-count mismatch: $logicalPath"
    }
    $sha256 = (Get-FileHash -LiteralPath $bundledPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -cne [string] $entry.sha256) {
        throw "Bundled SHA-256 mismatch: $logicalPath"
    }
    $totalBytes += $bundledFile.Length

    if ($logicalPath.StartsWith('materials/', [StringComparison]::Ordinal)) {
        $materialCount += 1
        $materialBytes += $bundledFile.Length
    }

    if (-not [string]::IsNullOrWhiteSpace($GModRoot) -and
        -not $logicalPath.StartsWith('materials/', [StringComparison]::Ordinal)) {
        $installedPath = Join-Path (Join-Path $GModRoot 'garrysmod') $relativePath
        $installedFile = Get-Item -LiteralPath $installedPath
        $installedHash = (
            Get-FileHash -LiteralPath $installedPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($installedFile.Length -ne $bundledFile.Length -or $installedHash -cne $sha256) {
            throw "Installed source differs from bundled content: $logicalPath"
        }
        $verifiedInstalled += 1
    }
}
if ($totalBytes -ne [int64] $manifest.byteCount) {
    throw 'Manifest aggregate byteCount mismatch'
}
if ($materialCount -ne 1580 -or $materialBytes -ne 9356582) {
    throw 'Bundled base-VPK PNG inventory does not match the authorized scope'
}

$actualFiles = @(
    Get-ChildItem -LiteralPath $contentRoot -Recurse -File | ForEach-Object {
        $_.FullName.Substring($contentRoot.Length + 1)
    }
)
if ($actualFiles.Count -ne $expectedRelativePaths.Count) {
    throw "Bundled file-set count differs from manifest: $($actualFiles.Count)"
}
foreach ($relativePath in $actualFiles) {
    if (-not $expectedRelativePaths.Contains($relativePath)) {
        throw "Unmanifested bundled content: $relativePath"
    }
}

$summary = (
    "GMod client content verified: files={0} bytes={1} installedLooseMatches={2} " +
    "vpkPNG={3}/{4} source=authorized-base-garrysmod_dir.vpk"
) -f $files.Count, $totalBytes, $verifiedInstalled, $materialCount, $materialBytes
Write-Host $summary
