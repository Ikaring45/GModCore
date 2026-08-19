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
$sourceScope = (
    "Project-authorized base Garry's Mod lua/, gamemodes/base/, " +
    "gamemodes/sandbox/, and all materials/**/*.png entries from the base " +
    "garrysmod_dir.vpk; Workshop, cache, addons, downloads, and non-PNG " +
    "VPK material content excluded."
)

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
            $logicalPath.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase))
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
