[CmdletBinding()]
param(
    [string] $GModRoot
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resourceRoot = Join-Path $repositoryRoot 'Sources/GModGameAssets/Resources'
$contentRoot = Join-Path $resourceRoot 'ClientContent'
$manifestPath = Join-Path $resourceRoot 'GModClientContentManifest.json'
$sourceMaterialAllowlistPath = Join-Path $resourceRoot 'GModSourceMaterialAllowlist.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sourceMaterialAllowlist = Get-Content -LiteralPath $sourceMaterialAllowlistPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

if ([int] $manifest.formatVersion -ne 1) {
    throw "Unsupported GMod client-content manifest version: $($manifest.formatVersion)"
}
$files = @($manifest.files)
if ([int] $manifest.fileCount -ne $files.Count) {
    throw 'Manifest fileCount does not match its entries'
}
if ([int] $manifest.fileCount -ne 2162 -or [int64] $manifest.byteCount -ne 14689206) {
    throw 'Unexpected authorized client-content inventory size'
}
$scope = [string] $manifest.sourceScope
$expectedScope = (
    "Project-authorized base Garry's Mod lua/, gamemodes/base/, " +
    "gamemodes/sandbox/, all materials/**/*.png entries, and the exact " +
    "generated GModSourceMaterialAllowlist.json VMT/VTF closure from " +
    "garrysmod/garrysmod_dir.vpk and platform/platform_misc_dir.vpk; " +
    "Workshop, cache, addons, downloads, and all other VPK content excluded."
)
if ($scope -cne $expectedScope) {
    throw 'Manifest sourceScope does not match the authorized bundle boundary'
}

if ([int] $sourceMaterialAllowlist.schemaVersion -ne 2 -or
    [int] $sourceMaterialAllowlist.fileCount -ne 118 -or
    [int64] $sourceMaterialAllowlist.byteCount -ne 3013414 -or
    [int] $sourceMaterialAllowlist.vmtCount -ne 72 -or
    [int] $sourceMaterialAllowlist.vtfCount -ne 46 -or
    [int64] $sourceMaterialAllowlist.decodedMip0ByteCount -ne 8075776) {
    throw 'Unexpected Source material allowlist contract'
}
$expectedSourceArchives = @(
    'garrysmod/garrysmod_dir.vpk',
    'platform/platform_misc_dir.vpk'
)
if ((@($sourceMaterialAllowlist.sourceArchives) -join '|') -cne
    ($expectedSourceArchives -join '|')) {
    throw 'Source material provenance archives do not match the exact release scope'
}
$expectedSelectionCriterion = (
    'Generated from bundled stock Lua literal Material/SetImage/SetMaterial roots ' +
    'present in garrysmod/garrysmod_dir.vpk and every literal surface.GetTextureID ' +
    'root in the exact garrysmod then platform VPK precedence, plus recursively ' +
    'existing Patch includes and resolved $basetexture VTFs. Dynamic and missing ' +
    'dependencies remain explicit.'
)
if ([string] $sourceMaterialAllowlist.selectionCriterion -cne $expectedSelectionCriterion) {
    throw 'Source material selection criterion does not match the release contract'
}
$sourceMaterialEntries = @($sourceMaterialAllowlist.assets)
$sourceMaterialByPath = @{}
foreach ($sourceEntry in $sourceMaterialEntries) {
    $sourcePath = [string] $sourceEntry.logicalPath
    if ($sourceMaterialByPath.ContainsKey($sourcePath)) {
        throw "Duplicate Source material allowlist path: $sourcePath"
    }
    if ([string] $sourceEntry.sourceArchive -cnotin $expectedSourceArchives) {
        throw "Source material entry has undeclared provenance: $sourcePath"
    }
    $sourceMaterialByPath[$sourcePath] = $sourceEntry
}

$surfacePattern = '(?im)\bsurface\s*\.\s*GetTextureID\s*\(\s*(?<quote>["\x27])(?<value>[^"\x27\r\n]+)\k<quote>'
$literalSurfacePaths = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::Ordinal
)
foreach ($luaFile in Get-ChildItem -LiteralPath $contentRoot -Recurse -File -Filter '*.lua') {
    $source = Get-Content -LiteralPath $luaFile.FullName -Raw -Encoding UTF8
    foreach ($match in [regex]::Matches($source, $surfacePattern)) {
        $value = $match.Groups['value'].Value.Trim().Replace('\', '/').ToLowerInvariant()
        if ($value.StartsWith('materials/')) { $value = $value.Substring('materials/'.Length) }
        if ($value.EndsWith('.vmt')) { $value = $value.Substring(0, $value.Length - 4) }
        if ([string]::IsNullOrWhiteSpace($value) -or
            $value.StartsWith('/') -or $value.Contains(':') -or
            $value.Contains('//') -or $value.Split('/') -contains '..') {
            throw "Unsafe literal surface.GetTextureID dependency: $($match.Groups['value'].Value)"
        }
        [void] $literalSurfacePaths.Add('materials/' + $value + '.vmt')
    }
}
$allowlistedSurfacePaths = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::Ordinal
)
foreach ($surfacePath in @($sourceMaterialAllowlist.surfaceTextureMaterialPaths)) {
    if (-not $allowlistedSurfacePaths.Add([string] $surfacePath) -or
        -not $sourceMaterialByPath.ContainsKey([string] $surfacePath)) {
        throw "Invalid surface.GetTextureID material allowlist entry: $surfacePath"
    }
}
if (-not $literalSurfacePaths.SetEquals($allowlistedSurfacePaths)) {
    throw 'Bundled literal surface.GetTextureID dependency set does not match the allowlist'
}

$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$seenCaseFolded = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::OrdinalIgnoreCase
)
$expectedRelativePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$totalBytes = [int64] 0
$materialBytes = [int64] 0
$materialCount = 0
$sourceMaterialCount = 0
$sourceMaterialBytes = [int64] 0
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
            $logicalPath.EndsWith('.png', [StringComparison]::OrdinalIgnoreCase)) -or
        $sourceMaterialByPath.ContainsKey($logicalPath)
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
    if ($sourceMaterialByPath.ContainsKey($logicalPath)) {
        $allowlisted = $sourceMaterialByPath[$logicalPath]
        if ([int64] $allowlisted.byteCount -ne $bundledFile.Length -or
            [string] $allowlisted.sha256 -cne $sha256) {
            throw "Bundled Source material differs from exact allowlist: $logicalPath"
        }
        $sourceMaterialCount += 1
        $sourceMaterialBytes += $bundledFile.Length
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
if ($materialCount -ne 1698 -or $materialBytes -ne 12369996) {
    throw 'Bundled base-VPK material inventory does not match the authorized scope'
}
if ($sourceMaterialCount -ne 118 -or $sourceMaterialBytes -ne 3013414) {
    throw 'Bundled Source material closure does not exactly match the allowlist'
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

function Read-VPKCString([IO.BinaryReader] $Reader) {
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    while ($true) {
        $value = $Reader.ReadByte()
        if ($value -eq 0) { break }
        $bytes.Add($value)
    }
    return [Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function Test-InstalledSourceMaterialVPK(
    [string] $DirectoryVPK,
    [hashtable] $ExpectedByPath
) {
    $stream = [IO.File]::Open($DirectoryVPK, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream)
    $found = @{}
    try {
        if ($reader.ReadUInt32() -ne 0x55AA1234) { throw 'Invalid installed VPK signature' }
        $version = $reader.ReadUInt32()
        $treeSize = [uint64] $reader.ReadUInt32()
        if ($version -eq 1) { $headerSize = [uint64] 12 }
        elseif ($version -eq 2) {
            [void] $reader.ReadUInt32(); [void] $reader.ReadUInt32()
            [void] $reader.ReadUInt32(); [void] $reader.ReadUInt32()
            $headerSize = [uint64] 28
        } else { throw "Unsupported installed VPK version: $version" }

        while ($true) {
            $extension = Read-VPKCString $reader
            if ($extension.Length -eq 0) { break }
            while ($true) {
                $directory = Read-VPKCString $reader
                if ($directory.Length -eq 0) { break }
                while ($true) {
                    $name = Read-VPKCString $reader
                    if ($name.Length -eq 0) { break }
                    [void] $reader.ReadUInt32()
                    $preloadCount = [int] $reader.ReadUInt16()
                    $archiveIndex = $reader.ReadUInt16()
                    $entryOffset = $reader.ReadUInt32()
                    $entryLength = $reader.ReadUInt32()
                    if ($reader.ReadUInt16() -ne 0xFFFF) { throw 'Invalid installed VPK entry terminator' }
                    $preload = $reader.ReadBytes($preloadCount)
                    if ($preload.Length -ne $preloadCount) { throw 'Truncated installed VPK preload data' }
                    $prefix = if ($directory -eq ' ') { '' } else { $directory + '/' }
                    $logicalPath = $prefix + $name + '.' + $extension
                    if ($ExpectedByPath.ContainsKey($logicalPath)) {
                        $found[$logicalPath] = [pscustomobject]@{
                            archiveIndex = $archiveIndex
                            offset = [uint64] $entryOffset
                            length = [int] $entryLength
                            preload = [byte[]] $preload
                        }
                    }
                }
            }
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }

    if ($found.Count -ne $ExpectedByPath.Count) {
        $missing = @($ExpectedByPath.Keys | Where-Object { -not $found.ContainsKey($_) })
        throw "Installed VPK lacks exact Source material entries: $($missing -join ', ')"
    }
    $directoryName = [IO.Path]::GetFileNameWithoutExtension($DirectoryVPK)
    $chunkStem = $directoryName.Substring(0, $directoryName.Length - '_dir'.Length)
    $chunkDirectory = Split-Path -Parent $DirectoryVPK
    foreach ($logicalPath in $ExpectedByPath.Keys) {
        $entry = $found[$logicalPath]
        if ([int] $entry.archiveIndex -eq 0x7FFF) {
            $payloadPath = $DirectoryVPK
            $payloadOffset = $headerSize + $treeSize + $entry.offset
        } else {
            $payloadPath = Join-Path $chunkDirectory (
                '{0}_{1:D3}.vpk' -f $chunkStem, [int] $entry.archiveIndex
            )
            $payloadOffset = $entry.offset
        }
        $payloadStream = [IO.File]::Open($payloadPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            [void] $payloadStream.Seek([int64] $payloadOffset, [IO.SeekOrigin]::Begin)
            $payload = New-Object byte[] $entry.length
            $read = $payloadStream.Read($payload, 0, $payload.Length)
            if ($read -ne $payload.Length) { throw "Truncated installed VPK payload: $logicalPath" }
        } finally { $payloadStream.Dispose() }
        $bytes = New-Object byte[] ($entry.preload.Length + $payload.Length)
        [Array]::Copy($entry.preload, 0, $bytes, 0, $entry.preload.Length)
        [Array]::Copy($payload, 0, $bytes, $entry.preload.Length, $payload.Length)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        $expected = $ExpectedByPath[$logicalPath]
        if ($bytes.Length -ne [int64] $expected.byteCount -or $digest -cne [string] $expected.sha256) {
            throw "Installed VPK Source material differs from allowlist: $logicalPath"
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($GModRoot)) {
    foreach ($sourceArchive in $expectedSourceArchives) {
        $expectedForArchive = @{}
        foreach ($sourceEntry in $sourceMaterialEntries) {
            if ([string] $sourceEntry.sourceArchive -ceq $sourceArchive) {
                $expectedForArchive[[string] $sourceEntry.logicalPath] = $sourceEntry
            }
        }
        $directoryVPK = Join-Path $GModRoot (
            $sourceArchive.Replace('/', [IO.Path]::DirectorySeparatorChar)
        )
        Test-InstalledSourceMaterialVPK `
            -DirectoryVPK $directoryVPK `
            -ExpectedByPath $expectedForArchive
    }
}

$summary = (
    "GMod client content verified: files={0} bytes={1} installedLooseMatches={2} " +
    "materials={3}/{4} sourceVMTVTF={5}/{6} source=exact-declared-base-vpks"
) -f $files.Count, $totalBytes, $verifiedInstalled, $materialCount, $materialBytes,
    $sourceMaterialCount, $sourceMaterialBytes
Write-Host $summary
