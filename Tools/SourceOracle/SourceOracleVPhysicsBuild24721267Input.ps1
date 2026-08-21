Set-StrictMode -Version 3.0

# Non-launch assembler for one exact AppID 4020 x86-64 build. It reads the
# fresh SteamCMD install and the two bounded model VPK ranges only. It cannot
# start a process, Windows Sandbox, SteamCMD, GMod, or load a DLL.

$script:VPhysicsBuild24721267SpecName =
    'VPhysicsSandbox-AppID4020-x86-64-build24721267-InputSpec.json'
$script:VPhysicsBuild24721267MetadataName =
    'VPhysicsAttestation-Button06-AllowlistMetadata.json'
$script:VPhysicsBuild24721267StartupClosureName =
    'VPhysicsSandbox-AppID4020-x86-64-build24721267-StartupClosure.json'
$script:VPhysicsBuild24721267ToolRoot = $PSScriptRoot
$script:VPhysicsBuild24721267DirectoryVPK = 'garrysmod/garrysmod_dir.vpk'
$script:VPhysicsBuild24721267MaximumDirectoryVPKBytes = [int64]1048576
$script:VPhysicsBuild24721267MaximumVPKEntries = 65536
$script:VPhysicsBuild24721267MaximumCStringBytes = 512

function Read-SourceOracleVPhysicsBuild24721267StartupClosure {
    [CmdletBinding()]
    param()

    $closure = Read-SourceOracleSandboxBoundedJSON `
        -Path (Join-Path $script:VPhysicsBuild24721267ToolRoot `
            $script:VPhysicsBuild24721267StartupClosureName) `
        -MaximumBytes 131072 `
        -Field 'build 24721267 startup closure'
    Assert-SourceOracleSandboxObjectShape `
        -InputObject $closure `
        -Field 'startup closure' `
        -Names @(
            'schema', 'kind', 'steam', 'scope', 'fixed_binaries',
            'required_files', 'audited_nonfatal', 'official_source'
        )
    if ([int64]$closure.schema -ne 1 -or
        [string]$closure.kind -cne
            'source-oracle-vphysics-pre-lua-fatal-file-closure') {
        throw 'Startup closure schema or kind is unsupported'
    }
    Assert-SourceOracleSandboxObjectShape `
        -InputObject $closure.steam `
        -Field 'startup closure steam' `
        -Names @('app_id', 'branch', 'build_id')
    if ([int64]$closure.steam.app_id -ne 4020 -or
        [string]$closure.steam.branch -cne 'x86-64' -or
        [string]$closure.steam.build_id -cne '24721267') {
        throw 'Startup closure is not bound to AppID 4020 x86-64 build 24721267'
    }
    Assert-SourceOracleSandboxObjectShape `
        -InputObject $closure.scope `
        -Field 'startup closure scope' `
        -Names @(
            'boundary', 'source_roots', 'path_classes',
            'required_file_count', 'finding'
        )
    if ([int64]$closure.scope.required_file_count -ne 6 -or
        (@($closure.scope.source_roots) -join '|') -cne
            'sourceengine|garrysmod' -or
        (@($closure.scope.path_classes) -join '|') -cne
            'resource|scripts|cfg|platform') {
        throw 'Startup closure scope does not declare the exact bounded audit'
    }

    $fixedBinaries = @($closure.fixed_binaries)
    if ($fixedBinaries.Count -ne 3) {
        throw 'Startup closure must bind exactly three evidence binaries'
    }
    $fixedBinarySources = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($binary in $fixedBinaries) {
        Assert-SourceOracleSandboxObjectShape `
            -InputObject $binary `
            -Field 'startup closure fixed binary' `
            -Names @('source_path', 'byte_count', 'sha256')
        Assert-SourceOracleSandboxRelativePath `
            -Value ([string]$binary.source_path) `
            -Field 'startup closure fixed binary source_path'
        Assert-SourceOracleSandboxSHA256 `
            -Value ([string]$binary.sha256) `
            -Field 'startup closure fixed binary SHA-256'
        if ([int64]$binary.byte_count -le 0) {
            throw 'Startup closure fixed binary byte_count must be positive'
        }
        if (-not $fixedBinarySources.Add([string]$binary.source_path)) {
            throw "Startup closure duplicates evidence binary $($binary.source_path)"
        }
    }
    foreach ($path in @(
        'bin/win64/engine.dll',
        'bin/win64/server.dll',
        'bin/win64/soundemittersystem.dll'
    )) {
        if (-not $fixedBinarySources.Contains($path)) {
            throw "Startup closure is missing evidence binary $path"
        }
    }

    $requiredFiles = @($closure.required_files)
    if ($requiredFiles.Count -ne 6) {
        throw 'Startup closure must contain exactly six fatal file inputs'
    }
    $requiredSources = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($entry in $requiredFiles) {
        Assert-SourceOracleSandboxObjectShape `
            -InputObject $entry `
            -Field 'startup closure required file' `
            -Names @(
                'source_root', 'source_path', 'input_path', 'byte_count',
                'sha256', 'fatal_stage', 'evidence'
            )
        $sourceRoot = [string]$entry.source_root
        $sourcePath = [string]$entry.source_path
        if ($sourceRoot -cnotin @('sourceengine', 'garrysmod') -or
            -not $sourcePath.StartsWith(
                $sourceRoot + '/',
                [StringComparison]::Ordinal
            )) {
            throw "Startup closure source root differs for $sourcePath"
        }
        Assert-SourceOracleSandboxRelativePath `
            -Value $sourcePath `
            -Field 'startup closure required source_path'
        Assert-SourceOracleSandboxRelativePath `
            -Value ([string]$entry.input_path) `
            -Field 'startup closure required input_path'
        Assert-SourceOracleSandboxSHA256 `
            -Value ([string]$entry.sha256) `
            -Field 'startup closure required SHA-256'
        if ([int64]$entry.byte_count -le 0 -or
            [string]::IsNullOrWhiteSpace([string]$entry.fatal_stage) -or
            [string]::IsNullOrWhiteSpace([string]$entry.evidence)) {
            throw "Startup closure evidence is incomplete for $sourcePath"
        }
        if (-not $requiredSources.Add($sourcePath)) {
            throw "Startup closure duplicates required file $sourcePath"
        }
    }
    foreach ($path in @(
        'garrysmod/resource/serverevents.res',
        'sourceengine/resource/hltvevents.res',
        'sourceengine/scripts/game_sounds_manifest.txt',
        'sourceengine/scripts/surfaceproperties_manifest.txt',
        'sourceengine/scripts/surfaceproperties.txt',
        'sourceengine/scripts/surfaceproperties_hl2.txt'
    )) {
        if (-not $requiredSources.Contains($path)) {
            throw "Startup closure is missing fatal file $path"
        }
    }

    $nonfatal = @($closure.audited_nonfatal)
    if ($nonfatal.Count -ne 4) {
        throw 'Startup closure must record four audited nonfatal path classes'
    }
    $nonfatalClasses = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($entry in $nonfatal) {
        Assert-SourceOracleSandboxObjectShape `
            -InputObject $entry `
            -Field 'startup closure audited nonfatal entry' `
            -Names @('path_class', 'paths', 'evidence')
        if (-not $nonfatalClasses.Add([string]$entry.path_class) -or
            @($entry.paths).Count -eq 0 -or
            [string]::IsNullOrWhiteSpace([string]$entry.evidence)) {
            throw 'Startup closure audited nonfatal entry is incomplete'
        }
    }
    foreach ($pathClass in @('resource', 'scripts', 'cfg', 'platform')) {
        if (-not $nonfatalClasses.Contains($pathClass)) {
            throw "Startup closure did not audit nonfatal $pathClass paths"
        }
    }
    Assert-SourceOracleSandboxObjectShape `
        -InputObject $closure.official_source `
        -Field 'startup closure official source' `
        -Names @(
            'commit', 'gameinterface', 'hltvdirector', 'sound_emitter',
            'prop_data', 'cached_file_data'
        )
    if ([string]$closure.official_source.commit -cne
        'c8f4c6351162fbff83bfa5a428d45d1e6eed3824') {
        throw 'Startup closure official Source reference is not pinned'
    }
    return $closure
}

function Assert-SourceOracleVPhysicsBuild24721267StartupClosure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Spec,
        [Parameter(Mandatory)] [object]$Closure
    )

    $issues = [Collections.Generic.List[string]]::new()
    foreach ($binary in @($Closure.fixed_binaries)) {
        $matches = @($Spec.files | Where-Object {
            [string]$_.source_path -ceq [string]$binary.source_path
        })
        if ($matches.Count -ne 1) {
            $issues.Add(
                "missing exact evidence binary: $($binary.source_path)"
            )
            continue
        }
        $match = $matches[0]
        if ([string]$match.sha256 -cne [string]$binary.sha256 -or
            [int64]$match.maximum_bytes -ne [int64]$binary.byte_count) {
            $issues.Add(
                "evidence binary differs from closure: $($binary.source_path)"
            )
        }
    }
    foreach ($entry in @($Closure.required_files)) {
        $matches = @($Spec.files | Where-Object {
            [string]$_.source_path -ceq [string]$entry.source_path
        })
        if ($matches.Count -ne 1) {
            $issues.Add(
                "missing exact fatal startup file: $($entry.source_path)"
            )
            continue
        }
        $match = $matches[0]
        if ([string]$match.input_path -cne [string]$entry.input_path -or
            [string]$match.sha256 -cne [string]$entry.sha256 -or
            [int64]$match.maximum_bytes -ne [int64]$entry.byte_count) {
            $issues.Add(
                "fatal startup file differs from closure: $($entry.source_path)"
            )
        }
    }
    if ($issues.Count -ne 0) {
        throw (
            "Startup closure rejected $($issues.Count) issue(s):`n- " +
            ($issues -join "`n- ")
        )
    }
    return $Closure
}

function Assert-SourceOracleVPhysicsBuild24721267StartupClosurePresence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstalledRoot,
        [Parameter(Mandatory)] [object]$Closure
    )

    $issues = [Collections.Generic.List[string]]::new()
    foreach ($entry in @($Closure.required_files)) {
        $path = $null
        try {
            $path = Assert-SourceOracleSandboxNoReparsePath `
                -Root $InstalledRoot `
                -RelativePath ([string]$entry.source_path) `
                -RequireFile
        } catch {
            $issues.Add("missing or unsafe: $($entry.source_path)")
            continue
        }
        $actualBytes = [int64][IO.FileInfo]::new($path).Length
        if ($actualBytes -ne [int64]$entry.byte_count) {
            $issues.Add(
                "byte count differs: $($entry.source_path) " +
                "($actualBytes != $($entry.byte_count))"
            )
        }
    }
    if ($issues.Count -ne 0) {
        throw (
            "Startup source closure rejected $($issues.Count) issue(s):`n- " +
            ($issues -join "`n- ")
        )
    }
    return $Closure
}

function Read-SourceOracleVPhysicsBuild24721267Inputs {
    [CmdletBinding()]
    param()

    $spec = Read-SourceOracleVPhysicsSandboxInputSpec -Path (
        Join-Path $script:VPhysicsBuild24721267ToolRoot `
            $script:VPhysicsBuild24721267SpecName
    )
    if ([string]$spec.steam.build_id -cne '24721267') {
        throw 'Fixed VPhysics input spec is not build 24721267'
    }
    $metadata = Read-SourceOracleVPhysicsBoundedJSON `
        -Path (Join-Path $script:VPhysicsBuild24721267ToolRoot `
            $script:VPhysicsBuild24721267MetadataName) `
        -MaximumBytes 65536 `
        -Field 'button_06 fixed input metadata'
    if ([string]$metadata.provenance.fresh_app_4020.build_id -cne '24721267') {
        throw 'button_06 metadata is not bound to AppID 4020 build 24721267'
    }
    if (@($metadata.model_files).Count -ne 4) {
        throw 'button_06 metadata must contain exactly four model files'
    }
    $closure = Read-SourceOracleVPhysicsBuild24721267StartupClosure
    [void](Assert-SourceOracleVPhysicsBuild24721267StartupClosure `
        -Spec $spec `
        -Closure $closure)
    return [pscustomobject]@{
        spec = $spec
        metadata = $metadata
        startup_closure = $closure
    }
}

function Copy-SourceOracleVPhysicsBuild24721267File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstalledRoot,
        [Parameter(Mandatory)] [object]$Entry,
        [Parameter(Mandatory)] [string]$StageRoot
    )

    $sourcePath = [string]$Entry.source_path
    $source = if ([string]$Entry.role -in @(
        'controlled_game_file', 'probe_lua', 'sandbox_bootstrap'
    )) {
        if (-not $sourcePath.StartsWith('tool/', [StringComparison]::Ordinal)) {
            throw "Controlled input does not originate from tool/: $sourcePath"
        }
        Assert-SourceOracleSandboxNoReparsePath `
            -Root $script:VPhysicsBuild24721267ToolRoot `
            -RelativePath $sourcePath.Substring('tool/'.Length) `
            -RequireFile
    } else {
        Assert-SourceOracleSandboxNoReparsePath `
            -Root $InstalledRoot `
            -RelativePath $sourcePath `
            -RequireFile
    }
    $destination = Get-SourceOracleSandboxChildPath `
        -Root $StageRoot `
        -RelativePath ([string]$Entry.source_path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))

    $sourceStream = [IO.File]::Open(
        $source,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $maximum = [int64]$Entry.maximum_bytes
        if ($sourceStream.Length -le 0 -or $sourceStream.Length -gt $maximum) {
            throw "Installed file byte count is outside its bound: $($Entry.source_path)"
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $actualSHA = ConvertTo-SourceOracleSandboxSHA256Hex (
                $sha.ComputeHash($sourceStream)
            )
        } finally {
            $sha.Dispose()
        }
        if ($actualSHA -cne [string]$Entry.sha256) {
            throw "Installed file SHA-256 differs: $($Entry.source_path)"
        }
        $sourceStream.Position = 0
        $destinationStream = [IO.File]::Open(
            $destination,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try { $sourceStream.CopyTo($destinationStream) }
        finally { $destinationStream.Dispose() }
    } finally {
        $sourceStream.Dispose()
    }
}

function Read-SourceOracleVPKCString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [IO.BinaryReader]$Reader,
        [Parameter(Mandatory)] [int64]$TreeEnd
    )

    $bytes = [Collections.Generic.List[byte]]::new()
    while ($true) {
        if ($Reader.BaseStream.Position -ge $TreeEnd) {
            throw 'VPK directory contains an unterminated string'
        }
        $value = $Reader.ReadByte()
        if ($value -eq 0) { break }
        $bytes.Add($value)
        if ($bytes.Count -gt $script:VPhysicsBuild24721267MaximumCStringBytes) {
            throw 'VPK directory string exceeds its bound'
        }
    }
    try { return [Text.UTF8Encoding]::new($false, $true).GetString($bytes.ToArray()) }
    catch { throw "VPK directory string is not strict UTF-8: $($_.Exception.Message)" }
}

function Read-SourceOracleVPhysicsBuild24721267VPKTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstalledRoot,
        [Parameter(Mandatory)] [object]$Metadata
    )

    $directoryPath = Assert-SourceOracleSandboxNoReparsePath `
        -Root $InstalledRoot `
        -RelativePath $script:VPhysicsBuild24721267DirectoryVPK `
        -RequireFile
    $expectedDirectorySHA = [string]$Metadata.provenance.directory_vpk.sha256
    Assert-SourceOracleSandboxSHA256 `
        -Value $expectedDirectorySHA `
        -Field 'button_06 directory VPK SHA-256'
    $targetPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($file in @($Metadata.model_files)) {
        [void]$targetPaths.Add([string]$file.logical_path)
    }

    $stream = [IO.File]::Open(
        $directoryPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -le 0 -or
            $stream.Length -gt $script:VPhysicsBuild24721267MaximumDirectoryVPKBytes) {
            throw 'GMod directory VPK byte count is outside its bound'
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $actualDirectorySHA = ConvertTo-SourceOracleSandboxSHA256Hex (
                $sha.ComputeHash($stream)
            )
        } finally {
            $sha.Dispose()
        }
        if ($actualDirectorySHA -cne $expectedDirectorySHA) {
            throw 'GMod directory VPK differs from the fixed owned input'
        }
        $stream.Position = 0
        if ($reader.ReadUInt32() -ne 0x55AA1234) {
            throw 'GMod directory VPK signature is invalid'
        }
        $version = $reader.ReadUInt32()
        $treeSize = [int64]$reader.ReadUInt32()
        if ($version -eq 1) {
            $headerSize = [int64]12
        } elseif ($version -eq 2) {
            [void]$reader.ReadUInt32()
            [void]$reader.ReadUInt32()
            [void]$reader.ReadUInt32()
            [void]$reader.ReadUInt32()
            $headerSize = [int64]28
        } else {
            throw "Unsupported GMod directory VPK version $version"
        }
        $treeEnd = $headerSize + $treeSize
        if ($treeSize -le 0 -or $treeEnd -gt $stream.Length) {
            throw 'GMod directory VPK tree exceeds the retained file'
        }

        $found = @{}
        $entryCount = 0
        while ($true) {
            $extension = Read-SourceOracleVPKCString -Reader $reader -TreeEnd $treeEnd
            if ($extension.Length -eq 0) { break }
            while ($true) {
                $directory = Read-SourceOracleVPKCString -Reader $reader -TreeEnd $treeEnd
                if ($directory.Length -eq 0) { break }
                while ($true) {
                    $name = Read-SourceOracleVPKCString -Reader $reader -TreeEnd $treeEnd
                    if ($name.Length -eq 0) { break }
                    $entryCount++
                    if ($entryCount -gt $script:VPhysicsBuild24721267MaximumVPKEntries) {
                        throw 'GMod directory VPK entry count exceeds its bound'
                    }
                    $crc = $reader.ReadUInt32()
                    $preloadBytes = [int]$reader.ReadUInt16()
                    $archiveIndex = [int]$reader.ReadUInt16()
                    $offset = [uint64]$reader.ReadUInt32()
                    $length = [int64]$reader.ReadUInt32()
                    if ($reader.ReadUInt16() -ne 0xFFFF) {
                        throw 'GMod directory VPK entry terminator is invalid'
                    }
                    $preload = $reader.ReadBytes($preloadBytes)
                    if ($preload.Length -ne $preloadBytes) {
                        throw 'GMod directory VPK preload data is truncated'
                    }
                    $prefix = if ($directory -ceq ' ') { '' } else { $directory + '/' }
                    $logicalPath = ($prefix + $name + '.' + $extension).ToLowerInvariant()
                    if ($targetPaths.Contains($logicalPath)) {
                        if ($found.ContainsKey($logicalPath)) {
                            throw "GMod directory VPK duplicates target $logicalPath"
                        }
                        $found[$logicalPath] = [pscustomobject]@{
                            logical_path = $logicalPath
                            crc32 = $crc.ToString('x8')
                            preload = [byte[]]$preload
                            archive_index = $archiveIndex
                            offset = $offset
                            length = $length
                        }
                    }
                }
            }
        }
        if ($stream.Position -ne $treeEnd) {
            throw 'GMod directory VPK tree did not end at its declared boundary'
        }
        if ($found.Count -ne $targetPaths.Count) {
            throw 'GMod directory VPK is missing a fixed button_06 target'
        }
        return $found
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Write-SourceOracleVPhysicsBuild24721267ModelFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstalledRoot,
        [Parameter(Mandatory)] [string]$StageRoot,
        [Parameter(Mandatory)] [object]$Spec,
        [Parameter(Mandatory)] [object]$Metadata
    )

    $targets = Read-SourceOracleVPhysicsBuild24721267VPKTargets `
        -InstalledRoot $InstalledRoot `
        -Metadata $Metadata
    $expectedArchiveIndex = [int]$Metadata.provenance.chunk_vpk.archive_index
    $chunkRelative = [string]$Metadata.provenance.chunk_vpk.logical_path
    $chunkPath = Assert-SourceOracleSandboxNoReparsePath `
        -Root $InstalledRoot `
        -RelativePath $chunkRelative `
        -RequireFile
    $expectedChunkBytes = [int64]$Metadata.provenance.chunk_vpk.byte_count

    $chunk = [IO.File]::Open(
        $chunkPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($chunk.Length -ne $expectedChunkBytes) {
            throw 'GMod button_06 VPK chunk byte count differs'
        }
        foreach ($file in @($Metadata.model_files)) {
            $logicalPath = [string]$file.logical_path
            $target = $targets[$logicalPath]
            if ($target.archive_index -ne $expectedArchiveIndex -or
                $target.offset -ne [uint64]$file.vpk_offset -or
                $target.preload.Length -ne [int]$file.vpk_preload_bytes -or
                $target.crc32 -cne [string]$file.vpk_crc32) {
                throw "GMod VPK index metadata differs for $logicalPath"
            }
            $byteCount = [int64]$file.byte_count
            if ($target.length + $target.preload.Length -ne $byteCount -or
                $byteCount -le 0 -or $byteCount -gt 33554432) {
                throw "GMod VPK target byte count differs for $logicalPath"
            }
            if ([uint64]$target.offset + [uint64]$target.length -gt [uint64]$chunk.Length) {
                throw "GMod VPK target range escapes its chunk for $logicalPath"
            }
            $payload = [byte[]]::new([int]$target.length)
            $chunk.Position = [int64]$target.offset
            $cursor = 0
            while ($cursor -lt $payload.Length) {
                $read = $chunk.Read($payload, $cursor, $payload.Length - $cursor)
                if ($read -le 0) { throw "GMod VPK target is truncated: $logicalPath" }
                $cursor += $read
            }
            $bytes = [byte[]]::new([int]$byteCount)
            [Array]::Copy($target.preload, 0, $bytes, 0, $target.preload.Length)
            [Array]::Copy(
                $payload,
                0,
                $bytes,
                $target.preload.Length,
                $payload.Length
            )
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $actualSHA = ConvertTo-SourceOracleSandboxSHA256Hex $sha.ComputeHash($bytes)
            } finally {
                $sha.Dispose()
            }
            if ($actualSHA -cne [string]$file.sha256) {
                throw "GMod VPK target SHA-256 differs for $logicalPath"
            }
            $matching = @($Spec.files | Where-Object {
                [string]$_.input_path -ceq ('oracle_game/' + $logicalPath)
            })
            if ($matching.Count -ne 1 -or
                [string]$matching[0].sha256 -cne $actualSHA -or
                [int64]$matching[0].maximum_bytes -ne $byteCount) {
                throw "Fixed workspace spec differs for model target $logicalPath"
            }
            $destination = Get-SourceOracleSandboxChildPath `
                -Root $StageRoot `
                -RelativePath ([string]$matching[0].source_path)
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $destinationStream = [IO.File]::Open(
                $destination,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            try { $destinationStream.Write($bytes, 0, $bytes.Length) }
            finally { $destinationStream.Dispose() }
        }
    } finally {
        $chunk.Dispose()
    }
}

function New-SourceOracleVPhysicsBuild24721267Stage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InstalledServerRoot,
        [Parameter(Mandatory)] [string]$StagePath
    )

    $installed = Assert-SourceOracleSandboxNoReparsePath `
        -Root $InstalledServerRoot `
        -RequireDirectory
    $inputs = Read-SourceOracleVPhysicsBuild24721267Inputs
    [void](Assert-SourceOracleVPhysicsBuild24721267StartupClosurePresence `
        -InstalledRoot $installed `
        -Closure $inputs.startup_closure)
    $stage = [IO.Path]::GetFullPath($StagePath).TrimEnd('\')
    if ([IO.Directory]::Exists($stage) -or [IO.File]::Exists($stage)) {
        throw "Stage already exists: $stage"
    }
    $parent = [IO.Path]::GetDirectoryName($stage)
    [void](Assert-SourceOracleSandboxNoReparsePath -Root $parent -RequireDirectory)
    $temporary = [IO.Path]::Combine(
        $parent,
        '.' + [IO.Path]::GetFileName($stage) + '.assembling-' +
            [Guid]::NewGuid().ToString('N')
    )
    $committed = $false
    try {
        [void][IO.Directory]::CreateDirectory($temporary)
        foreach ($entry in @($inputs.spec.files)) {
            if ([string]$entry.role -in @('model_mdl', 'model_phy', 'model_render_asset')) {
                continue
            }
            Copy-SourceOracleVPhysicsBuild24721267File `
                -InstalledRoot $installed `
                -Entry $entry `
                -StageRoot $temporary
        }
        Write-SourceOracleVPhysicsBuild24721267ModelFiles `
            -InstalledRoot $installed `
            -StageRoot $temporary `
            -Spec $inputs.spec `
            -Metadata $inputs.metadata
        foreach ($entry in @($inputs.spec.files)) {
            $path = Assert-SourceOracleSandboxNoReparsePath `
                -Root $temporary `
                -RelativePath ([string]$entry.source_path) `
                -RequireFile
            $fingerprint = Get-SourceOracleSandboxFileFingerprint `
                -Path $path `
                -MaximumBytes ([int64]$entry.maximum_bytes)
            if ($fingerprint.sha256 -cne [string]$entry.sha256) {
                throw "Staged file differs from its exact spec: $($entry.source_path)"
            }
        }
        $treeFiles = @(Get-SourceOracleSandboxBoundedTreeFiles -Root $temporary)
        if ($treeFiles.Count -ne @($inputs.spec.files).Count) {
            throw 'Staging input contains unallowlisted files'
        }
        [IO.Directory]::Move($temporary, $stage)
        $committed = $true
        return [pscustomobject][ordered]@{
            schema = [int64]1
            kind = 'source-oracle-vphysics-build-24721267-stage'
            build_id = '24721267'
            file_count = [int64]$treeFiles.Count
            source_root = $stage
            input_spec = [IO.Path]::Combine(
                $script:VPhysicsBuild24721267ToolRoot,
                $script:VPhysicsBuild24721267SpecName
            )
        }
    } finally {
        if (-not $committed -and [IO.Directory]::Exists($temporary)) {
            [IO.Directory]::Delete($temporary, $true)
        }
    }
}
