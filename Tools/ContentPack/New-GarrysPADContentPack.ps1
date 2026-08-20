[CmdletBinding()]
param(
    [string] $GModInstallRoot,

    [Parameter(Mandatory = $true)]
    [string] $OutputPath,

    [ValidateSet('Playable', 'CompleteBase')]
    [string] $Profile = 'Playable',

    [switch] $PlanOnly,

    [switch] $Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-GModInstallRoot {
    param([string] $RequestedRoot)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $candidates.Add($RequestedRoot)
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\GarrysMod'))
    }
    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Steam\steamapps\common\GarrysMod'))
    }

    foreach ($candidate in $candidates) {
        $resolved = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        $sentinel = Join-Path $resolved 'garrysmod\garrysmod_dir.vpk'
        if (Test-Path -LiteralPath $sentinel -PathType Leaf) {
            return $resolved
        }
    }

    throw 'Could not locate a Garry''s Mod install. Pass -GModInstallRoot explicitly.'
}

function Assert-OrdinaryFile {
    param([System.IO.FileInfo] $File)

    if ($File.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to package a reparse-point file: $($File.FullName)"
    }
}

function Get-RelativeChildPath {
    param(
        [string] $Root,
        [string] $Child
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar
    $resolvedChild = [System.IO.Path]::GetFullPath($Child)
    if (-not $resolvedChild.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escaped its selected root: $resolvedChild"
    }
    return $resolvedChild.Substring($resolvedRoot.Length)
}

function Convert-BytesToLowerHex {
    param([byte[]] $Bytes)

    return -join @($Bytes | ForEach-Object { $_.ToString('x2') })
}

function Add-PackFile {
    param(
        [System.Collections.Generic.Dictionary[string, object]] $Selection,
        [string] $SourcePath,
        [string] $LogicalPath
    )

    $file = Get-Item -LiteralPath $SourcePath -Force
    if ($file.PSIsContainer) {
        throw "Expected a file but found a directory: $SourcePath"
    }
    Assert-OrdinaryFile -File $file

    $logical = $LogicalPath.Replace('\', '/').TrimStart('/')
    if (
        [string]::IsNullOrWhiteSpace($logical) -or
        [System.IO.Path]::IsPathRooted($logical) -or
        $logical -match '(^|/)\.\.(/|$)'
    ) {
        throw "Unsafe logical path: $LogicalPath"
    }
    if ($Selection.ContainsKey($logical)) {
        throw "Case-insensitive duplicate logical path: $logical"
    }
    $Selection.Add($logical, $file)
}

function Add-PackDirectory {
    param(
        [System.Collections.Generic.Dictionary[string, object]] $Selection,
        [string] $SourceRoot,
        [string] $LogicalRoot
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        return
    }
    $rootItem = Get-Item -LiteralPath $SourceRoot -Force
    if ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to package a reparse-point directory: $SourceRoot"
    }

    $entries = @(Get-ChildItem -LiteralPath $SourceRoot -Force -Recurse)
    $reparseEntries = @(
        $entries | Where-Object {
            $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
        }
    )
    if ($reparseEntries.Count -ne 0) {
        throw "Selected directory contains a reparse point: $($reparseEntries[0].FullName)"
    }

    foreach ($file in @($entries | Where-Object { -not $_.PSIsContainer })) {
        $relative = Get-RelativeChildPath -Root $SourceRoot -Child $file.FullName
        Add-PackFile `
            -Selection $Selection `
            -SourcePath $file.FullName `
            -LogicalPath "$LogicalRoot/$relative"
    }
}

function Add-MatchingRootFiles {
    param(
        [System.Collections.Generic.Dictionary[string, object]] $Selection,
        [string] $SourceRoot,
        [string] $LogicalRoot,
        [string[]] $Patterns
    )

    foreach ($pattern in $Patterns) {
        foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -File -Force -Filter $pattern)) {
            Add-PackFile `
                -Selection $Selection `
                -SourcePath $file.FullName `
                -LogicalPath "$LogicalRoot/$($file.Name)"
        }
    }
}

function New-PackSelection {
    param(
        [string] $InstallRoot,
        [string] $SelectedProfile
    )

    $selection = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $garrysmod = Join-Path $InstallRoot 'garrysmod'
    $sourceengine = Join-Path $InstallRoot 'sourceengine'
    $platform = Join-Path $InstallRoot 'platform'

    # Loose, Valve/GMod-provided content roots. Deliberately excluded roots are
    # listed in the generated manifest and never discovered recursively.
    foreach ($directory in @(
        'backgrounds',
        'gamemodes',
        'html',
        'lua',
        'materials',
        'media',
        'particles',
        'resource',
        'scenes'
    )) {
        Add-PackDirectory `
            -Selection $selection `
            -SourceRoot (Join-Path $garrysmod $directory) `
            -LogicalRoot "garrysmod/$directory"
    }

    foreach ($relativePath in @(
        'maps/gm_construct.bsp',
        'maps/gm_construct.nav',
        'maps/graphs/gm_construct.ain',
        'maps/gm_flatgrass.bsp',
        'maps/gm_flatgrass.nav',
        'maps/graphs/gm_flatgrass.ain'
    )) {
        $source = Join-Path $garrysmod $relativePath.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required stock map payload is missing: $relativePath"
        }
        Add-PackFile `
            -Selection $selection `
            -SourcePath $source `
            -LogicalPath "garrysmod/$relativePath"
    }

    foreach ($name in @(
        'detail.vbsp',
        'gameinfo.txt',
        'garrysmod.ver',
        'lights.rad',
        'steam.inf'
    )) {
        $source = Join-Path $garrysmod $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Add-PackFile -Selection $selection -SourcePath $source -LogicalPath "garrysmod/$name"
        }
    }

    Add-MatchingRootFiles `
        -Selection $selection `
        -SourceRoot $garrysmod `
        -LogicalRoot 'garrysmod' `
        -Patterns @('garrysmod_*.vpk', 'fallbacks_*.vpk')

    foreach ($directory in @('resource', 'scripts')) {
        Add-PackDirectory `
            -Selection $selection `
            -SourceRoot (Join-Path $sourceengine $directory) `
            -LogicalRoot "sourceengine/$directory"
    }
    Add-MatchingRootFiles `
        -Selection $selection `
        -SourceRoot $sourceengine `
        -LogicalRoot 'sourceengine' `
        -Patterns @(
            'content_hl2_*.vpk',
            'hl2_misc_*.vpk',
            'hl2_sound_misc_*.vpk',
            'hl2_textures_*.vpk'
        )

    foreach ($directory in @('resource', 'vgui')) {
        Add-PackDirectory `
            -Selection $selection `
            -SourceRoot (Join-Path $platform $directory) `
            -LogicalRoot "platform/$directory"
    }
    Add-MatchingRootFiles `
        -Selection $selection `
        -SourceRoot $platform `
        -LogicalRoot 'platform' `
        -Patterns @('platform_misc_*.vpk')

    if ($SelectedProfile -eq 'CompleteBase') {
        Add-MatchingRootFiles `
            -Selection $selection `
            -SourceRoot $sourceengine `
            -LogicalRoot 'sourceengine' `
            -Patterns @('content_cstrike_*.vpk', 'hl2_sound_vo_english_*.vpk')
    }

    return $selection
}

function Get-CompressionLevel {
    param([string] $LogicalPath)

    $extension = [System.IO.Path]::GetExtension($LogicalPath).ToLowerInvariant()
    if ($extension -in @('.txt', '.lua', '.html', '.css', '.js', '.res', '.vdf', '.json')) {
        return [System.IO.Compression.CompressionLevel]::Optimal
    }
    return [System.IO.Compression.CompressionLevel]::NoCompression
}

function Add-FileToArchive {
    param(
        [System.IO.Compression.ZipArchive] $Archive,
        [System.IO.FileInfo] $Source,
        [string] $LogicalPath
    )

    $entry = $Archive.CreateEntry($LogicalPath, (Get-CompressionLevel -LogicalPath $LogicalPath))
    $entry.LastWriteTime = [System.DateTimeOffset]::new($Source.LastWriteTimeUtc)
    $input = [System.IO.File]::Open(
        $Source.FullName,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $output = $entry.Open()
    $hasher = [System.Security.Cryptography.IncrementalHash]::CreateHash(
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $buffer = [byte[]]::new(4MB)
    try {
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $read)
            $output.Write($buffer, 0, $read)
        }
        $hash = Convert-BytesToLowerHex -Bytes $hasher.GetHashAndReset()
    }
    finally {
        $hasher.Dispose()
        $output.Dispose()
        $input.Dispose()
    }

    return [ordered]@{
        path = $LogicalPath
        byteCount = [int64] $Source.Length
        sha256 = $hash
    }
}

$installRoot = Resolve-GModInstallRoot -RequestedRoot $GModInstallRoot
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$installPrefix = $installRoot + [System.IO.Path]::DirectorySeparatorChar
if ($resolvedOutput.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The content pack must be written outside the Garry''s Mod installation.'
}
if ([System.IO.Path]::GetExtension($resolvedOutput) -cne '.zip') {
    throw 'OutputPath must end in .zip.'
}

$selection = New-PackSelection -InstallRoot $installRoot -SelectedProfile $Profile
$orderedPaths = @($selection.Keys | Sort-Object)
$totalBytes = [int64] 0
foreach ($path in $orderedPaths) {
    $totalBytes += [int64] $selection[$path].Length
}

Write-Host "Garry's PAD content pack plan"
Write-Host "Profile: $Profile"
Write-Host "Files: $($orderedPaths.Count)"
Write-Host "Source bytes: $totalBytes"
Write-Host 'Excluded: addons, cache, cfg, data, demos, downloadlists, dupes, saves, screenshots, settings, Workshop/download content, logs, databases, user configuration, and unlisted loose maps'

if ($PlanOnly) {
    return
}

$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
if (Test-Path -LiteralPath $resolvedOutput) {
    if (-not $Overwrite) {
        throw "Output already exists. Pass -Overwrite to replace it: $resolvedOutput"
    }
    $existing = Get-Item -LiteralPath $resolvedOutput -Force
    if ($existing.PSIsContainer -or ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to replace a directory or reparse point: $resolvedOutput"
    }
}

Add-Type -AssemblyName System.IO.Compression
$partialPath = "$resolvedOutput.partial-$([guid]::NewGuid().ToString('N'))"
$stream = $null
$archive = $null
try {
    $stream = [System.IO.File]::Open(
        $partialPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $archive = [System.IO.Compression.ZipArchive]::new(
        $stream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $true
    )

    $manifestFiles = [System.Collections.Generic.List[object]]::new()
    $completedBytes = [int64] 0
    $index = 0
    foreach ($path in $orderedPaths) {
        $index += 1
        $file = [System.IO.FileInfo] $selection[$path]
        $manifestFiles.Add((Add-FileToArchive -Archive $archive -Source $file -LogicalPath $path))
        $completedBytes += $file.Length
        if ($index -eq 1 -or $index % 100 -eq 0 -or $index -eq $orderedPaths.Count) {
            $percent = if ($totalBytes -eq 0) { 100 } else {
                [Math]::Round(($completedBytes * 100.0) / $totalBytes, 1)
            }
            Write-Host "Packed $index/$($orderedPaths.Count) files ($percent%)"
        }
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        format = 'GarrysPADContentPack'
        profile = $Profile
        createdAtUTC = [DateTime]::UtcNow.ToString('o')
        source = 'User-owned Steam Garry''s Mod installation'
        mountRoots = @('garrysmod', 'platform', 'sourceengine')
        excludedRoots = @(
            'garrysmod/addons',
            'garrysmod/cache',
            'garrysmod/cfg',
            'garrysmod/data',
            'garrysmod/demos',
            'garrysmod/downloadlists',
            'garrysmod/dupes',
            'garrysmod/saves',
            'garrysmod/screenshots',
            'garrysmod/settings',
            'Workshop and download content',
            'logs, databases, user configuration, and unlisted loose maps'
        )
        optionalCompleteBaseFamilies = @(
            'sourceengine/content_cstrike_*.vpk',
            'sourceengine/hl2_sound_vo_english_*.vpk'
        )
        fileCount = $manifestFiles.Count
        byteCount = $totalBytes
        files = $manifestFiles
    }
    $json = $manifest | ConvertTo-Json -Depth 6
    $manifestEntry = $archive.CreateEntry(
        'GarrysPADContentManifest.json',
        [System.IO.Compression.CompressionLevel]::Optimal
    )
    $manifestStream = $manifestEntry.Open()
    $writer = [System.IO.StreamWriter]::new(
        $manifestStream,
        [System.Text.UTF8Encoding]::new($false),
        65536,
        $false
    )
    try {
        $writer.Write($json)
    }
    finally {
        $writer.Dispose()
    }

    $archive.Dispose()
    $archive = $null
    $stream.Dispose()
    $stream = $null
    Move-Item -LiteralPath $partialPath -Destination $resolvedOutput -Force
}
catch {
    if ($archive) { $archive.Dispose() }
    if ($stream) { $stream.Dispose() }
    if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
    }
    throw
}

$zipFile = Get-Item -LiteralPath $resolvedOutput
$zipHash = (Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "Content pack created: $resolvedOutput"
Write-Host "ZIP bytes: $($zipFile.Length)"
Write-Host "ZIP SHA-256: $zipHash"
