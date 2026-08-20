Set-StrictMode -Version 3.0

function Test-SourceOraclePathUnderRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    return $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SourceOracleBooleanProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    return $null -ne $property -and
        $property.Value -is [bool] -and
        $property.Value
}

function Test-SourceOracleSchemaProperty {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$InputObject)

    $property = $InputObject.PSObject.Properties['schema']
    if ($null -eq $property) { return $false }
    $value = $property.Value
    $isInteger = $value -is [byte] -or $value -is [sbyte] -or
        $value -is [int16] -or $value -is [uint16] -or
        $value -is [int32] -or $value -is [uint32] -or
        $value -is [int64] -or $value -is [uint64]
    return $isInteger -and [uint64]$value -eq 1
}

function Assert-SourceOracleResultObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Result,
        [Parameter(Mandatory)] [string]$RunID,
        [Parameter(Mandatory)] [ValidateSet('SERVER', 'CLIENT')] [string]$Realm
    )

    if ($RunID -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Expected run_id is not a lowercase 32-hex launch token'
    }
    if ($Result -is [array] -or $null -eq $Result.PSObject) {
        throw 'Oracle result must be one JSON object'
    }
    if (-not (Test-SourceOracleSchemaProperty -InputObject $Result)) {
        throw 'Oracle result schema is missing, not an integer, or unsupported'
    }
    if (-not (Test-SourceOracleBooleanProperty -InputObject $Result -Name 'enabled')) {
        throw 'Oracle result enabled is missing or not the JSON boolean true'
    }
    if (-not (Test-SourceOracleBooleanProperty -InputObject $Result -Name 'command_line_enabled')) {
        throw 'Oracle result command_line_enabled is missing or not the JSON boolean true'
    }

    $runIDProperty = $Result.PSObject.Properties['run_id']
    if ($null -eq $runIDProperty -or
        $runIDProperty.Value -isnot [string] -or
        -not [string]::Equals($runIDProperty.Value, $RunID, [StringComparison]::Ordinal)) {
        throw 'Oracle result run_id does not match the launched run'
    }

    $commandLineRunIDProperty = $Result.PSObject.Properties['command_line_run_id']
    if ($null -eq $commandLineRunIDProperty -or
        $commandLineRunIDProperty.Value -isnot [string] -or
        -not [string]::Equals(
            $commandLineRunIDProperty.Value,
            $RunID,
            [StringComparison]::Ordinal
        )) {
        throw 'Oracle result command_line_run_id does not match the launched run'
    }

    $realmProperty = $Result.PSObject.Properties['realm']
    if ($null -eq $realmProperty -or
        $realmProperty.Value -isnot [string] -or
        -not [string]::Equals($realmProperty.Value, $Realm, [StringComparison]::Ordinal)) {
        throw "Oracle result realm does not match $Realm"
    }

    $expectedFinishReason = if ($Realm -ceq 'SERVER') { 'sequence-complete' } else { 'complete' }
    $finishReasonProperty = $Result.PSObject.Properties['finish_reason']
    if ($null -eq $finishReasonProperty -or
        $finishReasonProperty.Value -isnot [string] -or
        -not [string]::Equals(
            $finishReasonProperty.Value,
            $expectedFinishReason,
            [StringComparison]::Ordinal
        )) {
        throw "Oracle result finish_reason is not the successful $Realm completion reason"
    }

    $probeErrorProperty = $Result.PSObject.Properties['probe_error']
    if ($null -ne $probeErrorProperty -and $null -ne $probeErrorProperty.Value) {
        throw 'Oracle result contains probe_error'
    }
    return $Result
}

function Read-SourceOracleResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RunID,
        [Parameter(Mandatory)] [ValidateSet('SERVER', 'CLIENT')] [string]$Realm
    )

    $result = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    return Assert-SourceOracleResultObject -Result $result -RunID $RunID -Realm $Realm
}

function Import-SourceOracleOwnedProcessJob {
    [CmdletBinding()]
    param()

    if ($null -eq ('SourceOracleOwnedProcessJob' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'SourceOracleOwnedProcessJob.cs')
    }
}

function Import-SourceOracleOwnedMount {
    [CmdletBinding()]
    param()

    if ($null -eq ('SourceOracleOwnedMount' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'SourceOracleOwnedMount.cs')
    }
}

function Enter-SourceOracleLaunchMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$GModRoot)

    $canonicalRoot = [IO.Path]::GetFullPath($GModRoot).TrimEnd('\').ToUpperInvariant()
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonicalRoot)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha256.Dispose()
    }

    # Global namespace serializes the same install across terminal sessions.
    # If policy denies a global kernel object, construction fails closed.
    $mutex = [Threading.Mutex]::new($false, "Global\GarrysPAD.SourceOracle.$digest")
    try {
        if (-not $mutex.WaitOne(0)) {
            throw 'Another Source oracle runner already owns this GMod root'
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Assert-SourceOracleNoRunningGMod {
    [CmdletBinding()]
    param()

    try {
        $existing = @([Diagnostics.Process]::GetProcessesByName('gmod'))
    } catch {
        throw "Could not complete the read-only existing-GMod preflight: $($_.Exception.Message)"
    }

    try {
        if ($existing.Count -ne 0) {
            $ids = ($existing | ForEach-Object { $_.Id } | Sort-Object) -join ', '
            throw "A gmod.exe process is already running (PID(s) $ids); refusing to launch or stop anything"
        }
    } finally {
        foreach ($process in $existing) { $process.Dispose() }
    }
}

function Assert-SourceOracleNoStaleMounts {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$AddonsRoot)

    if (-not (Test-Path -LiteralPath $AddonsRoot -PathType Container)) { return }
    $prefixes = @('garryspad_source_oracle_')
    $legacyNames = @('garryspad_source_oracle', 'garryspad_source_client_oracle')
    $stale = @(Get-ChildItem -LiteralPath $AddonsRoot -Directory -Force -ErrorAction Stop |
        Where-Object {
            $name = $_.Name
            @($legacyNames | Where-Object {
                [string]::Equals($name, $_, [StringComparison]::OrdinalIgnoreCase)
            }).Count -ne 0 -or @($prefixes | Where-Object {
                $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
            }).Count -ne 0
        })
    if ($stale.Count -ne 0) {
        $paths = ($stale | ForEach-Object { $_.FullName }) -join '; '
        throw "Stale Source oracle mount(s) require manual audit; nothing was removed: $paths"
    }
}
