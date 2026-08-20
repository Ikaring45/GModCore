[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $GModRoot,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or newer is required for canonical JSON generation'
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$resourceRoot = Join-Path $repositoryRoot 'Sources/GModGameAssets/Resources'
$contentRoot = Join-Path $resourceRoot 'ClientContent'
$allowlistPath = Join-Path $resourceRoot 'GModSourceMaterialAllowlist.json'
$archiveRelativePaths = @(
    'garrysmod/garrysmod_dir.vpk',
    'platform/platform_misc_dir.vpk'
)

$maximumVMTBytes = 1MB
$maximumVTFBytes = 16MB
$maximumTextureDimension = 4096
$maximumTexturePixels = 2097152
$maximumDecodedBytes = 8MB

function Read-VPKCString([IO.BinaryReader] $Reader) {
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    while ($true) {
        $value = $Reader.ReadByte()
        if ($value -eq 0) { break }
        $bytes.Add($value)
    }
    return [Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function Read-VPKIndex([string] $DirectoryVPK, [string] $SourceArchive) {
    $stream = [IO.File]::Open(
        $DirectoryVPK,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    $reader = New-Object IO.BinaryReader($stream)
    $entries = @{}
    try {
        if ($reader.ReadUInt32() -ne 0x55AA1234) {
            throw "Invalid VPK signature: $SourceArchive"
        }
        $version = $reader.ReadUInt32()
        $treeSize = [uint64] $reader.ReadUInt32()
        if ($version -eq 1) {
            $headerSize = [uint64] 12
        } elseif ($version -eq 2) {
            [void] $reader.ReadUInt32()
            [void] $reader.ReadUInt32()
            [void] $reader.ReadUInt32()
            [void] $reader.ReadUInt32()
            $headerSize = [uint64] 28
        } else {
            throw "Unsupported VPK version ${version}: $SourceArchive"
        }

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
                    if ($reader.ReadUInt16() -ne 0xFFFF) {
                        throw "Invalid VPK entry terminator: $SourceArchive"
                    }
                    $preload = $reader.ReadBytes($preloadCount)
                    if ($preload.Length -ne $preloadCount) {
                        throw "Truncated VPK preload data: $SourceArchive"
                    }
                    $prefix = if ($directory -eq ' ') { '' } else { $directory + '/' }
                    $logicalPath = ($prefix + $name + '.' + $extension).ToLowerInvariant()
                    $entries[$logicalPath] = [pscustomobject] @{
                        logicalPath = $logicalPath
                        sourceArchive = $SourceArchive
                        directoryVPK = $DirectoryVPK
                        headerSize = $headerSize
                        treeSize = $treeSize
                        archiveIndex = $archiveIndex
                        offset = [uint64] $entryOffset
                        length = [int] $entryLength
                        preload = [byte[]] $preload
                    }
                }
            }
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    return $entries
}

function Read-VPKEntryBytes($Entry) {
    $directoryName = [IO.Path]::GetFileNameWithoutExtension($Entry.directoryVPK)
    $chunkStem = $directoryName.Substring(0, $directoryName.Length - '_dir'.Length)
    if ([int] $Entry.archiveIndex -eq 0x7FFF) {
        $payloadPath = $Entry.directoryVPK
        $payloadOffset = $Entry.headerSize + $Entry.treeSize + $Entry.offset
    } else {
        $payloadPath = Join-Path (Split-Path -Parent $Entry.directoryVPK) (
            '{0}_{1:D3}.vpk' -f $chunkStem, [int] $Entry.archiveIndex
        )
        $payloadOffset = $Entry.offset
    }

    $payloadStream = [IO.File]::Open(
        $payloadPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    $payloadReader = New-Object IO.BinaryReader($payloadStream)
    try {
        [void] $payloadStream.Seek([int64] $payloadOffset, [IO.SeekOrigin]::Begin)
        $payload = $payloadReader.ReadBytes([int] $Entry.length)
        if ($payload.Length -ne [int] $Entry.length) {
            throw "Truncated VPK payload: $($Entry.logicalPath)"
        }
    } finally {
        $payloadReader.Dispose()
        $payloadStream.Dispose()
    }

    $bytes = New-Object byte[] ($Entry.preload.Length + $payload.Length)
    [Array]::Copy($Entry.preload, 0, $bytes, 0, $Entry.preload.Length)
    [Array]::Copy($payload, 0, $bytes, $Entry.preload.Length, $payload.Length)
    return $bytes
}

function Get-SHA256([byte[]] $Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-ImportedImageLiteral([string] $Literal) {
    $extension = [IO.Path]::GetExtension($Literal).ToLowerInvariant()
    return $extension -in @('.png', '.jpg', '.jpeg')
}

function ConvertTo-MaterialVMTPath([string] $Literal) {
    $value = $Literal.Trim().Replace('\', '/').ToLowerInvariant()
    if ($value.StartsWith('materials/')) { $value = $value.Substring('materials/'.Length) }
    if ($value.EndsWith('.vmt')) { $value = $value.Substring(0, $value.Length - 4) }
    if ([string]::IsNullOrWhiteSpace($value) -or
        $value.StartsWith('/') -or
        $value.Contains(':') -or
        $value.Contains('//') -or
        $value.Split('/') -contains '..' -or
        $value.Split('/') -contains '.' -or
        $value.IndexOfAny([char[]] @('*', '?', '{', '}', '(', ')')) -ge 0) {
        return $null
    }
    return 'materials/' + $value + '.vmt'
}

function ConvertTo-MaterialVTFPath([string] $Value) {
    $path = $Value.Trim().Replace('\', '/').ToLowerInvariant()
    if ($path.StartsWith('materials/')) { $path = $path.Substring('materials/'.Length) }
    if ($path.EndsWith('.vtf')) { $path = $path.Substring(0, $path.Length - 4) }
    if ([string]::IsNullOrWhiteSpace($path) -or
        $path.StartsWith('/') -or
        $path.Contains(':') -or
        $path.Contains('//') -or
        $path.Split('/') -contains '..' -or
        $path.Split('/') -contains '.') {
        return $null
    }
    return 'materials/' + $path + '.vtf'
}

function Get-LiteralValues([string] $Source, [string[]] $Patterns) {
    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pattern in $Patterns) {
        foreach ($match in [regex]::Matches($Source, $pattern)) {
            $values.Add($match.Groups['value'].Value)
        }
    }
    return $values.ToArray()
}

$literalPatterns = @(
    '(?im)\bMaterial\s*\(\s*(?<quote>["\x27])(?<value>[^"\x27\r\n]+)\k<quote>',
    '(?im):\s*(?:SetImage|SetMaterial)\s*\(\s*(?<quote>["\x27])(?<value>[^"\x27\r\n]+)\k<quote>'
)
$surfacePattern = '(?im)\bsurface\s*\.\s*GetTextureID\s*\(\s*(?<quote>["\x27])(?<value>[^"\x27\r\n]+)\k<quote>'
$literalValues = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$surfaceValues = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$scanRoots = @('lua', 'gamemodes/base', 'gamemodes/sandbox')
foreach ($scanRoot in $scanRoots) {
    $path = Join-Path $contentRoot $scanRoot.Replace('/', [IO.Path]::DirectorySeparatorChar)
    foreach ($file in Get-ChildItem -LiteralPath $path -Recurse -File -Filter '*.lua') {
        $source = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        foreach ($literal in Get-LiteralValues $source $literalPatterns) {
            [void] $literalValues.Add($literal)
        }
        foreach ($literal in Get-LiteralValues $source @($surfacePattern)) {
            [void] $literalValues.Add($literal)
            [void] $surfaceValues.Add($literal)
        }
    }
}

$sourceByPath = @{}
$archiveIndexes = @{}
foreach ($relativeArchive in $archiveRelativePaths) {
    $directoryVPK = Join-Path $GModRoot $relativeArchive.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $directoryVPK -PathType Leaf)) {
        throw "Required installed VPK is missing: $relativeArchive"
    }
    $index = Read-VPKIndex $directoryVPK $relativeArchive
    $archiveIndexes[$relativeArchive] = $index
    foreach ($logicalPath in $index.Keys) {
        if (-not $sourceByPath.ContainsKey($logicalPath)) {
            $sourceByPath[$logicalPath] = $index[$logicalPath]
        }
    }
}

$rootLiteralsByPath = @{}
$unresolvedMaterialLiterals = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::Ordinal
)
foreach ($literal in $literalValues) {
    if (Test-ImportedImageLiteral $literal) { continue }
    $logicalPath = ConvertTo-MaterialVMTPath $literal
    if ($null -eq $logicalPath) {
        [void] $unresolvedMaterialLiterals.Add($literal)
        continue
    }
    if (-not $rootLiteralsByPath.ContainsKey($logicalPath)) {
        $rootLiteralsByPath[$logicalPath] = New-Object 'System.Collections.Generic.List[string]'
    }
    $rootLiteralsByPath[$logicalPath].Add($literal)
}

$surfaceMaterialPaths = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::Ordinal
)
$unresolvedSurfaceLiterals = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::Ordinal
)
foreach ($literal in $surfaceValues) {
    $logicalPath = ConvertTo-MaterialVMTPath $literal
    if ($null -eq $logicalPath) {
        [void] $unresolvedSurfaceLiterals.Add($literal)
    } else {
        [void] $surfaceMaterialPaths.Add($logicalPath)
    }
}

$selectedBytes = @{}
$selectedSources = @{}
$primarySourceByPath = $archiveIndexes['garrysmod/garrysmod_dir.vpk']
$queuedVMTs = New-Object 'System.Collections.Generic.Queue[object]'
$visitedVMTs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$unresolvedVMTDependencies = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::Ordinal
)
$unresolvedBaseTextures = New-Object 'System.Collections.Generic.HashSet[string]' (
    [StringComparer]::Ordinal
)
foreach ($rootPath in $rootLiteralsByPath.Keys) {
    if ($surfaceMaterialPaths.Contains($rootPath)) {
        $queuedVMTs.Enqueue([pscustomobject] @{ path = $rootPath; extended = $true })
    } elseif ($primarySourceByPath.ContainsKey($rootPath)) {
        $queuedVMTs.Enqueue([pscustomobject] @{ path = $rootPath; extended = $false })
    } else {
        [void] $unresolvedVMTDependencies.Add($rootPath)
        foreach ($literal in $rootLiteralsByPath[$rootPath]) {
            [void] $unresolvedMaterialLiterals.Add($literal)
        }
    }
}

while ($queuedVMTs.Count -gt 0) {
    $request = $queuedVMTs.Dequeue()
    $logicalPath = [string] $request.path
    $extended = [bool] $request.extended
    $visitKey = $logicalPath + $(if ($extended) { '|extended' } else { '|primary' })
    if (-not $visitedVMTs.Add($visitKey)) { continue }
    $availableSources = if ($extended) { $sourceByPath } else { $primarySourceByPath }
    if (-not $availableSources.ContainsKey($logicalPath)) {
        [void] $unresolvedVMTDependencies.Add($logicalPath)
        if ($rootLiteralsByPath.ContainsKey($logicalPath)) {
            foreach ($literal in $rootLiteralsByPath[$logicalPath]) {
                [void] $unresolvedMaterialLiterals.Add($literal)
            }
        }
        foreach ($literal in $surfaceValues) {
            if ((ConvertTo-MaterialVMTPath $literal) -ceq $logicalPath) {
                [void] $unresolvedSurfaceLiterals.Add($literal)
            }
        }
        continue
    }

    $entry = $availableSources[$logicalPath]
    $bytes = [byte[]] (Read-VPKEntryBytes $entry)
    if ($bytes.Length -gt $maximumVMTBytes) {
        throw "VMT exceeds resolver bound: $logicalPath"
    }
    $selectedBytes[$logicalPath] = $bytes
    $selectedSources[$logicalPath] = $entry.sourceArchive

    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $withoutComments = [regex]::Replace($text, '(?m)//.*$', '')
    foreach ($match in [regex]::Matches(
        $withoutComments,
        '(?im)["\x27]?include["\x27]?\s+["\x27](?<value>[^"\x27]+)["\x27]'
    )) {
        $includePath = ConvertTo-MaterialVMTPath $match.Groups['value'].Value
        if ($null -eq $includePath) {
            throw "Unsafe Patch include in ${logicalPath}: $($match.Groups['value'].Value)"
        }
        $queuedVMTs.Enqueue([pscustomobject] @{
            path = $includePath
            extended = $extended
        })
    }
    foreach ($match in [regex]::Matches(
        $withoutComments,
        '(?im)["\x27]?\$basetexture["\x27]?\s+["\x27]?(?<value>[^\s"\x27{}]+)'
    )) {
        $texturePath = ConvertTo-MaterialVTFPath $match.Groups['value'].Value
        if ($null -eq $texturePath) {
            throw "Unsafe base texture in ${logicalPath}: $($match.Groups['value'].Value)"
        }
        if (-not $availableSources.ContainsKey($texturePath)) {
            [void] $unresolvedBaseTextures.Add($texturePath)
            continue
        }
        $textureEntry = $availableSources[$texturePath]
        $textureBytes = [byte[]] (Read-VPKEntryBytes $textureEntry)
        if ($textureBytes.Length -gt $maximumVTFBytes) {
            throw "VTF exceeds resolver encoded-byte bound: $texturePath"
        }
        $selectedBytes[$texturePath] = $textureBytes
        $selectedSources[$texturePath] = $textureEntry.sourceArchive
    }
}

if ($unresolvedSurfaceLiterals.Count -gt 0) {
    throw "Literal surface.GetTextureID dependencies are missing: " +
        (($unresolvedSurfaceLiterals | Sort-Object) -join ', ')
}
foreach ($surfacePath in $surfaceMaterialPaths) {
    if (-not $selectedBytes.ContainsKey($surfacePath)) {
        throw "Literal surface.GetTextureID VMT is outside the generated closure: $surfacePath"
    }
}

$logicalPaths = [string[]] @($selectedBytes.Keys)
[Array]::Sort($logicalPaths, [StringComparer]::Ordinal)
$assets = New-Object 'System.Collections.Generic.List[object]'
$byteCount = [int64] 0
$vmtCount = 0
$vtfCount = 0
$decodedMip0ByteCount = [int64] 0
foreach ($logicalPath in $logicalPaths) {
    $bytes = [byte[]] $selectedBytes[$logicalPath]
    if ($logicalPath.EndsWith('.vmt', [StringComparison]::Ordinal)) {
        $vmtCount += 1
    } elseif ($logicalPath.EndsWith('.vtf', [StringComparison]::Ordinal)) {
        $vtfCount += 1
        if ($bytes.Length -lt 20 -or
            $bytes[0] -ne 0x56 -or $bytes[1] -ne 0x54 -or
            $bytes[2] -ne 0x46 -or $bytes[3] -ne 0) {
            throw "Invalid VTF header: $logicalPath"
        }
        $width = [BitConverter]::ToUInt16($bytes, 16)
        $height = [BitConverter]::ToUInt16($bytes, 18)
        $pixels = [int64] $width * [int64] $height
        $decodedBytes = $pixels * 4
        if ($width -lt 1 -or $height -lt 1 -or
            $width -gt $maximumTextureDimension -or
            $height -gt $maximumTextureDimension -or
            $pixels -gt $maximumTexturePixels -or
            $decodedBytes -gt $maximumDecodedBytes) {
            throw "VTF exceeds resolver decoded-image bounds: $logicalPath (${width}x${height})"
        }
        $decodedMip0ByteCount += $decodedBytes
    } else {
        throw "Unexpected generated Source material extension: $logicalPath"
    }
    $assets.Add([ordered] @{
        logicalPath = $logicalPath
        sourceArchive = [string] $selectedSources[$logicalPath]
        byteCount = [int64] $bytes.Length
        sha256 = Get-SHA256 $bytes
    })
    $byteCount += $bytes.Length
}

$sourceArchives = [string[]] @(
    $archiveRelativePaths | Where-Object { $_ -in $assets.sourceArchive }
)
$surfacePaths = [string[]] @($surfaceMaterialPaths)
[Array]::Sort($surfacePaths, [StringComparer]::Ordinal)
$unresolvedMaterial = [string[]] @($unresolvedMaterialLiterals)
[Array]::Sort($unresolvedMaterial, [StringComparer]::Ordinal)
$unresolvedVMT = [string[]] @($unresolvedVMTDependencies)
[Array]::Sort($unresolvedVMT, [StringComparer]::Ordinal)
$unresolvedTextures = [string[]] @($unresolvedBaseTextures)
[Array]::Sort($unresolvedTextures, [StringComparer]::Ordinal)

$allowlist = [ordered] @{
    schemaVersion = 2
    sourceArchives = $sourceArchives
    selectionCriterion = (
        'Generated from bundled stock Lua literal Material/SetImage/SetMaterial roots ' +
        'present in garrysmod/garrysmod_dir.vpk and every literal surface.GetTextureID ' +
        'root in the exact garrysmod then platform VPK precedence, plus recursively ' +
        'existing Patch includes and resolved $basetexture VTFs. Dynamic and missing ' +
        'dependencies remain explicit.'
    )
    fileCount = $assets.Count
    byteCount = $byteCount
    vmtCount = $vmtCount
    vtfCount = $vtfCount
    decodedMip0ByteCount = $decodedMip0ByteCount
    surfaceTextureMaterialPaths = $surfacePaths
    assets = $assets
    unresolvedDynamicBaseTextures = $unresolvedTextures
    unresolvedMaterialLiterals = $unresolvedMaterial
    unresolvedVMTDependencies = $unresolvedVMT
}
$json = $allowlist | ConvertTo-Json -Depth 6

if ($Apply) {
    if (Test-Path -LiteralPath $allowlistPath -PathType Leaf) {
        $previous = Get-Content -LiteralPath $allowlistPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $removed = @($previous.assets.logicalPath | Where-Object { $_ -notin $logicalPaths })
        if ($removed.Count -gt 0) {
            throw 'Generated closure is not an expansion of the existing allowlist: ' +
                ($removed -join ', ')
        }
    }
    foreach ($logicalPath in $logicalPaths) {
        $destination = Join-Path $contentRoot (
            $logicalPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        )
        [void] [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [IO.File]::WriteAllBytes($destination, [byte[]] $selectedBytes[$logicalPath])
    }
    [IO.File]::WriteAllText(
        $allowlistPath,
        $json + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
    Write-Host "Wrote Source material allowlist and assets: files=$($assets.Count) bytes=$byteCount"
} else {
    if (-not (Test-Path -LiteralPath $allowlistPath -PathType Leaf)) {
        throw 'Generated Source material allowlist is not checked in'
    }
    $checkedInJSON = Get-Content -LiteralPath $allowlistPath -Raw -Encoding UTF8
    if ($checkedInJSON.TrimEnd() -cne $json.TrimEnd()) {
        throw 'Checked-in Source material allowlist differs from generated output'
    }
    foreach ($asset in $assets) {
        $bundledPath = Join-Path $contentRoot (
            $asset.logicalPath.Replace('/', [IO.Path]::DirectorySeparatorChar)
        )
        $bundled = Get-Item -LiteralPath $bundledPath
        $bundledHash = (
            Get-FileHash -LiteralPath $bundledPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        if ($bundled.Length -ne [int64] $asset.byteCount -or
            $bundledHash -cne [string] $asset.sha256) {
            throw "Bundled Source material differs from generated VPK bytes: $($asset.logicalPath)"
        }
    }
    Write-Host "Verified generated Source material allowlist: files=$($assets.Count) bytes=$byteCount VMT=$vmtCount VTF=$vtfCount decodedMip0=$decodedMip0ByteCount"
    Write-Host "surface.GetTextureID VMTs=$($surfacePaths.Count) archives=$($sourceArchives -join ',')"
    Write-Host "explicit unresolved literals=$($unresolvedMaterial.Count) VMTs=$($unresolvedVMT.Count) VTFs=$($unresolvedTextures.Count)"
}
