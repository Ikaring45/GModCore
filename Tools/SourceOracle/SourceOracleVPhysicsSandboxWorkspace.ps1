Set-StrictMode -Version 3.0

# Non-launch support for assembling one manifest-verified Windows Sandbox input.
# This file does not install Steam content, start Windows Sandbox/GMod, load a
# DLL, or change firewall policy.

$script:VPhysicsSandboxSpecByteCap = 262144
$script:VPhysicsSandboxMetadataByteCap = 1048576
$script:VPhysicsSandboxMaximumFiles = 512
$script:VPhysicsSandboxMaximumDirectories = 1024
$script:VPhysicsSandboxMaximumFileBytes = [int64]536870912
$script:VPhysicsSandboxMaximumTotalBytes = [int64]8589934592
$script:VPhysicsSandboxRequiredRoles = @(
    'server_executable',
    'engine_module',
    'game_server_module',
    'vphysics_module',
    'tier0_module',
    'model_mdl',
    'model_phy'
)
$script:VPhysicsSandboxAllowedRoles = @(
    $script:VPhysicsSandboxRequiredRoles + @(
        'server_runtime',
        'shipped_content',
        'shipped_lua',
        'model_render_asset'
    )
)
$script:VPhysicsSandboxEmptyMount = '"mountcfg"' + "`r`n{`r`n}`r`n"
$script:VPhysicsSandboxEmptyDepots = '"gamedepotsystem"' + "`r`n{`r`n}`r`n"

function Assert-SourceOracleSandboxObjectShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string[]]$Names,
        [Parameter(Mandatory)] [string]$Field
    )

    if ($null -eq $InputObject -or $InputObject -is [array] -or
        $InputObject -is [string] -or $null -eq $InputObject.PSObject) {
        throw "$Field must be one JSON object"
    }
    $actual = @($InputObject.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) {
        throw "$Field has an unexpected property count"
    }
    foreach ($name in $Names) {
        if ($actual -cnotcontains $name) {
            throw "$Field is missing exact property $name"
        }
    }
}

function Get-SourceOracleSandboxString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int]$MaximumLength
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string]) {
        throw "$Name must be a JSON string"
    }
    $value = [string]$property.Value
    if ($value.Length -eq 0 -or $value.Length -gt $MaximumLength -or
        $value.IndexOf([char]0) -ge 0) {
        throw "$Name has an invalid string length or contains NUL"
    }
    return $value
}

function Get-SourceOracleSandboxInteger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int64]$Minimum,
        [Parameter(Mandatory)] [int64]$Maximum
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Name is missing" }
    $value = $property.Value
    $isInteger = $value -is [byte] -or $value -is [sbyte] -or
        $value -is [int16] -or $value -is [uint16] -or
        $value -is [int32] -or $value -is [uint32] -or
        $value -is [int64]
    if (-not $isInteger) { throw "$Name must be a JSON integer" }
    $converted = [int64]$value
    if ($converted -lt $Minimum -or $converted -gt $Maximum) {
        throw "$Name is outside $Minimum...$Maximum"
    }
    return $converted
}

function Assert-SourceOracleSandboxSHA256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Value,
        [Parameter(Mandatory)] [string]$Field
    )

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Field must be lowercase SHA-256 hex"
    }
}

function Assert-SourceOracleSandboxRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Value,
        [Parameter(Mandatory)] [string]$Field
    )

    if ($Value.Length -gt 512 -or
        $Value -cnotmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$') {
        throw "$Field is not one canonical relative path"
    }
    $reserved = @('con', 'prn', 'aux', 'nul', 'clock$')
    foreach ($index in 1..9) {
        $reserved += "com$index"
        $reserved += "lpt$index"
    }
    foreach ($segment in $Value.Split('/')) {
        if ($segment -ceq '.' -or $segment -ceq '..' -or
            $segment.EndsWith('.', [StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [StringComparison]::Ordinal)) {
            throw "$Field contains an unsafe path segment"
        }
        $baseName = [IO.Path]::GetFileNameWithoutExtension($segment).ToLowerInvariant()
        if ($reserved -contains $baseName) {
            throw "$Field contains reserved Windows name $segment"
        }
    }
}

function Assert-SourceOracleSandboxLogicalModelPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Value,
        [Parameter(Mandatory)] [ValidateSet('.mdl', '.phy')] [string]$Extension,
        [Parameter(Mandatory)] [string]$Field
    )

    if ($Value.Length -gt 240 -or
        $Value -cnotmatch '^models/[a-z0-9_.-]+(?:/[a-z0-9_.-]+)*\.(mdl|phy)$' -or
        -not $Value.EndsWith($Extension, [StringComparison]::Ordinal)) {
        throw "$Field is not one canonical lowercase model path"
    }
}

function Get-SourceOracleSandboxChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$RelativePath
    )

    Assert-SourceOracleSandboxRelativePath -Value $RelativePath -Field 'relative path'
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath(
        [IO.Path]::Combine($fullRoot, $RelativePath.Replace('/', '\'))
    )
    if (-not $candidate.StartsWith(
        $fullRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Relative path escaped its root'
    }
    return $candidate
}

function Assert-SourceOracleSandboxNoReparsePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [string]$RelativePath,
        [switch]$RequireFile,
        [switch]$RequireDirectory
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not [IO.Directory]::Exists($fullRoot)) {
        throw "Root directory does not exist: $fullRoot"
    }
    $rootAttributes = [IO.File]::GetAttributes($fullRoot)
    if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Root directory is a reparse point: $fullRoot"
    }
    if ([string]::IsNullOrEmpty($RelativePath)) { return $fullRoot }

    Assert-SourceOracleSandboxRelativePath -Value $RelativePath -Field 'relative path'
    $current = $fullRoot
    $segments = $RelativePath.Split('/')
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = [IO.Path]::Combine($current, $segments[$index])
        if (-not [IO.File]::Exists($current) -and -not [IO.Directory]::Exists($current)) {
            throw "Manifest path does not exist: $RelativePath"
        }
        $attributes = [IO.File]::GetAttributes($current)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Manifest path traverses a reparse point: $RelativePath"
        }
        if ($index -lt ($segments.Count - 1) -and
            ($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
            throw "Manifest path traverses a non-directory: $RelativePath"
        }
    }
    if ($RequireFile -and -not [IO.File]::Exists($current)) {
        throw "Manifest path is not a file: $RelativePath"
    }
    if ($RequireDirectory -and -not [IO.Directory]::Exists($current)) {
        throw "Manifest path is not a directory: $RelativePath"
    }
    return $current
}

function Read-SourceOracleSandboxBoundedJSON {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$MaximumBytes,
        [Parameter(Mandatory)] [string]$Field
    )

    $stream = [IO.File]::Open(
        [IO.Path]::GetFullPath($Path),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $MaximumBytes) {
            throw "$Field byte count $($stream.Length) is outside 1...$MaximumBytes"
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $cursor = 0
        while ($cursor -lt $bytes.Length) {
            $read = $stream.Read($bytes, $cursor, $bytes.Length - $cursor)
            if ($read -le 0) { throw "$Field ended before its retained length" }
            $cursor += $read
        }
    } finally {
        $stream.Dispose()
    }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { throw "$Field is not strict UTF-8: $($_.Exception.Message)" }
    try { return $text | ConvertFrom-Json }
    catch { throw "$Field is not valid JSON: $($_.Exception.Message)" }
}

function Assert-SourceOracleVPhysicsSandboxInputSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Spec)

    Assert-SourceOracleSandboxObjectShape -InputObject $Spec -Field 'input spec' -Names @(
        'schema', 'kind', 'steam', 'ownership_reference', 'server', 'model', 'files'
    )
    [void](Get-SourceOracleSandboxInteger -InputObject $Spec -Name 'schema' -Minimum 1 -Maximum 1)
    if ((Get-SourceOracleSandboxString -InputObject $Spec -Name 'kind' -MaximumLength 96) `
        -cne 'fresh-steamcmd-app-4020-x86-64-attestation-input') {
        throw 'input spec kind is unsupported'
    }

    Assert-SourceOracleSandboxObjectShape -InputObject $Spec.steam -Field 'steam' -Names @(
        'app_id', 'branch', 'build_id'
    )
    [void](Get-SourceOracleSandboxInteger -InputObject $Spec.steam `
        -Name 'app_id' -Minimum 4020 -Maximum 4020)
    if ((Get-SourceOracleSandboxString -InputObject $Spec.steam `
        -Name 'branch' -MaximumLength 32) -cne 'x86-64') {
        throw 'steam.branch must be x86-64'
    }
    $buildID = Get-SourceOracleSandboxString -InputObject $Spec.steam `
        -Name 'build_id' -MaximumLength 20
    if ($buildID -cnotmatch '^[1-9][0-9]{0,19}$') {
        throw 'steam.build_id must be one positive decimal build ID'
    }
    [void](Get-SourceOracleSandboxString -InputObject $Spec `
        -Name 'ownership_reference' -MaximumLength 128)

    Assert-SourceOracleSandboxObjectShape -InputObject $Spec.server -Field 'server' -Names @(
        'executable_input_path', 'engine_input_path', 'game_server_input_path',
        'vphysics_input_path', 'tier0_input_path'
    )
    $serverRolePaths = [ordered]@{
        server_executable = Get-SourceOracleSandboxString -InputObject $Spec.server `
            -Name 'executable_input_path' -MaximumLength 512
        engine_module = Get-SourceOracleSandboxString -InputObject $Spec.server `
            -Name 'engine_input_path' -MaximumLength 512
        game_server_module = Get-SourceOracleSandboxString -InputObject $Spec.server `
            -Name 'game_server_input_path' -MaximumLength 512
        vphysics_module = Get-SourceOracleSandboxString -InputObject $Spec.server `
            -Name 'vphysics_input_path' -MaximumLength 512
        tier0_module = Get-SourceOracleSandboxString -InputObject $Spec.server `
            -Name 'tier0_input_path' -MaximumLength 512
    }
    foreach ($pair in $serverRolePaths.GetEnumerator()) {
        Assert-SourceOracleSandboxRelativePath -Value $pair.Value -Field "server.$($pair.Key)"
        if (-not $pair.Value.StartsWith('server/', [StringComparison]::Ordinal)) {
            throw "server.$($pair.Key) must be below the isolated server input"
        }
    }

    Assert-SourceOracleSandboxObjectShape -InputObject $Spec.model -Field 'model' -Names @(
        'model_path', 'phy_path'
    )
    $modelPath = Get-SourceOracleSandboxString -InputObject $Spec.model `
        -Name 'model_path' -MaximumLength 240
    $phyPath = Get-SourceOracleSandboxString -InputObject $Spec.model `
        -Name 'phy_path' -MaximumLength 240
    Assert-SourceOracleSandboxLogicalModelPath -Value $modelPath -Extension '.mdl' -Field 'model_path'
    Assert-SourceOracleSandboxLogicalModelPath -Value $phyPath -Extension '.phy' -Field 'phy_path'
    if ($phyPath -cne ($modelPath.Substring(0, $modelPath.Length - 4) + '.phy')) {
        throw 'model.phy_path is not derived from model.model_path'
    }

    if ($Spec.files -isnot [array]) { throw 'files must be one JSON array' }
    $files = @($Spec.files)
    if ($files.Count -lt $script:VPhysicsSandboxRequiredRoles.Count -or
        $files.Count -gt $script:VPhysicsSandboxMaximumFiles) {
        throw 'files count is outside the bounded workspace limit'
    }

    $inputPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $sourcePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $roleCounts = @{}
    $totalMaximum = [int64]0
    foreach ($entry in $files) {
        Assert-SourceOracleSandboxObjectShape -InputObject $entry -Field 'files entry' -Names @(
            'role', 'source_path', 'input_path', 'sha256', 'maximum_bytes'
        )
        $role = Get-SourceOracleSandboxString -InputObject $entry -Name 'role' -MaximumLength 64
        if ($script:VPhysicsSandboxAllowedRoles -cnotcontains $role) {
            throw "Unsupported files role $role"
        }
        $sourcePath = Get-SourceOracleSandboxString -InputObject $entry `
            -Name 'source_path' -MaximumLength 512
        $inputPath = Get-SourceOracleSandboxString -InputObject $entry `
            -Name 'input_path' -MaximumLength 512
        Assert-SourceOracleSandboxRelativePath -Value $sourcePath -Field 'files.source_path'
        Assert-SourceOracleSandboxRelativePath -Value $inputPath -Field 'files.input_path'
        if ($sourcePath -match '(?i)(^|/)garrysmod/addons(/|$)' -or
            $inputPath -match '(?i)(^|/)garrysmod/addons(/|$)' -or
            $inputPath -match '(?i)(^|/)addons(/|$)') {
            throw 'Inherited garrysmod/addons content is forbidden'
        }
        if (-not $inputPaths.Add($inputPath)) {
            throw "Duplicate case-insensitive input path $inputPath"
        }
        if (-not $sourcePaths.Add($sourcePath)) {
            throw "Duplicate case-insensitive source path $sourcePath"
        }
        $sha = Get-SourceOracleSandboxString -InputObject $entry `
            -Name 'sha256' -MaximumLength 64
        Assert-SourceOracleSandboxSHA256 -Value $sha -Field 'files.sha256'
        $maximum = Get-SourceOracleSandboxInteger -InputObject $entry `
            -Name 'maximum_bytes' -Minimum 1 -Maximum $script:VPhysicsSandboxMaximumFileBytes
        $totalMaximum += [int64]$maximum
        if ($totalMaximum -gt $script:VPhysicsSandboxMaximumTotalBytes) {
            throw 'Declared file maxima exceed the bounded workspace total'
        }
        if (-not $roleCounts.ContainsKey($role)) { $roleCounts[$role] = 0 }
        $roleCounts[$role] = [int]$roleCounts[$role] + 1

        if ($serverRolePaths.Contains($role) -and
            $inputPath -cne [string]$serverRolePaths[$role]) {
            throw "$role does not match its exact server input path"
        }
        if ($role -ceq 'model_mdl' -and
            $inputPath -cne ('oracle_game/' + $modelPath)) {
            throw 'model_mdl does not match the exact logical model path'
        }
        if ($role -ceq 'model_phy' -and
            $inputPath -cne ('oracle_game/' + $phyPath)) {
            throw 'model_phy does not match the exact logical PHY path'
        }
        if ($role -ceq 'model_render_asset') {
            $modelStem = $modelPath.Substring(0, $modelPath.Length - 4)
            if ($inputPath -cne ('oracle_game/' + $modelStem + '.vvd') -and
                $inputPath -cne ('oracle_game/' + $modelStem + '.dx90.vtx')) {
                throw 'model_render_asset is not the exact VVD or DX90 VTX companion'
            }
        }
        if ($role -in @('server_runtime', 'shipped_content', 'shipped_lua') -and
            -not $inputPath.StartsWith('server/', [StringComparison]::Ordinal)) {
            throw "$role must remain below the isolated server input"
        }
    }

    foreach ($role in $script:VPhysicsSandboxRequiredRoles) {
        if (-not $roleCounts.ContainsKey($role) -or [int]$roleCounts[$role] -ne 1) {
            throw "Required role $role must appear exactly once"
        }
    }
    return $Spec
}

function Read-SourceOracleVPhysicsSandboxInputSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    $spec = Read-SourceOracleSandboxBoundedJSON -Path $Path `
        -MaximumBytes $script:VPhysicsSandboxSpecByteCap -Field 'sandbox input spec'
    return Assert-SourceOracleVPhysicsSandboxInputSpec -Spec $spec
}

function ConvertTo-SourceOracleSandboxSHA256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [byte[]]$Digest)
    return ($Digest | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Copy-SourceOracleSandboxVerifiedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceRoot,
        [Parameter(Mandatory)] [object]$Entry,
        [Parameter(Mandatory)] [string]$InputRoot
    )

    $source = Assert-SourceOracleSandboxNoReparsePath -Root $SourceRoot `
        -RelativePath ([string]$Entry.source_path) -RequireFile
    $destination = Get-SourceOracleSandboxChildPath -Root $InputRoot `
        -RelativePath ([string]$Entry.input_path)
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
            throw "Source byte count for $($Entry.source_path) exceeds its exact bound"
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualSHA = ConvertTo-SourceOracleSandboxSHA256Hex $sha.ComputeHash($sourceStream) }
        finally { $sha.Dispose() }
        if ($actualSHA -cne [string]$Entry.sha256) {
            throw "Source SHA-256 mismatch for $($Entry.source_path)"
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
        return [pscustomobject][ordered]@{
            path = [string]$Entry.input_path
            role = [string]$Entry.role
            sha256 = $actualSHA
            byte_count = [int64]$sourceStream.Length
        }
    } finally {
        $sourceStream.Dispose()
    }
}

function Write-SourceOracleSandboxUTF8 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-SourceOracleSandboxFileFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int64]$MaximumBytes
    )

    $stream = [IO.File]::Open(
        [IO.Path]::GetFullPath($Path),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $MaximumBytes) {
            throw "File byte count for $Path is outside its bound"
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ConvertTo-SourceOracleSandboxSHA256Hex $sha.ComputeHash($stream) }
        finally { $sha.Dispose() }
        return [pscustomobject]@{ sha256 = $hash; byte_count = [int64]$stream.Length }
    } finally {
        $stream.Dispose()
    }
}

function New-SourceOracleSandboxWSBText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InputPath,
        [Parameter(Mandatory)] [string]$OutputPath
    )

    $escapedInput = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath($InputPath))
    $escapedOutput = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath($OutputPath))
    return @"
<Configuration>
  <vGPU>Disable</vGPU>
  <Networking>Disable</Networking>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$escapedInput</HostFolder>
      <SandboxFolder>C:\GarrysPAD\Input</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$escapedOutput</HostFolder>
      <SandboxFolder>C:\GarrysPAD\Output</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
</Configuration>
"@
}

function New-SourceOracleVPhysicsSandboxWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceRoot,
        [Parameter(Mandatory)] [string]$InputSpecPath,
        [Parameter(Mandatory)] [string]$WorkspacePath
    )

    $sourceRootFull = Assert-SourceOracleSandboxNoReparsePath `
        -Root $SourceRoot -RequireDirectory
    $spec = Read-SourceOracleVPhysicsSandboxInputSpec -Path $InputSpecPath
    $workspaceFull = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    if ([IO.Directory]::Exists($workspaceFull) -or [IO.File]::Exists($workspaceFull)) {
        throw "Workspace already exists: $workspaceFull"
    }
    $parent = [IO.Path]::GetDirectoryName($workspaceFull)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not [IO.Directory]::Exists($parent)) {
        throw 'Workspace parent must already exist'
    }
    [void](Assert-SourceOracleSandboxNoReparsePath -Root $parent -RequireDirectory)
    $temporary = [IO.Path]::Combine(
        $parent,
        '.' + [IO.Path]::GetFileName($workspaceFull) + '.assembling-' +
            [Guid]::NewGuid().ToString('N')
    )
    $committed = $false
    try {
        [void][IO.Directory]::CreateDirectory($temporary)
        $inputRoot = [IO.Path]::Combine($temporary, 'input')
        $outputRoot = [IO.Path]::Combine($temporary, 'output')
        [void][IO.Directory]::CreateDirectory($inputRoot)
        [void][IO.Directory]::CreateDirectory($outputRoot)

        $records = [Collections.Generic.List[object]]::new()
        foreach ($entry in @($spec.files)) {
            $records.Add((Copy-SourceOracleSandboxVerifiedFile `
                -SourceRoot $sourceRootFull -Entry $entry -InputRoot $inputRoot))
        }

        $mountPath = Get-SourceOracleSandboxChildPath -Root $inputRoot `
            -RelativePath 'oracle_game/cfg/mount.cfg'
        $depotsPath = Get-SourceOracleSandboxChildPath -Root $inputRoot `
            -RelativePath 'oracle_game/cfg/mountdepots.txt'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($mountPath))
        Write-SourceOracleSandboxUTF8 -Path $mountPath -Text $script:VPhysicsSandboxEmptyMount
        Write-SourceOracleSandboxUTF8 -Path $depotsPath -Text $script:VPhysicsSandboxEmptyDepots
        foreach ($generated in @(
            @('oracle_game/cfg/mount.cfg', 'empty_mount_config', $mountPath),
            @('oracle_game/cfg/mountdepots.txt', 'empty_mountdepots_config', $depotsPath)
        )) {
            $fingerprint = Get-SourceOracleSandboxFileFingerprint `
                -Path $generated[2] -MaximumBytes 4096
            $records.Add([pscustomobject][ordered]@{
                path = $generated[0]
                role = $generated[1]
                sha256 = $fingerprint.sha256
                byte_count = $fingerprint.byte_count
            })
        }

        $normalizedSpecPath = [IO.Path]::Combine($inputRoot, 'input-spec.json')
        $normalizedSpec = $spec | ConvertTo-Json -Depth 16
        Write-SourceOracleSandboxUTF8 -Path $normalizedSpecPath `
            -Text ($normalizedSpec + "`r`n")
        $specFingerprint = Get-SourceOracleSandboxFileFingerprint `
            -Path $normalizedSpecPath -MaximumBytes $script:VPhysicsSandboxSpecByteCap
        $records.Add([pscustomobject][ordered]@{
            path = 'input-spec.json'
            role = 'validated_input_spec'
            sha256 = $specFingerprint.sha256
            byte_count = $specFingerprint.byte_count
        })

        $orderedRecords = @($records | Sort-Object -Property path)
        $manifest = [pscustomobject][ordered]@{
            schema = [int64]1
            kind = 'source-oracle-vphysics-sandbox-input-manifest'
            steam = [pscustomobject][ordered]@{
                app_id = [int64]4020
                branch = 'x86-64'
                build_id = [string]$spec.steam.build_id
            }
            model = [pscustomobject][ordered]@{
                model_path = [string]$spec.model.model_path
                phy_path = [string]$spec.model.phy_path
            }
            files = $orderedRecords
        }
        $manifestPath = [IO.Path]::Combine($inputRoot, 'input-manifest.json')
        Write-SourceOracleSandboxUTF8 -Path $manifestPath `
            -Text (($manifest | ConvertTo-Json -Depth 16) + "`r`n")
        $manifestFingerprint = Get-SourceOracleSandboxFileFingerprint `
            -Path $manifestPath -MaximumBytes $script:VPhysicsSandboxMetadataByteCap

        $finalInput = [IO.Path]::Combine($workspaceFull, 'input')
        $finalOutput = [IO.Path]::Combine($workspaceFull, 'output')
        $wsbPath = [IO.Path]::Combine($temporary, 'SourceVPhysicsAttestation.wsb')
        Write-SourceOracleSandboxUTF8 -Path $wsbPath `
            -Text (New-SourceOracleSandboxWSBText `
                -InputPath $finalInput -OutputPath $finalOutput)

        $payloadBytes = [int64]0
        foreach ($record in $orderedRecords) {
            $payloadBytes += [int64]$record.byte_count
        }
        $state = [pscustomobject][ordered]@{
            schema = [int64]1
            kind = 'source-oracle-vphysics-sandbox-workspace'
            probe_enabled = $false
            prerequisites_verified = $true
            steam = [pscustomobject][ordered]@{
                app_id = [int64]4020
                branch = 'x86-64'
                build_id = [string]$spec.steam.build_id
            }
            policy = [pscustomobject][ordered]@{
                networking = 'Disable'
                input_mapping = 'read-only'
                output_mapping = 'writable-empty'
                allow_inherited_addons = $false
                allow_inherited_user_lua = $false
            }
            files = [pscustomobject][ordered]@{
                input_manifest = 'input/input-manifest.json'
                input_manifest_sha256 = $manifestFingerprint.sha256
                input_file_count = [int64]($orderedRecords.Count + 1)
                input_payload_bytes = $payloadBytes
                sandbox_config = 'SourceVPhysicsAttestation.wsb'
            }
        }
        Write-SourceOracleSandboxUTF8 -Path ([IO.Path]::Combine($temporary, 'workspace.json')) `
            -Text (($state | ConvertTo-Json -Depth 12) + "`r`n")

        [IO.Directory]::Move($temporary, $workspaceFull)
        $committed = $true
        [void](Assert-SourceOracleVPhysicsSandboxWorkspace -WorkspacePath $workspaceFull)
        return $state
    } catch {
        if ($committed -and [IO.Directory]::Exists($workspaceFull)) {
            [IO.Directory]::Delete($workspaceFull, $true)
        } elseif ([IO.Directory]::Exists($temporary)) {
            [IO.Directory]::Delete($temporary, $true)
        }
        throw
    }
}

function Get-SourceOracleSandboxBoundedTreeFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Root)

    $fullRoot = Assert-SourceOracleSandboxNoReparsePath -Root $Root -RequireDirectory
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($fullRoot)
    $files = [Collections.Generic.List[string]]::new()
    $directoryCount = 0
    while ($queue.Count -ne 0) {
        $directory = $queue.Dequeue()
        $directoryCount++
        if ($directoryCount -gt $script:VPhysicsSandboxMaximumDirectories) {
            throw 'Input directory tree exceeds its bounded directory count'
        }
        foreach ($entry in [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos()) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Input tree contains a reparse point: $($entry.FullName)"
            }
            if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                $queue.Enqueue($entry.FullName)
            } else {
                $relative = $entry.FullName.Substring($fullRoot.Length).TrimStart('\').Replace('\', '/')
                Assert-SourceOracleSandboxRelativePath -Value $relative -Field 'input tree path'
                $files.Add($relative)
                if ($files.Count -gt ($script:VPhysicsSandboxMaximumFiles + 4)) {
                    throw 'Input tree exceeds its bounded file count'
                }
            }
        }
    }
    return @($files | Sort-Object)
}

function Read-SourceOracleSandboxXML {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    $info = [IO.FileInfo]::new([IO.Path]::GetFullPath($Path))
    if (-not $info.Exists -or $info.Length -le 0 -or $info.Length -gt 65536) {
        throw 'Sandbox config byte count is outside 1...65536'
    }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($info.FullName, $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        return $document
    } finally {
        $reader.Dispose()
    }
}

function Assert-SourceOracleVPhysicsSandboxWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$WorkspacePath)

    $workspace = Assert-SourceOracleSandboxNoReparsePath `
        -Root $WorkspacePath -RequireDirectory
    $statePath = Assert-SourceOracleSandboxNoReparsePath -Root $workspace `
        -RelativePath 'workspace.json' -RequireFile
    $state = Read-SourceOracleSandboxBoundedJSON -Path $statePath `
        -MaximumBytes 65536 -Field 'sandbox workspace state'
    Assert-SourceOracleSandboxObjectShape -InputObject $state -Field 'workspace state' -Names @(
        'schema', 'kind', 'probe_enabled', 'prerequisites_verified',
        'steam', 'policy', 'files'
    )
    [void](Get-SourceOracleSandboxInteger -InputObject $state -Name 'schema' -Minimum 1 -Maximum 1)
    if ((Get-SourceOracleSandboxString -InputObject $state -Name 'kind' -MaximumLength 96) `
        -cne 'source-oracle-vphysics-sandbox-workspace') {
        throw 'Workspace state kind is unsupported'
    }
    foreach ($name in @('probe_enabled', 'prerequisites_verified')) {
        $property = $state.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [bool]) {
            throw "workspace.$name must be a JSON boolean"
        }
    }
    if ([bool]$state.probe_enabled) { throw 'Prerequisite workspace must not enable a probe' }
    if (-not [bool]$state.prerequisites_verified) {
        throw 'Workspace prerequisites are not marked verified'
    }

    Assert-SourceOracleSandboxObjectShape -InputObject $state.steam -Field 'workspace.steam' `
        -Names @('app_id', 'branch', 'build_id')
    [void](Get-SourceOracleSandboxInteger -InputObject $state.steam `
        -Name 'app_id' -Minimum 4020 -Maximum 4020)
    if ((Get-SourceOracleSandboxString -InputObject $state.steam `
        -Name 'branch' -MaximumLength 32) -cne 'x86-64') {
        throw 'Workspace branch is not x86-64'
    }
    $buildID = Get-SourceOracleSandboxString -InputObject $state.steam `
        -Name 'build_id' -MaximumLength 20

    Assert-SourceOracleSandboxObjectShape -InputObject $state.policy -Field 'workspace.policy' `
        -Names @(
            'networking', 'input_mapping', 'output_mapping',
            'allow_inherited_addons', 'allow_inherited_user_lua'
        )
    if ((Get-SourceOracleSandboxString -InputObject $state.policy `
        -Name 'networking' -MaximumLength 16) -cne 'Disable' -or
        (Get-SourceOracleSandboxString -InputObject $state.policy `
        -Name 'input_mapping' -MaximumLength 16) -cne 'read-only' -or
        (Get-SourceOracleSandboxString -InputObject $state.policy `
        -Name 'output_mapping' -MaximumLength 32) -cne 'writable-empty') {
        throw 'Workspace mapping or networking policy changed'
    }
    foreach ($name in @('allow_inherited_addons', 'allow_inherited_user_lua')) {
        $property = $state.policy.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [bool] -or
            [bool]$property.Value) {
            throw "workspace.policy.$name must be false"
        }
    }

    Assert-SourceOracleSandboxObjectShape -InputObject $state.files -Field 'workspace.files' `
        -Names @(
            'input_manifest', 'input_manifest_sha256', 'input_file_count',
            'input_payload_bytes', 'sandbox_config'
        )
    if ((Get-SourceOracleSandboxString -InputObject $state.files `
        -Name 'input_manifest' -MaximumLength 64) -cne 'input/input-manifest.json' -or
        (Get-SourceOracleSandboxString -InputObject $state.files `
        -Name 'sandbox_config' -MaximumLength 64) -cne 'SourceVPhysicsAttestation.wsb') {
        throw 'Workspace metadata paths changed'
    }
    $expectedManifestSHA = Get-SourceOracleSandboxString -InputObject $state.files `
        -Name 'input_manifest_sha256' -MaximumLength 64
    Assert-SourceOracleSandboxSHA256 -Value $expectedManifestSHA `
        -Field 'workspace input manifest SHA-256'
    $expectedFileCount = Get-SourceOracleSandboxInteger -InputObject $state.files `
        -Name 'input_file_count' -Minimum 1 -Maximum ($script:VPhysicsSandboxMaximumFiles + 4)
    [void](Get-SourceOracleSandboxInteger -InputObject $state.files `
        -Name 'input_payload_bytes' -Minimum 1 -Maximum $script:VPhysicsSandboxMaximumTotalBytes)

    $inputRoot = Assert-SourceOracleSandboxNoReparsePath -Root $workspace `
        -RelativePath 'input' -RequireDirectory
    $outputRoot = Assert-SourceOracleSandboxNoReparsePath -Root $workspace `
        -RelativePath 'output' -RequireDirectory
    $outputEnumerator = [IO.Directory]::EnumerateFileSystemEntries($outputRoot).GetEnumerator()
    try {
        if ($outputEnumerator.MoveNext()) {
            throw 'Writable sandbox output is not empty'
        }
    } finally {
        if ($outputEnumerator -is [IDisposable]) { $outputEnumerator.Dispose() }
    }

    $manifestPath = Assert-SourceOracleSandboxNoReparsePath -Root $inputRoot `
        -RelativePath 'input-manifest.json' -RequireFile
    $manifestFingerprint = Get-SourceOracleSandboxFileFingerprint `
        -Path $manifestPath -MaximumBytes $script:VPhysicsSandboxMetadataByteCap
    if ($manifestFingerprint.sha256 -cne $expectedManifestSHA) {
        throw 'Input manifest SHA-256 does not match workspace state'
    }
    $manifest = Read-SourceOracleSandboxBoundedJSON -Path $manifestPath `
        -MaximumBytes $script:VPhysicsSandboxMetadataByteCap -Field 'sandbox input manifest'
    Assert-SourceOracleSandboxObjectShape -InputObject $manifest -Field 'input manifest' `
        -Names @('schema', 'kind', 'steam', 'model', 'files')
    [void](Get-SourceOracleSandboxInteger -InputObject $manifest -Name 'schema' -Minimum 1 -Maximum 1)
    if ((Get-SourceOracleSandboxString -InputObject $manifest `
        -Name 'kind' -MaximumLength 96) -cne 'source-oracle-vphysics-sandbox-input-manifest') {
        throw 'Input manifest kind is unsupported'
    }
    if ([string]$manifest.steam.build_id -cne $buildID) {
        throw 'Input manifest build ID differs from workspace state'
    }
    if ($manifest.files -isnot [array]) { throw 'Input manifest files must be an array' }
    $records = @($manifest.files)
    if (($records.Count + 1) -ne $expectedFileCount) {
        throw 'Input manifest file count differs from workspace state'
    }
    $manifestPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $roles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $records) {
        Assert-SourceOracleSandboxObjectShape -InputObject $record -Field 'manifest file' `
            -Names @('path', 'role', 'sha256', 'byte_count')
        $relative = Get-SourceOracleSandboxString -InputObject $record `
            -Name 'path' -MaximumLength 512
        Assert-SourceOracleSandboxRelativePath -Value $relative -Field 'manifest file path'
        if ($relative -match '(?i)(^|/)addons(/|$)') {
            throw 'Input manifest contains inherited addons content'
        }
        if (-not $manifestPaths.Add($relative)) {
            throw "Input manifest duplicates path $relative"
        }
        [void]$roles.Add((Get-SourceOracleSandboxString -InputObject $record `
            -Name 'role' -MaximumLength 64))
        $sha = Get-SourceOracleSandboxString -InputObject $record `
            -Name 'sha256' -MaximumLength 64
        Assert-SourceOracleSandboxSHA256 -Value $sha -Field 'manifest file sha256'
        $bytes = Get-SourceOracleSandboxInteger -InputObject $record `
            -Name 'byte_count' -Minimum 1 -Maximum $script:VPhysicsSandboxMaximumFileBytes
        $filePath = Assert-SourceOracleSandboxNoReparsePath -Root $inputRoot `
            -RelativePath $relative -RequireFile
        $fingerprint = Get-SourceOracleSandboxFileFingerprint -Path $filePath -MaximumBytes $bytes
        if ($fingerprint.byte_count -ne $bytes -or $fingerprint.sha256 -cne $sha) {
            throw "Input file differs from manifest: $relative"
        }
    }
    foreach ($role in @(
        $script:VPhysicsSandboxRequiredRoles + @(
            'empty_mount_config', 'empty_mountdepots_config', 'validated_input_spec'
        )
    )) {
        if (-not $roles.Contains($role)) { throw "Input manifest is missing role $role" }
    }

    $treeFiles = @(Get-SourceOracleSandboxBoundedTreeFiles -Root $inputRoot)
    if ($treeFiles.Count -ne ($manifestPaths.Count + 1)) {
        throw 'Input mapping contains unmanifested files'
    }
    foreach ($relative in $treeFiles) {
        if ($relative -cne 'input-manifest.json' -and -not $manifestPaths.Contains($relative)) {
            throw "Input mapping contains unmanifested file $relative"
        }
    }
    $mountText = [IO.File]::ReadAllText(
        (Get-SourceOracleSandboxChildPath -Root $inputRoot `
            -RelativePath 'oracle_game/cfg/mount.cfg'),
        [Text.UTF8Encoding]::new($false, $true)
    )
    $depotsText = [IO.File]::ReadAllText(
        (Get-SourceOracleSandboxChildPath -Root $inputRoot `
            -RelativePath 'oracle_game/cfg/mountdepots.txt'),
        [Text.UTF8Encoding]::new($false, $true)
    )
    if ($mountText -cne $script:VPhysicsSandboxEmptyMount -or
        $depotsText -cne $script:VPhysicsSandboxEmptyDepots) {
        throw 'Mount configuration is not explicitly empty'
    }
    $spec = Read-SourceOracleVPhysicsSandboxInputSpec -Path (
        Get-SourceOracleSandboxChildPath -Root $inputRoot -RelativePath 'input-spec.json'
    )
    if ([string]$spec.steam.build_id -cne $buildID -or
        [string]$spec.model.model_path -cne [string]$manifest.model.model_path -or
        [string]$spec.model.phy_path -cne [string]$manifest.model.phy_path) {
        throw 'Validated input spec differs from workspace manifest'
    }

    $wsbPath = Assert-SourceOracleSandboxNoReparsePath -Root $workspace `
        -RelativePath 'SourceVPhysicsAttestation.wsb' -RequireFile
    $xml = Read-SourceOracleSandboxXML -Path $wsbPath
    if ($xml.DocumentElement.Name -cne 'Configuration' -or
        $xml.SelectNodes('/Configuration/Networking').Count -ne 1 -or
        $xml.SelectSingleNode('/Configuration/Networking').InnerText -cne 'Disable' -or
        $xml.SelectNodes('//LogonCommand').Count -ne 0) {
        throw 'Sandbox config does not enforce nonlaunch networking isolation'
    }
    foreach ($name in @(
        'vGPU', 'AudioInput', 'VideoInput', 'PrinterRedirection', 'ClipboardRedirection'
    )) {
        $nodes = $xml.SelectNodes("/Configuration/$name")
        if ($nodes.Count -ne 1 -or $nodes[0].InnerText -cne 'Disable') {
            throw "Sandbox config does not disable $name"
        }
    }
    $mappings = @($xml.SelectNodes('/Configuration/MappedFolders/MappedFolder'))
    if ($mappings.Count -ne 2) { throw 'Sandbox config must contain exactly two mappings' }
    $mappingBySandbox = @{}
    foreach ($mapping in $mappings) {
        $children = @($mapping.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
        if ($children.Count -ne 3) { throw 'Sandbox mapping has unexpected fields' }
        $sandboxFolder = [string]$mapping.SandboxFolder
        if ($mappingBySandbox.ContainsKey($sandboxFolder)) {
            throw 'Sandbox mapping duplicates a sandbox path'
        }
        $mappingBySandbox[$sandboxFolder] = $mapping
    }
    $inputMapping = $mappingBySandbox['C:\GarrysPAD\Input']
    $outputMapping = $mappingBySandbox['C:\GarrysPAD\Output']
    if ($null -eq $inputMapping -or $null -eq $outputMapping -or
        [IO.Path]::GetFullPath([string]$inputMapping.HostFolder) -cne $inputRoot -or
        [IO.Path]::GetFullPath([string]$outputMapping.HostFolder) -cne $outputRoot -or
        [string]$inputMapping.ReadOnly -cne 'true' -or
        [string]$outputMapping.ReadOnly -cne 'false') {
        throw 'Sandbox input/output mappings are not separate read-only/writable paths'
    }
    return $state
}
