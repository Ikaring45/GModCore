[CmdletBinding()]
param(
    [Parameter()]
    [string] $GModInstallRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fontRoot = Join-Path $repoRoot 'Sources\GModApp\Resources\Fonts\GMod'
$manifestPath = Join-Path $fontRoot 'GModFonts.manifest.json'
$failures = [System.Collections.Generic.List[string]]::new()

function Test-Requirement {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

Test-Requirement (Test-Path -LiteralPath $manifestPath -PathType Leaf) `
    "Missing manifest: $manifestPath"
if ($failures.Count -gt 0) {
    throw ($failures -join [Environment]::NewLine)
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$entries = @($manifest.entries)
$uniqueBundleNames = @($entries.bundleFile | Sort-Object -Unique)
$actualFonts = @(Get-ChildItem -LiteralPath $fontRoot -File -Filter '*.ttf')

Test-Requirement ($manifest.formatVersion -eq 1) 'Unexpected manifest formatVersion.'
Test-Requirement ($manifest.sourceAliasCount -eq 30) 'sourceAliasCount must be 30.'
Test-Requirement ($manifest.bundledFileCount -eq 28) 'bundledFileCount must be 28.'
Test-Requirement ($manifest.bundledByteCount -eq 3336964) `
    'bundledByteCount must be 3336964.'
Test-Requirement ($entries.Count -eq $manifest.sourceAliasCount) `
    'Manifest entry count does not match sourceAliasCount.'
Test-Requirement (@($entries.sourceAlias | Sort-Object -Unique).Count -eq 30) `
    'Every source alias must be unique.'
Test-Requirement ($uniqueBundleNames.Count -eq $manifest.bundledFileCount) `
    'Unique bundle filename count does not match bundledFileCount.'
Test-Requirement ($actualFonts.Count -eq $manifest.bundledFileCount) `
    'The resource directory must contain exactly 28 TTF files.'
Test-Requirement ($manifest.scope -match '(?i)project-authorized') `
    'Manifest scope must record project authorization without confidential details.'

$declaredExclusions = @($manifest.exclusions | ForEach-Object {
    ([string] $_).ToLowerInvariant()
})
foreach ($requiredExclusion in @(
    'garrysmod/cache',
    'garrysmod/cache/workshop',
    'garrysmod/addons',
    'all non-font game assets'
)) {
    Test-Requirement ($declaredExclusions -contains $requiredExclusion) `
        "Manifest does not declare exclusion: $requiredExclusion"
}

foreach ($entry in $entries) {
    $sourceAlias = [string] $entry.sourceAlias
    $bundleFile = [string] $entry.bundleFile
    $allowedSource = $sourceAlias -match `
        '^(?i)(sourceengine/resource/[^/]+\.ttf|garrysmod/resource/[^/]+\.ttf|garrysmod/resource/fonts/[^/]+\.ttf)$'
    Test-Requirement $allowedSource "Out-of-scope source alias: $sourceAlias"
    Test-Requirement ($sourceAlias -notmatch '(?i)(^|/)(cache|workshop|addons)(/|$)') `
        "Excluded content appeared in source alias: $sourceAlias"
    Test-Requirement ($bundleFile -match '^[^\\/]+\.ttf$') `
        "Bundle filename must be a leaf TTF name: $bundleFile"
    Test-Requirement ([long] $entry.byteCount -gt 0) `
        "Invalid byte count for $sourceAlias"
    Test-Requirement ([string] $entry.sha256 -match '^[0-9a-f]{64}$') `
        "Invalid SHA-256 for $sourceAlias"

    foreach ($nameField in @('family', 'subfamily', 'full', 'postScript')) {
        $value = [string] $entry.fontNames.$nameField
        Test-Requirement (-not [string]::IsNullOrWhiteSpace($value)) `
            "Missing $nameField name-table value for $sourceAlias"
    }
}

foreach ($group in @($entries | Group-Object bundleFile)) {
    $first = $group.Group[0]
    foreach ($alias in @($group.Group | Select-Object -Skip 1)) {
        Test-Requirement ($alias.byteCount -eq $first.byteCount) `
            "Duplicate aliases disagree on byteCount: $($group.Name)"
        Test-Requirement ($alias.sha256 -eq $first.sha256) `
            "Duplicate aliases disagree on SHA-256: $($group.Name)"
        foreach ($nameField in @('family', 'subfamily', 'full', 'postScript')) {
            Test-Requirement `
                ($alias.fontNames.$nameField -ceq $first.fontNames.$nameField) `
                "Duplicate aliases disagree on ${nameField}: $($group.Name)"
        }
    }
}

$uniqueByteCount = [long] 0
foreach ($bundleName in $uniqueBundleNames) {
    $entry = @($entries | Where-Object bundleFile -CEQ $bundleName)[0]
    $fontPath = Join-Path $fontRoot $bundleName
    Test-Requirement (Test-Path -LiteralPath $fontPath -PathType Leaf) `
        "Missing bundled font: $bundleName"
    if (Test-Path -LiteralPath $fontPath -PathType Leaf) {
        $item = Get-Item -LiteralPath $fontPath
        $actualHash = (
            (Get-FileHash -LiteralPath $fontPath -Algorithm SHA256).Hash
        ).ToLowerInvariant()
        $uniqueByteCount += $item.Length
        Test-Requirement ($item.Length -eq [long] $entry.byteCount) `
            "Bundled byte count mismatch: $bundleName"
        Test-Requirement ($actualHash -ceq [string] $entry.sha256) `
            "Bundled SHA-256 mismatch: $bundleName"
    }
}
Test-Requirement ($uniqueByteCount -eq [long] $manifest.bundledByteCount) `
    'Actual unique bundle byte total does not match bundledByteCount.'

$declaredNames = @($uniqueBundleNames | Sort-Object)
$actualNames = @($actualFonts.Name | Sort-Object)
Test-Requirement ((Compare-Object $declaredNames $actualNames).Count -eq 0) `
    'Resource directory TTF set does not exactly match the manifest.'

if (-not [string]::IsNullOrWhiteSpace($GModInstallRoot)) {
    $resolvedInstallRoot = [IO.Path]::GetFullPath($GModInstallRoot)
    Test-Requirement (Test-Path -LiteralPath $resolvedInstallRoot -PathType Container) `
        "GMod install root does not exist: $resolvedInstallRoot"
    if (Test-Path -LiteralPath $resolvedInstallRoot -PathType Container) {
        foreach ($entry in $entries) {
            $relativeSource = ([string] $entry.sourceAlias).Replace(
                '/',
                [IO.Path]::DirectorySeparatorChar
            )
            $sourcePath = Join-Path $resolvedInstallRoot $relativeSource
            Test-Requirement (Test-Path -LiteralPath $sourcePath -PathType Leaf) `
                "Installed source alias is missing: $($entry.sourceAlias)"
            if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
                $sourceItem = Get-Item -LiteralPath $sourcePath
                $sourceHash = (
                    (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
                ).ToLowerInvariant()
                Test-Requirement ($sourceItem.Length -eq [long] $entry.byteCount) `
                    "Installed source byte count mismatch: $($entry.sourceAlias)"
                Test-Requirement ($sourceHash -ceq [string] $entry.sha256) `
                    "Installed source SHA-256 mismatch: $($entry.sourceAlias)"
            }
        }
    }
}

if ($failures.Count -gt 0) {
    throw ("GMod font bundle validation failed:`n- " + ($failures -join "`n- "))
}

Write-Output (
    'PASS: 30 source aliases, 28 unique TTF files, {0} bytes; manifest hashes match.' `
        -f $uniqueByteCount
)
