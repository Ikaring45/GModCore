Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Runs only inside Windows Sandbox. The host maps one manifest-verified input
# read-only, one two-file request read-only, and one initially empty output
# writable. This script copies only manifest entries, launches one fixed x64
# dedicated server, exports one bounded authenticated result, and shuts down
# the disposable VM.

$inputRoot = 'C:\GarrysPAD\Input'
$requestRoot = 'C:\GarrysPAD\Request'
$outputRoot = 'C:\GarrysPAD\Output'
$localRoot = 'C:\GarrysPAD\Run'
$manifestMaximumBytes = 1048576
$maximumManifestFiles = 512
$fixedBuildID = '24721267'
$fixedMap = 'gm_flatgrass'
$fixedGamemode = 'garryspad_attestation'
$fixedModel = 'models/maxofs2d/button_06.mdl'
$fixedPHY = 'models/maxofs2d/button_06.phy'
$fixedMDLSHA = '85dca39870932c39dd1bcd51afbb0fc09aaf8d90fadfeb222e7b49cd784e0f07'
$fixedPHYSHA = '8901ecd8be29b5a3e5b688843bdbea13f34c7b76c5a63cb435f9ef1174527ef3'
$fixedVPhysicsSHA = '4ebd6149f885dfc518a44dd32dda64cbd6ebb3f938d43bdead70e80771b7e414'
$fixedMapSHA = '4dfd95ecb8f77a093e3079697b04c5be5675e8595c05639aaf57ad1541024d76'
$fixedSurfaceInputs = [ordered]@{
    'sourceengine/scripts/surfaceproperties_manifest.txt' =
        'd8bead334f07cd9f7cdfa30d691076b242ee469727aa0f0dcb734f3699d92a11'
    'sourceengine/scripts/surfaceproperties.txt' =
        'b75f463e4a5b351c0f9a155c100659ae0384003ae910d092a07398e611056e32'
    'sourceengine/scripts/surfaceproperties_hl2.txt' =
        '6eb6c622f9d566515d0909d610c6f7213d327ed69545807696d74162ee3c0280'
}
$fixedOwnership =
    'user-owned-playable-manifest-sha256:' +
    '2755c232b55cfe6f466555c4e63d2c5b1c3a4c300910aaffdee5701a7e492045'
$guestProcessTimeoutSeconds = 60
$runID = $null
$requestID = $null
$srcdsExitCode = $null
$srcdsTimedOut = $false
$srcdsStdoutTail = ''
$srcdsStderrTail = ''

if ($null -eq ('SourceOracleGuestProcessRunner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Text;

public sealed class SourceOracleGuestProcessResult
{
    public int ExitCode;
    public bool HasExitCode;
    public bool TimedOut;
    public string StdoutTail;
    public string StderrTail;
}

public static class SourceOracleGuestProcessRunner
{
    private const int TailCharacters = 4096;

    private static void AppendTail(StringBuilder output, object gate, string value)
    {
        lock (gate)
        {
            output.Append(value);
            output.Append('\n');
            if (output.Length > TailCharacters)
            {
                output.Remove(0, output.Length - TailCharacters);
            }
        }
    }

    public static SourceOracleGuestProcessResult Run(
        string executable,
        string arguments,
        string workingDirectory,
        int timeoutMilliseconds)
    {
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = executable;
        start.Arguments = arguments;
        start.WorkingDirectory = workingDirectory;
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.EnvironmentVariables["SteamAppId"] = "4000";

        StringBuilder stdout = new StringBuilder();
        StringBuilder stderr = new StringBuilder();
        object stdoutGate = new object();
        object stderrGate = new object();
        SourceOracleGuestProcessResult result = new SourceOracleGuestProcessResult();

        using (Process process = new Process())
        {
            process.StartInfo = start;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendTail(stdout, stdoutGate, e.Data);
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) AppendTail(stderr, stderrGate, e.Data);
            };
            if (!process.Start())
            {
                throw new InvalidOperationException("srcds process creation returned false");
            }
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            if (!process.WaitForExit(timeoutMilliseconds))
            {
                result.TimedOut = true;
                process.Kill();
                if (!process.WaitForExit(5000))
                {
                    throw new InvalidOperationException("timed-out srcds did not terminate");
                }
            }
            process.WaitForExit();
            result.ExitCode = process.ExitCode;
            result.HasExitCode = true;
        }
        lock (stdoutGate) result.StdoutTail = stdout.ToString();
        lock (stderrGate) result.StderrTail = stderr.ToString();
        return result;
    }
}
'@
}

function Assert-GuestRelativePath {
    param([Parameter(Mandatory)] [string]$Value)
    if ($Value.Length -lt 1 -or $Value.Length -gt 512 -or
        $Value -notmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or
        @($Value.Split('/') | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -ne 0) {
        throw "Unsafe manifest path: $Value"
    }
}

function Get-GuestChildPath {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$RelativePath
    )
    Assert-GuestRelativePath $RelativePath
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath(
        [IO.Path]::Combine($fullRoot, $RelativePath.Replace('/', '\'))
    )
    if (-not $full.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes its root: $RelativePath"
    }
    return $full
}

function Read-GuestBoundedJSON {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$MaximumBytes,
        [Parameter(Mandatory)] [string]$Field
    )
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($stream.Length -lt 2 -or $stream.Length -gt $MaximumBytes) {
            throw "$Field byte count is outside its fixed bound"
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $cursor = 0
        while ($cursor -lt $bytes.Length) {
            $read = $stream.Read($bytes, $cursor, $bytes.Length - $cursor)
            if ($read -le 0) { throw "$Field is truncated" }
            $cursor += $read
        }
    } finally {
        $stream.Dispose()
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try { $text = $utf8.GetString($bytes) }
    catch { throw "$Field is not strict UTF-8" }
    try { return $text | ConvertFrom-Json }
    catch { throw "$Field is not valid JSON" }
}

function Assert-GuestExactNames {
    param(
        [Parameter(Mandatory)] [object]$Value,
        [Parameter(Mandatory)] [string[]]$Names,
        [Parameter(Mandatory)] [string]$Field
    )
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { throw "$Field shape changed" }
    foreach ($name in $Names) {
        if ($actual -cnotcontains $name) { throw "$Field is missing $name" }
    }
}

function Get-GuestCopiedFileSHA256 {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int64]$ExpectedBytes,
        [Parameter(Mandatory)] [string]$Field
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $info = Get-Item -LiteralPath $fullPath -Force
    if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $info.PSIsContainer -or $info.Length -ne $ExpectedBytes) {
        throw "$Field type or byte count changed before local rehash"
    }
    $stream = [IO.File]::Open(
        $fullPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None
    )
    try {
        if ($stream.Length -ne $ExpectedBytes) {
            throw "$Field byte count changed while opening for local rehash"
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Assert-GuestFixedRequest {
    param([Parameter(Mandatory)] [object]$Request)
    Assert-GuestExactNames $Request @(
        'schema', 'request_id', 'model_path', 'phy_path',
        'expected_mdl_sha256', 'expected_phy_sha256', 'ownership_reference',
        'policy', 'limits', 'surface_probe'
    ) 'request'
    if ([int64]$Request.schema -ne 2 -or
        [string]$Request.request_id -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$Request.model_path -cne $fixedModel -or
        [string]$Request.phy_path -cne $fixedPHY -or
        [string]$Request.expected_mdl_sha256 -cne $fixedMDLSHA -or
        [string]$Request.expected_phy_sha256 -cne $fixedPHYSHA -or
        [string]$Request.ownership_reference -cne $fixedOwnership) {
        throw 'Request does not match the fixed owned button_06 input'
    }
    Assert-GuestExactNames $Request.policy @(
        'search_path', 'allow_workshop', 'allow_installed_addons',
        'allow_user_lua', 'allow_network'
    ) 'request.policy'
    if ([string]$Request.policy.search_path -cne 'GAME' -or
        [bool]$Request.policy.allow_workshop -or
        [bool]$Request.policy.allow_installed_addons -or
        [bool]$Request.policy.allow_user_lua -or
        [bool]$Request.policy.allow_network) {
        throw 'Request policy is not fully isolated'
    }
    Assert-GuestExactNames $Request.limits @(
        'maximum_mdl_bytes', 'maximum_phy_bytes', 'maximum_solids',
        'maximum_convexes', 'maximum_vertices_per_convex',
        'maximum_total_vertices', 'maximum_result_bytes', 'timeout_seconds'
    ) 'request.limits'
    $fixedLimits = [ordered]@{
        maximum_mdl_bytes = [int64]2540
        maximum_phy_bytes = [int64]880
        maximum_solids = [int64]1
        maximum_convexes = [int64]4
        maximum_vertices_per_convex = [int64]256
        maximum_total_vertices = [int64]256
        maximum_result_bytes = [int64]65536
        timeout_seconds = [int64]20
    }
    foreach ($pair in $fixedLimits.GetEnumerator()) {
        if ([int64]$Request.limits.PSObject.Properties[$pair.Key].Value -ne $pair.Value) {
            throw "Request limit changed: $($pair.Key)"
        }
    }

    Assert-GuestExactNames $Request.surface_probe @(
        'schema', 'provenance', 'requested_surface_names', 'world_traces',
        'controlled_pair'
    ) 'request.surface_probe'
    if ([int64]$Request.surface_probe.schema -ne 1) {
        throw 'Surface probe schema changed'
    }
    $provenance = $Request.surface_probe.provenance
    Assert-GuestExactNames $provenance @(
        'app_id', 'branch', 'build_id', 'request_id', 'vphysics',
        'surface_inputs', 'map'
    ) 'request.surface_probe.provenance'
    if ([int64]$provenance.app_id -ne 4020 -or
        [string]$provenance.branch -cne 'x86-64' -or
        [string]$provenance.build_id -cne $fixedBuildID -or
        [string]$provenance.request_id -cne [string]$Request.request_id) {
        throw 'Surface provenance identity changed'
    }
    foreach ($binding in @(
        @($provenance.vphysics, 'bin/win64/vphysics.dll', $fixedVPhysicsSHA),
        @($provenance.map, 'garrysmod/maps/gm_flatgrass.bsp', $fixedMapSHA)
    )) {
        Assert-GuestExactNames $binding[0] @('path', 'sha256') `
            'request.surface_probe.provenance file'
        if ([string]$binding[0].path -cne [string]$binding[1] -or
            [string]$binding[0].sha256 -cne [string]$binding[2]) {
            throw 'Surface provenance file binding changed'
        }
    }
    $surfaceInputs = @($provenance.surface_inputs)
    if ($provenance.surface_inputs -isnot [array] -or
        $surfaceInputs.Count -ne $fixedSurfaceInputs.Count) {
        throw 'Surface provenance input count changed'
    }
    for ($index = 0; $index -lt $surfaceInputs.Count; $index++) {
        $record = $surfaceInputs[$index]
        $expected = @($fixedSurfaceInputs.GetEnumerator())[$index]
        Assert-GuestExactNames $record @('path', 'sha256') `
            'request.surface_probe.provenance.surface_inputs'
        if ([string]$record.path -cne [string]$expected.Key -or
            [string]$record.sha256 -cne [string]$expected.Value) {
            throw 'Surface provenance input order or hash changed'
        }
    }
    $requested = @($Request.surface_probe.requested_surface_names)
    if ($Request.surface_probe.requested_surface_names -isnot [array] -or
        $requested.Count -ne 2 -or [string]$requested[0] -cne 'plastic' -or
        [string]$requested[1] -cne 'rubber') {
        throw 'Requested surface list changed or contains duplicates'
    }
    $worldTraces = @($Request.surface_probe.world_traces)
    $fixedTraces = @(
        @('flatgrass-center', 0, 0),
        @('flatgrass-offset', 1024, 1024)
    )
    if ($Request.surface_probe.world_traces -isnot [array] -or
        $worldTraces.Count -ne $fixedTraces.Count) {
        throw 'Fixed surface world traces changed'
    }
    for ($index = 0; $index -lt $worldTraces.Count; $index++) {
        $trace = $worldTraces[$index]
        $expected = $fixedTraces[$index]
        Assert-GuestExactNames $trace @('id', 'start', 'end') `
            'request.surface_probe.world_trace'
        foreach ($endpoint in @('start', 'end')) {
            Assert-GuestExactNames $trace.PSObject.Properties[$endpoint].Value `
                @('x', 'y', 'z') "request.surface_probe.world_trace.$endpoint"
        }
        if ([string]$trace.id -cne [string]$expected[0] -or
            [int64]$trace.start.x -ne [int64]$expected[1] -or
            [int64]$trace.start.y -ne [int64]$expected[2] -or
            [int64]$trace.start.z -ne 4096 -or
            [int64]$trace.end.x -ne [int64]$expected[1] -or
            [int64]$trace.end.y -ne [int64]$expected[2] -or
            [int64]$trace.end.z -ne -4096) {
            throw 'Fixed surface world trace coordinates changed'
        }
    }
    $pair = $Request.surface_probe.controlled_pair
    Assert-GuestExactNames $pair @(
        'pair_id', 'moving_surface_name', 'fixed_surface_name',
        'anchor_trace_id', 'separation_units', 'impact_speed_units_per_second',
        'sample_delay_milliseconds', 'maximum_friction_snapshots'
    ) 'request.surface_probe.controlled_pair'
    if ([string]$pair.pair_id -cne 'plastic-against-rubber' -or
        [string]$pair.moving_surface_name -cne 'plastic' -or
        [string]$pair.fixed_surface_name -cne 'rubber' -or
        [string]$pair.anchor_trace_id -cne 'flatgrass-center' -or
        [int64]$pair.separation_units -ne 256 -or
        [int64]$pair.impact_speed_units_per_second -ne 128 -or
        [int64]$pair.sample_delay_milliseconds -ne 50 -or
        [int64]$pair.maximum_friction_snapshots -ne 16) {
        throw 'Controlled surface pair changed'
    }
}

function Write-GuestAtomicUTF8 {
    param(
        [Parameter(Mandatory)] [string]$FinalPath,
        [Parameter(Mandatory)] [string]$Text
    )
    $pending = $FinalPath + '.pending-' + [Guid]::NewGuid().ToString('N')
    $stream = [IO.File]::Open(
        $pending,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    [IO.File]::Move($pending, $FinalPath)
}

function Write-GuestFailure {
    param([Parameter(Mandatory)] [string]$Message)
    if ($runID -cnotmatch '^[0-9a-f]{32}$' -or
        $requestID -cnotmatch '^[0-9a-f]{32}$') {
        return
    }
    $bounded = if ($Message.Length -gt 512) { $Message.Substring(0, 512) } else { $Message }
    $failure = [pscustomobject][ordered]@{
        schema = [int64]1
        kind = 'source-oracle-vphysics-sandbox-guest-failure'
        run_id = $runID
        request_id = $requestID
        error = $bounded
        srcds_exit_code = $srcdsExitCode
        srcds_timed_out = [bool]$srcdsTimedOut
        stdout_tail = $srcdsStdoutTail
        stderr_tail = $srcdsStderrTail
    }
    $path = Join-Path $outputRoot 'failure.json'
    if (-not [IO.File]::Exists($path)) {
        $encoded = ($failure | ConvertTo-Json -Depth 4 -Compress) + "`n"
        $utf8 = [Text.UTF8Encoding]::new($false)
        if ($utf8.GetByteCount($encoded) -gt 16384) {
            $failure.stdout_tail = if ($srcdsStdoutTail.Length -gt 512) {
                $srcdsStdoutTail.Substring($srcdsStdoutTail.Length - 512)
            } else { $srcdsStdoutTail }
            $failure.stderr_tail = if ($srcdsStderrTail.Length -gt 512) {
                $srcdsStderrTail.Substring($srcdsStderrTail.Length - 512)
            } else { $srcdsStderrTail }
            $encoded = ($failure | ConvertTo-Json -Depth 4 -Compress) + "`n"
        }
        if ($utf8.GetByteCount($encoded) -gt 16384) {
            throw 'Bounded guest failure JSON still exceeds 16384 bytes'
        }
        Write-GuestAtomicUTF8 `
            -FinalPath $path `
            -Text $encoded
    }
}

try {
    foreach ($root in @($inputRoot, $requestRoot, $outputRoot)) {
        if (-not [IO.Directory]::Exists($root)) { throw "Missing mapped root $root" }
    }
    if ([IO.Directory]::Exists($localRoot) -or [IO.File]::Exists($localRoot)) {
        throw 'Ephemeral run root already exists'
    }
    $requestFiles = @(Get-ChildItem -LiteralPath $requestRoot -Force -File)
    $requestDirectories = @(Get-ChildItem -LiteralPath $requestRoot -Force -Directory)
    if ($requestDirectories.Count -ne 0 -or $requestFiles.Count -ne 2 -or
        @($requestFiles.Name | Sort-Object) -join ',' -cne 'request.json,run_token.txt') {
        throw 'Read-only request mapping is not the exact two-file handoff'
    }
    if (@(Get-ChildItem -LiteralPath $outputRoot -Force).Count -ne 0) {
        throw 'Writable output mapping was not empty at guest start'
    }

    $tokenText = [IO.File]::ReadAllText(
        (Join-Path $requestRoot 'run_token.txt'),
        [Text.UTF8Encoding]::new($false, $true)
    ).Trim()
    if ($tokenText -cnotmatch '^[0-9a-f]{32}$') { throw 'Run token is invalid' }
    $runID = $tokenText
    $request = Read-GuestBoundedJSON `
        -Path (Join-Path $requestRoot 'request.json') `
        -MaximumBytes 65536 `
        -Field 'request'
    Assert-GuestFixedRequest $request
    $requestID = [string]$request.request_id

    $manifest = Read-GuestBoundedJSON `
        -Path (Join-Path $inputRoot 'input-manifest.json') `
        -MaximumBytes $manifestMaximumBytes `
        -Field 'input manifest'
    if ([int64]$manifest.schema -ne 1 -or
        [string]$manifest.kind -cne 'source-oracle-vphysics-sandbox-input-manifest' -or
        [int64]$manifest.steam.app_id -ne 4020 -or
        [string]$manifest.steam.branch -cne 'x86-64' -or
        [string]$manifest.steam.build_id -cne $fixedBuildID -or
        $manifest.files -isnot [array]) {
        throw 'Input manifest identity changed'
    }
    $records = @($manifest.files)
    if ($records.Count -lt 1 -or $records.Count -gt $maximumManifestFiles) {
        throw 'Input manifest file count is outside its bound'
    }
    $paths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $probeCount = 0
    $bootstrapCount = 0
    $mapCount = 0
    $manifestByPath = @{}
    $copiedManifestFiles = [Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $relative = [string]$record.path
        $role = [string]$record.role
        Assert-GuestRelativePath $relative
        if (-not $paths.Add($relative)) { throw "Duplicate manifest path $relative" }
        $manifestByPath[$relative] = $record
        if ($relative -match '(?i)(^|/)addons(/|$)') {
            throw 'Manifest contains forbidden addons content'
        }
        if ($role -ceq 'probe_lua') { $probeCount++ }
        if ($role -ceq 'sandbox_bootstrap') { $bootstrapCount++ }
        if ($relative -ceq 'oracle_game/maps/gm_flatgrass.bsp') { $mapCount++ }
        if (-not $relative.StartsWith('server/', [StringComparison]::Ordinal) -and
            -not $relative.StartsWith('oracle_game/', [StringComparison]::Ordinal)) {
            continue
        }
        $source = Get-GuestChildPath $inputRoot $relative
        if (-not [IO.File]::Exists($source)) { throw "Missing manifest input $relative" }
        $expectedBytes = [int64]$record.byte_count
        $expectedSHA = [string]$record.sha256
        if ($expectedSHA -cnotmatch '^[0-9a-f]{64}$') {
            throw "Manifest input SHA-256 is invalid: $relative"
        }
        $sourceInfo = Get-Item -LiteralPath $source
        if ($expectedBytes -lt 1 -or $sourceInfo.Length -ne $expectedBytes -or
            ($sourceInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Manifest input byte count or type changed: $relative"
        }
        $destination = Get-GuestChildPath $localRoot $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::Copy($source, $destination, $false)
        $copiedManifestFiles.Add([pscustomobject][ordered]@{
            path = $relative
            local_path = $destination
            byte_count = $expectedBytes
            manifest_sha256 = $expectedSHA
        })
    }
    if ($probeCount -ne 1 -or $bootstrapCount -ne 1 -or $mapCount -ne 1) {
        throw 'Clean input manifest is missing the fixed probe, bootstrap, or map'
    }
    $provenanceBindings = [ordered]@{
        'server/bin/win64/vphysics.dll' = $fixedVPhysicsSHA
        'oracle_game/maps/gm_flatgrass.bsp' = $fixedMapSHA
        'server/sourceengine/scripts/surfaceproperties_manifest.txt' =
            [string]$fixedSurfaceInputs['sourceengine/scripts/surfaceproperties_manifest.txt']
        'server/sourceengine/scripts/surfaceproperties.txt' =
            [string]$fixedSurfaceInputs['sourceengine/scripts/surfaceproperties.txt']
        'server/sourceengine/scripts/surfaceproperties_hl2.txt' =
            [string]$fixedSurfaceInputs['sourceengine/scripts/surfaceproperties_hl2.txt']
    }
    foreach ($binding in $provenanceBindings.GetEnumerator()) {
        if (-not $manifestByPath.ContainsKey([string]$binding.Key) -or
            [string]$manifestByPath[[string]$binding.Key].sha256 -cne
                [string]$binding.Value) {
            throw "Input manifest is not bound to surface provenance $($binding.Key)"
        }
    }

    $handoff = Join-Path $localRoot 'oracle_game\lua\garryspad_vphysics_attestation'
    [void][IO.Directory]::CreateDirectory($handoff)
    [IO.File]::Copy(
        (Join-Path $requestRoot 'request.json'),
        (Join-Path $handoff 'request.json'),
        $false
    )
    [IO.File]::Copy(
        (Join-Path $requestRoot 'run_token.txt'),
        (Join-Path $handoff 'run_token.txt'),
        $false
    )

    $executable = Join-Path $localRoot 'server\srcds_console_win64.exe'
    $gameRoot = Join-Path $localRoot 'oracle_game'
    if (-not [IO.File]::Exists($executable) -or
        -not [IO.File]::Exists((Join-Path $gameRoot 'gameinfo.txt')) -or
        -not [IO.File]::Exists((Join-Path $gameRoot 'maps\gm_flatgrass.bsp'))) {
        throw 'Fixed executable, gameinfo, or map was not staged'
    }

    # Re-open and hash every file actually copied into the disposable run root
    # immediately before srcds starts. This closes the mapped-input-to-local-copy
    # interval instead of trusting the manifest declaration after File.Copy.
    $actualLocalHashes = @{}
    foreach ($copied in $copiedManifestFiles) {
        $actualSHA = Get-GuestCopiedFileSHA256 `
            -Path ([string]$copied.local_path) `
            -ExpectedBytes ([int64]$copied.byte_count) `
            -Field ("copied manifest input " + [string]$copied.path)
        if ($actualSHA -cne [string]$copied.manifest_sha256) {
            throw "Copied local input SHA-256 differs from manifest: $($copied.path)"
        }
        $actualLocalHashes[[string]$copied.path] = $actualSHA
    }
    foreach ($binding in $provenanceBindings.GetEnumerator()) {
        if (-not $actualLocalHashes.ContainsKey([string]$binding.Key) -or
            [string]$actualLocalHashes[[string]$binding.Key] -cne
                [string]$binding.Value) {
            throw "Copied local input SHA-256 differs from fixed surface provenance: $($binding.Key)"
        }
    }

    $arguments = @(
        '-console', '-textmode', '-norestart', '-nohltv', '-nosound', '-nojoy',
        '-noworkshop', '-disableluarefresh', '-insecure', '-usercon',
        '-game', $gameRoot,
        '+sv_lan', '1',
        '+maxplayers', '1',
        '+gamemode', $fixedGamemode,
        '+map', $fixedMap,
        '+garryspad_source_vphysics_attestation_run', $runID, $requestID
    )
    foreach ($argument in $arguments) {
        if ($argument.IndexOf('"') -ge 0 -or $argument.IndexOf([char]0) -ge 0 -or
            $argument.IndexOf(' ') -ge 0) {
            throw 'Fixed srcds argument is not safely tokenizable'
        }
    }
    $processResult = [SourceOracleGuestProcessRunner]::Run(
        $executable,
        ($arguments -join ' '),
        [IO.Path]::GetDirectoryName($executable),
        $guestProcessTimeoutSeconds * 1000
    )
    if ($processResult.HasExitCode) {
        $srcdsExitCode = [int]$processResult.ExitCode
    }
    $srcdsTimedOut = [bool]$processResult.TimedOut
    $srcdsStdoutTail = [string]$processResult.StdoutTail
    $srcdsStderrTail = [string]$processResult.StderrTail
    if ($srcdsTimedOut) { throw 'Fixed srcds guest timeout elapsed' }

    $localResult = Join-Path $gameRoot 'data\garryspad_vphysics_attestation\latest.json'
    if (-not [IO.File]::Exists($localResult)) {
        throw 'Probe exited without a result file'
    }
    $resultInfo = Get-Item -LiteralPath $localResult
    if ($resultInfo.Length -lt 2 -or
        $resultInfo.Length -gt [int64]$request.limits.maximum_result_bytes) {
        throw 'Probe result byte count is outside its request bound'
    }
    $lightweight = Read-GuestBoundedJSON `
        -Path $localResult `
        -MaximumBytes ([int]$request.limits.maximum_result_bytes) `
        -Field 'probe result'
    if ([string]$lightweight.run_id -cne $runID -or
        [string]$lightweight.request_id -cne $requestID) {
        throw 'Probe result authentication IDs differ'
    }
    $outputResult = Join-Path $outputRoot 'result.json'
    $pendingResult = $outputResult + '.pending-' + [Guid]::NewGuid().ToString('N')
    $sourceStream = [IO.File]::OpenRead($localResult)
    try {
        $destinationStream = [IO.File]::Open(
            $pendingResult,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $sourceStream.CopyTo($destinationStream)
            $destinationStream.Flush($true)
        } finally {
            $destinationStream.Dispose()
        }
    } finally {
        $sourceStream.Dispose()
    }
    [IO.File]::Move($pendingResult, $outputResult)
} catch {
    Write-GuestFailure -Message $_.Exception.Message
} finally {
    Start-Sleep -Milliseconds 500
    & 'C:\Windows\System32\shutdown.exe' /s /t 0 /f | Out-Null
}
