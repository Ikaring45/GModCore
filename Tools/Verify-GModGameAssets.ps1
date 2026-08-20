[CmdletBinding()]
param(
    [string] $GModRoot
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$resourceRoot = Join-Path $repositoryRoot 'Sources/GModGameAssets/Resources'
$manifestPath = Join-Path $resourceRoot 'GModGameAssetManifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ([int] $manifest.schemaVersion -ne 1) {
    throw "Unsupported GMod game asset manifest schema: $($manifest.schemaVersion)"
}

$verified = 0
foreach ($asset in @($manifest.assets)) {
    $logicalPath = [string] $asset.logicalPath
    if (-not $logicalPath.StartsWith('maps/', [StringComparison]::Ordinal)) {
        throw "Manifest path is outside maps/: $logicalPath"
    }

    $mapRelativePath = $logicalPath.Substring('maps/'.Length).Replace('/', '\')
    $bundledPath = Join-Path (Join-Path $resourceRoot 'Maps') $mapRelativePath
    $bundledFile = Get-Item -LiteralPath $bundledPath
    $bundledHash = (Get-FileHash -LiteralPath $bundledPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($bundledFile.Length -ne [int64] $asset.byteCount) {
        throw "Bundled byte-count mismatch for $logicalPath"
    }
    if ($bundledHash -cne [string] $asset.sha256) {
        throw "Bundled SHA-256 mismatch for $logicalPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($GModRoot)) {
        $installedPath = Join-Path (Join-Path $GModRoot 'garrysmod\maps') $mapRelativePath
        $installedFile = Get-Item -LiteralPath $installedPath
        $installedHash = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($installedFile.Length -ne $bundledFile.Length -or $installedHash -cne $bundledHash) {
            throw "Installed source differs from bundled fixture: $logicalPath"
        }
    }
    $verified += 1
}

Write-Host "GMod game asset manifest verified: $verified/$(@($manifest.assets).Count)"
