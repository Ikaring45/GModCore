Set-StrictMode -Version 3.0

$script:VPhysicsSandboxRunKind = 'source-oracle-vphysics-sandbox-single-run'
$script:VPhysicsSandboxRunMap = 'gm_flatgrass'
$script:VPhysicsSandboxRunGamemode = 'garryspad_attestation'
$script:VPhysicsSandboxRunProbeTimeoutSeconds = 20
$script:VPhysicsSandboxRunGuestTimeoutSeconds = 60
$script:VPhysicsSandboxRunHostTimeoutSeconds = 90
$script:VPhysicsSandboxRunConfigName = 'LaunchSourceVPhysicsAttestation.wsb'
$script:VPhysicsSandboxRunGuestScript =
    'sandbox/Run-SourceOracleVPhysicsSandboxGuest.ps1'
$script:VPhysicsSandboxRunGuestCommand =
    'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe ' +
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    'C:\GarrysPAD\Input\sandbox\Run-SourceOracleVPhysicsSandboxGuest.ps1'

function New-SourceOracleVPhysicsFixedRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RequestID,
        [Parameter(Mandatory)] [object]$Metadata
    )
    if ($RequestID -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Request ID must be lowercase 32-hex'
    }
    $entry = @($Metadata.allowlist.models)
    if ($entry.Count -ne 1) { throw 'Fixed metadata must allow exactly one model' }
    $surfaceInputs = @($script:SourceOracleSurfaceContract.SurfaceInputs | ForEach-Object {
        [pscustomobject][ordered]@{
            path = [string]$_.path
            sha256 = [string]$_.sha256
        }
    })
    $worldTraces = @($script:SourceOracleSurfaceContract.WorldTraces | ForEach-Object {
        [pscustomobject][ordered]@{
            id = [string]$_.id
            start = [pscustomobject][ordered]@{
                x = [int64]$_.start.x; y = [int64]$_.start.y; z = [int64]$_.start.z
            }
            end = [pscustomobject][ordered]@{
                x = [int64]$_.end.x; y = [int64]$_.end.y; z = [int64]$_.end.z
            }
        }
    })
    $request = [pscustomobject][ordered]@{
        schema = [int64]2
        request_id = $RequestID
        model_path = [string]$entry[0].model_path
        phy_path = [string]$entry[0].phy_path
        expected_mdl_sha256 = [string]$entry[0].mdl_sha256
        expected_phy_sha256 = [string]$entry[0].phy_sha256
        ownership_reference = [string]$entry[0].ownership_reference
        policy = [pscustomobject][ordered]@{
            search_path = 'GAME'
            allow_workshop = $false
            allow_installed_addons = $false
            allow_user_lua = $false
            allow_network = $false
        }
        limits = [pscustomobject][ordered]@{
            maximum_mdl_bytes = [int64]2540
            maximum_phy_bytes = [int64]880
            maximum_solids = [int64]1
            maximum_convexes = [int64]4
            maximum_vertices_per_convex = [int64]256
            maximum_total_vertices = [int64]256
            maximum_result_bytes = [int64]65536
            timeout_seconds = [int64]$script:VPhysicsSandboxRunProbeTimeoutSeconds
        }
        surface_probe = [pscustomobject][ordered]@{
            schema = [int64]1
            provenance = [pscustomobject][ordered]@{
                app_id = [int64]$script:SourceOracleSurfaceContract.AppID
                branch = [string]$script:SourceOracleSurfaceContract.Branch
                build_id = [string]$script:SourceOracleSurfaceContract.BuildID
                request_id = $RequestID
                vphysics = [pscustomobject][ordered]@{
                    path = [string]$script:SourceOracleSurfaceContract.VPhysicsPath
                    sha256 = [string]$script:SourceOracleSurfaceContract.VPhysicsSHA256
                }
                surface_inputs = $surfaceInputs
                map = [pscustomobject][ordered]@{
                    path = [string]$script:SourceOracleSurfaceContract.MapPath
                    sha256 = [string]$script:SourceOracleSurfaceContract.MapSHA256
                }
            }
            requested_surface_names = @(
                $script:SourceOracleSurfaceContract.RequestedSurfaceNames
            )
            world_traces = $worldTraces
            controlled_pair = [pscustomobject][ordered]@{
                pair_id = [string]$script:SourceOracleSurfaceContract.PairID
                moving_surface_name =
                    [string]$script:SourceOracleSurfaceContract.MovingSurfaceName
                fixed_surface_name =
                    [string]$script:SourceOracleSurfaceContract.FixedSurfaceName
                anchor_trace_id = [string]$script:SourceOracleSurfaceContract.AnchorTraceID
                separation_units =
                    [int64]$script:SourceOracleSurfaceContract.SeparationUnits
                impact_speed_units_per_second =
                    [int64]$script:SourceOracleSurfaceContract.ImpactSpeedUnitsPerSecond
                sample_delay_milliseconds =
                    [int64]$script:SourceOracleSurfaceContract.SampleDelayMilliseconds
                maximum_friction_snapshots =
                    [int64]$script:SourceOracleSurfaceContract.MaximumFrictionSnapshots
            }
        }
    }
    return Assert-SourceOracleVPhysicsRequestObject `
        -Request $request `
        -Allowlist $Metadata.allowlist
}

function New-SourceOracleVPhysicsLaunchWSBText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$InputPath,
        [Parameter(Mandatory)] [string]$RequestPath,
        [Parameter(Mandatory)] [string]$OutputPath
    )
    $escapedInput = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath($InputPath))
    $escapedRequest = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath($RequestPath))
    $escapedOutput = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath($OutputPath))
    $escapedCommand = [Security.SecurityElement]::Escape(
        $script:VPhysicsSandboxRunGuestCommand
    )
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
      <HostFolder>$escapedRequest</HostFolder>
      <SandboxFolder>C:\GarrysPAD\Request</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$escapedOutput</HostFolder>
      <SandboxFolder>C:\GarrysPAD\Output</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$escapedCommand</Command>
  </LogonCommand>
</Configuration>
"@
}

function New-SourceOracleVPhysicsSandboxRunBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$RunPath
    )

    $workspaceState = Assert-SourceOracleVPhysicsSandboxWorkspace `
        -WorkspacePath $WorkspacePath
    $workspace = [IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\')
    $inputRoot = Assert-SourceOracleSandboxNoReparsePath `
        -Root $workspace `
        -RelativePath 'input' `
        -RequireDirectory
    $run = [IO.Path]::GetFullPath($RunPath).TrimEnd('\')
    if ([IO.Directory]::Exists($run) -or [IO.File]::Exists($run)) {
        throw "Run path already exists: $run"
    }
    $parent = [IO.Path]::GetDirectoryName($run)
    [void](Assert-SourceOracleSandboxNoReparsePath -Root $parent -RequireDirectory)

    $metadata = Read-SourceOracleVPhysicsBoundedJSON `
        -Path (Join-Path $PSScriptRoot `
            'VPhysicsAttestation-Button06-AllowlistMetadata.json') `
        -MaximumBytes 65536 `
        -Field 'button_06 allowlist metadata'
    $runID = [Guid]::NewGuid().ToString('N')
    $requestID = [Guid]::NewGuid().ToString('N')
    $request = New-SourceOracleVPhysicsFixedRequest `
        -RequestID $requestID `
        -Metadata $metadata

    $temporary = [IO.Path]::Combine(
        $parent,
        '.' + [IO.Path]::GetFileName($run) + '.assembling-' +
            [Guid]::NewGuid().ToString('N')
    )
    $committed = $false
    try {
        [void][IO.Directory]::CreateDirectory($temporary)
        $requestRoot = Join-Path $temporary 'request'
        $outputRoot = Join-Path $temporary 'output'
        [void][IO.Directory]::CreateDirectory($requestRoot)
        [void][IO.Directory]::CreateDirectory($outputRoot)
        Write-SourceOracleSandboxUTF8 `
            -Path (Join-Path $requestRoot 'request.json') `
            -Text (($request | ConvertTo-Json -Depth 8) + "`r`n")
        Write-SourceOracleSandboxUTF8 `
            -Path (Join-Path $requestRoot 'run_token.txt') `
            -Text ($runID + "`r`n")

        $finalRequest = Join-Path $run 'request'
        $finalOutput = Join-Path $run 'output'
        $configText = New-SourceOracleVPhysicsLaunchWSBText `
            -InputPath $inputRoot `
            -RequestPath $finalRequest `
            -OutputPath $finalOutput
        Write-SourceOracleSandboxUTF8 `
            -Path (Join-Path $temporary $script:VPhysicsSandboxRunConfigName) `
            -Text $configText

        $state = [pscustomobject][ordered]@{
            schema = [int64]1
            kind = $script:VPhysicsSandboxRunKind
            run_id = $runID
            request_id = $requestID
            build_id = '24721267'
            map = $script:VPhysicsSandboxRunMap
            gamemode = $script:VPhysicsSandboxRunGamemode
            probe_timeout_seconds = [int64]$script:VPhysicsSandboxRunProbeTimeoutSeconds
            guest_timeout_seconds = [int64]$script:VPhysicsSandboxRunGuestTimeoutSeconds
            host_timeout_seconds = [int64]$script:VPhysicsSandboxRunHostTimeoutSeconds
            workspace = $workspace
            input_manifest_sha256 =
                [string]$workspaceState.files.input_manifest_sha256
            request_file = 'request/request.json'
            token_file = 'request/run_token.txt'
            output_file = 'output/result.json'
            failure_file = 'output/failure.json'
            sandbox_config = $script:VPhysicsSandboxRunConfigName
        }
        Write-SourceOracleSandboxUTF8 `
            -Path (Join-Path $temporary 'run-state.json') `
            -Text (($state | ConvertTo-Json -Depth 6) + "`r`n")
        [IO.Directory]::Move($temporary, $run)
        $committed = $true
        return [pscustomobject][ordered]@{
            state = $state
            workspace_state = $workspaceState
            request = $request
            run_path = $run
            input_path = $inputRoot
            request_path = $finalRequest
            output_path = $finalOutput
            config_path = Join-Path $run $script:VPhysicsSandboxRunConfigName
        }
    } finally {
        if (-not $committed -and [IO.Directory]::Exists($temporary)) {
            [IO.Directory]::Delete($temporary, $true)
        }
    }
}

function Assert-SourceOracleVPhysicsSandboxRunBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Bundle)

    $state = $Bundle.state
    Assert-SourceOracleSandboxObjectShape -InputObject $state -Field 'run state' -Names @(
        'schema', 'kind', 'run_id', 'request_id', 'build_id', 'map', 'gamemode',
        'probe_timeout_seconds', 'guest_timeout_seconds', 'host_timeout_seconds',
        'workspace', 'input_manifest_sha256', 'request_file', 'token_file',
        'output_file', 'failure_file', 'sandbox_config'
    )
    [void](Get-SourceOracleSandboxInteger -InputObject $state `
        -Name 'schema' -Minimum 1 -Maximum 1)
    if ([string]$state.kind -cne $script:VPhysicsSandboxRunKind -or
        [string]$state.build_id -cne '24721267' -or
        [string]$state.map -cne $script:VPhysicsSandboxRunMap -or
        [string]$state.gamemode -cne $script:VPhysicsSandboxRunGamemode -or
        [int64]$state.probe_timeout_seconds -ne
            $script:VPhysicsSandboxRunProbeTimeoutSeconds -or
        [int64]$state.guest_timeout_seconds -ne
            $script:VPhysicsSandboxRunGuestTimeoutSeconds -or
        [int64]$state.host_timeout_seconds -ne
            $script:VPhysicsSandboxRunHostTimeoutSeconds) {
        throw 'Run state fixed build, map, gamemode, or timeout changed'
    }
    foreach ($name in @('run_id', 'request_id')) {
        if ([string]$state.PSObject.Properties[$name].Value -cnotmatch '^[0-9a-f]{32}$') {
            throw "run state $name is invalid"
        }
    }
    if ([string]$state.input_manifest_sha256 -cne
        [string]$Bundle.workspace_state.files.input_manifest_sha256) {
        throw 'Run state is not bound to the validated input manifest'
    }

    $run = Assert-SourceOracleSandboxNoReparsePath `
        -Root ([string]$Bundle.run_path) `
        -RequireDirectory
    $requestRoot = Assert-SourceOracleSandboxNoReparsePath `
        -Root $run -RelativePath 'request' -RequireDirectory
    $outputRoot = Assert-SourceOracleSandboxNoReparsePath `
        -Root $run -RelativePath 'output' -RequireDirectory
    $requestEntries = @(Get-ChildItem -LiteralPath $requestRoot -Force)
    if ($requestEntries.Count -ne 2 -or
        (@($requestEntries.Name | Sort-Object) -join ',') -cne
            'request.json,run_token.txt') {
        throw 'Host request handoff is not exactly request.json plus run_token.txt'
    }
    if (@(Get-ChildItem -LiteralPath $outputRoot -Force).Count -ne 0) {
        throw 'Host writable result handoff is not empty before launch'
    }
    $token = [IO.File]::ReadAllText(
        (Join-Path $requestRoot 'run_token.txt'),
        [Text.UTF8Encoding]::new($false, $true)
    ).Trim()
    if ($token -cne [string]$state.run_id) {
        throw 'Host run token differs from run state'
    }
    $requestObject = Read-SourceOracleVPhysicsBoundedJSON `
        -Path (Join-Path $requestRoot 'request.json') `
        -MaximumBytes 65536 `
        -Field 'host VPhysics request'
    $metadata = Read-SourceOracleVPhysicsBoundedJSON `
        -Path (Join-Path $PSScriptRoot `
            'VPhysicsAttestation-Button06-AllowlistMetadata.json') `
        -MaximumBytes 65536 `
        -Field 'button_06 allowlist metadata'
    $validatedRequest = Assert-SourceOracleVPhysicsRequestObject `
        -Request $requestObject `
        -Allowlist $metadata.allowlist
    if ([string]$validatedRequest.request_id -cne [string]$state.request_id) {
        throw 'Host request ID differs from run state'
    }

    $manifest = Read-SourceOracleSandboxBoundedJSON `
        -Path (Join-Path ([string]$Bundle.input_path) 'input-manifest.json') `
        -MaximumBytes 1048576 `
        -Field 'validated launch input manifest'
    $bootstrap = @($manifest.files | Where-Object {
        [string]$_.role -ceq 'sandbox_bootstrap' -and
        [string]$_.path -ceq $script:VPhysicsSandboxRunGuestScript
    })
    $probe = @($manifest.files | Where-Object {
        [string]$_.role -ceq 'probe_lua' -and
        [string]$_.path -ceq
            'oracle_game/lua/autorun/server/garryspad_source_vphysics_attestation.lua'
    })
    $map = @($manifest.files | Where-Object {
        [string]$_.path -ceq 'oracle_game/maps/gm_flatgrass.bsp'
    })
    if ($bootstrap.Count -ne 1 -or $probe.Count -ne 1 -or $map.Count -ne 1) {
        throw 'Validated launch input is missing the exact bootstrap, probe, or map'
    }
    $provenanceBindings = [ordered]@{
        'server/bin/win64/vphysics.dll' =
            [string]$validatedRequest.surface_probe.provenance.vphysics.sha256
        'oracle_game/maps/gm_flatgrass.bsp' =
            [string]$validatedRequest.surface_probe.provenance.map.sha256
    }
    foreach ($surfaceInput in @(
        $validatedRequest.surface_probe.provenance.surface_inputs
    )) {
        $provenanceBindings['server/' + [string]$surfaceInput.path] =
            [string]$surfaceInput.sha256
    }
    foreach ($binding in $provenanceBindings.GetEnumerator()) {
        $records = @($manifest.files | Where-Object {
            [string]$_.path -ceq [string]$binding.Key
        })
        if ($records.Count -ne 1 -or
            [string]$records[0].sha256 -cne [string]$binding.Value) {
            throw "Validated launch input is not bound to surface provenance $($binding.Key)"
        }
    }

    $xml = Read-SourceOracleSandboxXML -Path ([string]$Bundle.config_path)
    if ($xml.DocumentElement.Name -cne 'Configuration' -or
        $xml.SelectNodes('/Configuration/Networking').Count -ne 1 -or
        $xml.SelectSingleNode('/Configuration/Networking').InnerText -cne 'Disable') {
        throw 'Launch config does not disable Windows Sandbox networking'
    }
    foreach ($name in @(
        'vGPU', 'AudioInput', 'VideoInput', 'PrinterRedirection', 'ClipboardRedirection'
    )) {
        $nodes = $xml.SelectNodes("/Configuration/$name")
        if ($nodes.Count -ne 1 -or $nodes[0].InnerText -cne 'Disable') {
            throw "Launch config does not disable $name"
        }
    }
    $commandNodes = @($xml.SelectNodes('/Configuration/LogonCommand/Command'))
    if ($commandNodes.Count -ne 1 -or
        $commandNodes[0].InnerText -cne $script:VPhysicsSandboxRunGuestCommand) {
        throw 'Launch config guest command changed'
    }
    $mappings = @($xml.SelectNodes('/Configuration/MappedFolders/MappedFolder'))
    if ($mappings.Count -ne 3) { throw 'Launch config must contain exactly three mappings' }
    $expected = [ordered]@{
        'C:\GarrysPAD\Input' = @([string]$Bundle.input_path, 'true')
        'C:\GarrysPAD\Request' = @($requestRoot, 'true')
        'C:\GarrysPAD\Output' = @($outputRoot, 'false')
    }
    foreach ($mapping in $mappings) {
        $sandboxPath = [string]$mapping.SandboxFolder
        if (-not $expected.Contains($sandboxPath)) {
            throw "Launch config has an unexpected mapping $sandboxPath"
        }
        $pair = $expected[$sandboxPath]
        if ([IO.Path]::GetFullPath([string]$mapping.HostFolder) -cne
            [IO.Path]::GetFullPath([string]$pair[0]) -or
            [string]$mapping.ReadOnly -cne [string]$pair[1]) {
            throw "Launch config mapping differs for $sandboxPath"
        }
        $expected.Remove($sandboxPath)
    }
    if ($expected.Count -ne 0) { throw 'Launch config is missing a fixed mapping' }
    return $Bundle
}

function Read-SourceOracleVPhysicsGuestFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RunID,
        [Parameter(Mandatory)] [string]$RequestID
    )
    $failure = Read-SourceOracleVPhysicsBoundedJSON `
        -Path $Path -MaximumBytes 16384 -Field 'sandbox guest failure'
    Assert-SourceOracleVPhysicsObjectShape -InputObject $failure `
        -Field 'sandbox guest failure' `
        -Names @(
            'schema', 'kind', 'run_id', 'request_id', 'error',
            'srcds_exit_code', 'srcds_timed_out', 'stdout_tail', 'stderr_tail'
        )
    if ([int64]$failure.schema -ne 1 -or
        [string]$failure.kind -cne 'source-oracle-vphysics-sandbox-guest-failure' -or
        [string]$failure.run_id -cne $RunID -or
        [string]$failure.request_id -cne $RequestID) {
        throw 'Sandbox guest failure authentication differs'
    }
    [void](Get-SourceOracleVPhysicsString `
        -InputObject $failure -Name 'error' -MaximumLength 512
    )
    $exitProperty = $failure.PSObject.Properties['srcds_exit_code']
    if ($null -ne $exitProperty.Value) {
        $exitValue = $exitProperty.Value
        if ($exitValue -is [bool] -or $exitValue -isnot [ValueType] -or
            [double]$exitValue % 1 -ne 0 -or
            [double]$exitValue -lt [int]::MinValue -or
            [double]$exitValue -gt [int]::MaxValue) {
            throw 'Sandbox guest failure srcds_exit_code is not null or int32'
        }
    }
    [void](Get-SourceOracleVPhysicsBoolean `
        -InputObject $failure -Name 'srcds_timed_out')
    [void](Get-SourceOracleVPhysicsString `
        -InputObject $failure -Name 'stdout_tail' -MaximumLength 4096 -AllowEmpty)
    [void](Get-SourceOracleVPhysicsString `
        -InputObject $failure -Name 'stderr_tail' -MaximumLength 4096 -AllowEmpty)
    return $failure
}

function Assert-SourceOracleVPhysicsFinalOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [ValidateSet('result.json', 'failure.json')] [string]$Name
    )
    $entries = @(Get-ChildItem -LiteralPath $OutputPath -Force)
    if ($entries.Count -ne 1 -or $entries[0].PSIsContainer -or
        [string]$entries[0].Name -cne $Name) {
        throw "Sandbox final output is not exactly $Name"
    }
}

function Wait-SourceOracleWindowsSandboxGuestShutdown {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$TimeoutSeconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $existing = @()
        try {
            $existing = @(
                [Diagnostics.Process]::GetProcessesByName('WindowsSandboxServer') +
                [Diagnostics.Process]::GetProcessesByName('WindowsSandboxClient')
            )
            if ($existing.Count -eq 0) { return $true }
        } finally {
            foreach ($process in $existing) { $process.Dispose() }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Assert-SourceOracleNoRunningWindowsSandbox {
    [CmdletBinding()]
    param()
    $existing = @()
    try {
        $existing = @(
            [Diagnostics.Process]::GetProcessesByName('WindowsSandbox') +
            [Diagnostics.Process]::GetProcessesByName('WindowsSandboxClient') +
            [Diagnostics.Process]::GetProcessesByName('WindowsSandboxServer')
        )
        if ($existing.Count -ne 0) {
            $ids = ($existing | ForEach-Object { $_.Id } | Sort-Object -Unique) -join ', '
            throw "Windows Sandbox is already running (PID(s) $ids)"
        }
    } finally {
        foreach ($process in $existing) { $process.Dispose() }
    }
}

function Invoke-SourceOracleVPhysicsPreparedSandboxSingleRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Bundle,
        [switch]$AllowSingleSandboxLaunch
    )
    if (-not $AllowSingleSandboxLaunch) {
        throw 'Single Windows Sandbox launch remains disabled without the explicit switch'
    }
    [void](Assert-SourceOracleVPhysicsSandboxRunBundle -Bundle $bundle)
    $sandboxExecutable = 'C:\Windows\System32\WindowsSandbox.exe'
    if (-not [IO.File]::Exists($sandboxExecutable)) {
        throw 'Windows Sandbox executable is unavailable'
    }
    Assert-SourceOracleNoRunningWindowsSandbox
    Import-SourceOracleOwnedProcessJob

    $mutex = Enter-SourceOracleLaunchMutex -GModRoot ([string]$bundle.input_path)
    $owned = $null
    $validated = $null
    $guestFailure = $null
    $brokerExitCode = $null
    try {
        $owned = [SourceOracleOwnedProcessJob]::Start(
            $sandboxExecutable,
            [string[]]@([string]$bundle.config_path),
            [IO.Path]::GetDirectoryName($sandboxExecutable)
        )
        $deadline = [DateTime]::UtcNow.AddSeconds(
            $script:VPhysicsSandboxRunHostTimeoutSeconds
        )
        $resultPath = Join-Path ([string]$bundle.output_path) 'result.json'
        $failurePath = Join-Path ([string]$bundle.output_path) 'failure.json'
        while ([DateTime]::UtcNow -lt $deadline) {
            if ([IO.File]::Exists($resultPath)) {
                if ([IO.File]::Exists($failurePath)) {
                    throw 'Sandbox returned both success and failure handoffs'
                }
                Assert-SourceOracleVPhysicsFinalOutput `
                    -OutputPath ([string]$bundle.output_path) `
                    -Name 'result.json'
                $validated = Read-SourceOracleVPhysicsResult `
                    -Path $resultPath `
                    -RunID ([string]$bundle.state.run_id) `
                    -Request $bundle.request
                break
            }
            if ([IO.File]::Exists($failurePath)) {
                Assert-SourceOracleVPhysicsFinalOutput `
                    -OutputPath ([string]$bundle.output_path) `
                    -Name 'failure.json'
                $guestFailure = Read-SourceOracleVPhysicsGuestFailure `
                    -Path $failurePath `
                    -RunID ([string]$bundle.state.run_id) `
                    -RequestID ([string]$bundle.state.request_id)
                break
            }
            if ($null -eq $brokerExitCode -and $owned.HasExited) {
                $brokerExitCode = [int]$owned.ExitCode
            }
            Start-Sleep -Milliseconds 200
        }
        if ($null -eq $validated -and $null -eq $guestFailure) {
            if (-not $owned.HasExited) {
                if (-not $owned.TerminateAndWait(10000, [uint32]0xE0560001)) {
                    throw 'Timed-out Windows Sandbox owned Job did not terminate'
                }
                throw 'Windows Sandbox run exceeded the fixed 90-second host timeout'
            }
            if ($null -eq $brokerExitCode) { $brokerExitCode = [int]$owned.ExitCode }
            throw (
                "Windows Sandbox broker exited with code $brokerExitCode, but no " +
                'authenticated guest result/failure arrived before the fixed timeout'
            )
        }

        $exitDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not $owned.HasExited -and [DateTime]::UtcNow -lt $exitDeadline) {
            Start-Sleep -Milliseconds 100
        }
        if (-not $owned.HasExited -and
            -not $owned.TerminateAndWait(10000, [uint32]0xE0560002)) {
            throw 'Validated Windows Sandbox owned Job did not terminate'
        }
        $guestShutdown = Wait-SourceOracleWindowsSandboxGuestShutdown -TimeoutSeconds 30
        if ($null -ne $guestFailure) {
            $exitText = if ($null -eq $guestFailure.srcds_exit_code) {
                'unavailable'
            } else {
                [string]$guestFailure.srcds_exit_code
            }
            throw (
                "Windows Sandbox guest rejected the run: $($guestFailure.error); " +
                "srcds_exit_code=$exitText; timed_out=$($guestFailure.srcds_timed_out); " +
                "stdout_tail=$($guestFailure.stdout_tail); " +
                "stderr_tail=$($guestFailure.stderr_tail); " +
                "sandbox_shutdown=$guestShutdown"
            )
        }
        if (-not $guestShutdown) {
            throw 'Authenticated result arrived but Windows Sandbox did not shut down'
        }
        return [pscustomobject][ordered]@{
            schema = [int64]1
            kind = 'source-oracle-vphysics-sandbox-validated-result'
            run_id = [string]$bundle.state.run_id
            request_id = [string]$bundle.state.request_id
            build_id = [string]$bundle.state.build_id
            map = [string]$validated.runtime.map
            model_path = [string]$validated.model_path
            attestation_status = [string]$validated.surface_response.status
            result_path = Join-Path ([string]$bundle.output_path) 'result.json'
            input_manifest_sha256 = [string]$bundle.state.input_manifest_sha256
            result = $validated
        }
    } finally {
        if ($null -ne $owned) { $owned.Dispose() }
        try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() }
    }
}

function Invoke-SourceOracleVPhysicsSandboxSingleRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WorkspacePath,
        [Parameter(Mandatory)] [string]$RunPath,
        [switch]$AllowSingleSandboxLaunch
    )
    if (-not $AllowSingleSandboxLaunch) {
        throw 'Single Windows Sandbox launch remains disabled without the explicit switch'
    }
    $bundle = New-SourceOracleVPhysicsSandboxRunBundle `
        -WorkspacePath $WorkspacePath `
        -RunPath $RunPath
    return Invoke-SourceOracleVPhysicsPreparedSandboxSingleRun `
        -Bundle $bundle `
        -AllowSingleSandboxLaunch
}
