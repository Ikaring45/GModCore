$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$common = Join-Path $toolRoot 'SourceOracleRunnerCommon.ps1'
. $common

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

$runID = '0123456789abcdef0123456789abcdef'
$valid = [pscustomobject]@{
    schema = [int64]1
    enabled = $true
    command_line_enabled = $true
    run_id = $runID
    command_line_run_id = $runID
    realm = 'CLIENT'
    finish_reason = 'complete'
}
$validated = Assert-SourceOracleResultObject -Result $valid -RunID $runID -Realm 'CLIENT'
Assert-True ($validated.run_id -ceq $runID) 'Valid oracle result was rejected'

$invalidCases = @(
    [pscustomobject]@{ Name = 'missing enabled'; Value = [pscustomobject]@{
        schema = 1; command_line_enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'string enabled'; Value = [pscustomobject]@{
        schema = 1; enabled = 'true'; command_line_enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'missing command line enable'; Value = [pscustomobject]@{
        schema = 1; enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'false command line enable'; Value = [pscustomobject]@{
        schema = 1; enabled = $true; command_line_enabled = $false; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'stale run'; Value = [pscustomobject]@{
        schema = 1; enabled = $true; command_line_enabled = $true
        run_id = 'ffffffffffffffffffffffffffffffff'
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'stale command line run'; Value = [pscustomobject]@{
        schema = 1; enabled = $true; command_line_enabled = $true; run_id = $runID
        command_line_run_id = 'ffffffffffffffffffffffffffffffff'
        realm = 'CLIENT'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'wrong realm'; Value = [pscustomobject]@{
        schema = 1; enabled = $true; command_line_enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'SERVER'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'string schema'; Value = [pscustomobject]@{
        schema = '1'; enabled = $true; command_line_enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'new schema'; Value = [pscustomobject]@{
        schema = 2; enabled = $true; command_line_enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'complete'
    } },
    [pscustomobject]@{ Name = 'missing finish'; Value = [pscustomobject]@{
        schema = 1; enabled = $true; command_line_enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'
    } },
    [pscustomobject]@{ Name = 'timeout finish'; Value = [pscustomobject]@{
        schema = 1; enabled = $true; command_line_enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'network-timeout'
    } },
    [pscustomobject]@{ Name = 'probe error'; Value = [pscustomobject]@{
        schema = 1; enabled = $true; command_line_enabled = $true; run_id = $runID
        command_line_run_id = $runID; realm = 'CLIENT'; finish_reason = 'complete'
        probe_error = 'synthetic failure'
    } }
)
foreach ($case in $invalidCases) {
    Assert-Throws {
        Assert-SourceOracleResultObject `
            -Result $case.Value `
            -RunID $runID `
            -Realm 'CLIENT' | Out-Null
    } "Unsafe oracle result was accepted: $($case.Name)"
}

$serverValid = [pscustomobject]@{
    schema = 1; enabled = $true; command_line_enabled = $true; run_id = $runID
    command_line_run_id = $runID; realm = 'SERVER'; finish_reason = 'sequence-complete'
}
Assert-SourceOracleResultObject -Result $serverValid -RunID $runID -Realm 'SERVER' | Out-Null

# The per-install mutex is acquired and released without touching process state.
# Windows Mutex ownership is intentionally re-entrant on the owning thread, so
# cross-process exclusion is covered by the kernel primitive rather than a
# misleading same-thread second WaitOne assertion.
$mutexRoot = Join-Path ([IO.Path]::GetTempPath()) 'source-oracle-mutex-fixture'
$firstMutex = Enter-SourceOracleLaunchMutex -GModRoot $mutexRoot
try {
    Assert-True ($null -ne $firstMutex) 'The per-install launch mutex was not acquired'
} finally {
    $firstMutex.ReleaseMutex()
    $firstMutex.Dispose()
}

# Stale mount detection reports and preserves the directory for manual audit.
$staleRoot = Join-Path ([IO.Path]::GetTempPath()) ("source-oracle-stale-$runID")
$staleMount = Join-Path $staleRoot "garryspad_source_oracle_${runID}_fixturetoken"
[void][IO.Directory]::CreateDirectory($staleMount)
try {
    Assert-Throws {
        Assert-SourceOracleNoStaleMounts -AddonsRoot $staleRoot
    } 'A stale oracle mount was not rejected'
    Assert-True (Test-Path -LiteralPath $staleMount -PathType Container) (
        'Stale mount preflight removed a directory instead of failing closed'
    )
} finally {
    [IO.Directory]::Delete($staleRoot, $true)
}

$parserErrors = [Collections.Generic.List[System.Management.Automation.Language.ParseError]]::new()
foreach ($scriptName in @(
    'SourceOracleRunnerCommon.ps1',
    'Run-SourceOracle.ps1',
    'Run-SourceClientOracle.ps1',
    'Test-SourceOracleRunnerSafety.ps1',
    'Test-SourceOracleOwnedProcessJob.ps1',
    'Test-SourceOracleOwnedMount.ps1'
)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $toolRoot $scriptName),
        [ref]$tokens,
        [ref]$errors
    )
    foreach ($error in $errors) { $parserErrors.Add($error) }
}
Assert-True ($parserErrors.Count -eq 0) "PowerShell parser found $($parserErrors.Count) error(s)"

$commonText = Get-Content -Raw -Encoding UTF8 -LiteralPath $common
Assert-True ($commonText -notmatch '\bStop-Process\b') 'Common code still terminates by PID'
Assert-True ($commonText -notmatch '\bGet-CimInstance\b') 'Common code still uses CIM as cleanup authority'
Assert-True ($commonText -notmatch '\bProcessTracker\b') 'Common code still contains the PID tracker'

$runnerExitCodes = @{
    'Run-SourceOracle.ps1' = [pscustomobject]@{
        Hex = 'E0450002'
        Decimal = [uint64]3762618370
    }
    'Run-SourceClientOracle.ps1' = [pscustomobject]@{
        Hex = 'E0450003'
        Decimal = [uint64]3762618371
    }
}
foreach ($runnerName in @('Run-SourceOracle.ps1', 'Run-SourceClientOracle.ps1')) {
    $runnerPath = Join-Path $toolRoot $runnerName
    $runnerText = Get-Content -Raw -Encoding UTF8 -LiteralPath $runnerPath
    $exitCodeFixture = $runnerExitCodes[$runnerName]
    $convertedExitCode = [Convert]::ToUInt32($exitCodeFixture.Hex, 16)
    Assert-True ($convertedExitCode -is [uint32]) "$runnerName exit code is not UInt32"
    Assert-True (
        [uint64]$convertedExitCode -eq $exitCodeFixture.Decimal
    ) "$runnerName exit code changed value"
    Assert-True (
        $runnerText -match (
            "\[Convert\]::ToUInt32\('" + $exitCodeFixture.Hex + "',\s*16\)"
        )
    ) "$runnerName lacks a PowerShell 5.1-safe UInt32 exit-code conversion"
    Assert-True (
        $runnerText -notmatch '\[uint32\]\s*0xE045000[23]'
    ) "$runnerName uses the overflowing PowerShell 5.1 UInt32 hex cast"
    Assert-True ($runnerText -notmatch '\bStart-Process\b') "$runnerName launches outside the Job Object"
    Assert-True ($runnerText -notmatch '\bStop-Process\b') "$runnerName terminates by PID"
    Assert-True ($runnerText -notmatch '\bGet-CimInstance\b') "$runnerName uses CIM as cleanup authority"
    Assert-True ($runnerText -notmatch '\bRemove-Item\b') "$runnerName uses path-based recursive mount deletion"
    Assert-True ($runnerText -match '\[SourceOracleOwnedProcessJob\]::Start') "$runnerName lacks suspended Job launch"
    Assert-True ($runnerText -match '\bTerminateAndWait\b') "$runnerName lacks retained-Job cleanup"
    Assert-True ($runnerText -match '\bActiveProcessCount\b') "$runnerName accepts results without an active Job member"
    Assert-True ($runnerText -match '\bRead-SourceOracleResult\b') "$runnerName does not authenticate result JSON"
    Assert-True ($runnerText -match '\brun_token\.txt\b') "$runnerName does not inject a unique run token"
    Assert-True ($runnerText -match '\bAllowRealGModLaunch\b') "$runnerName lacks the explicit real-launch interlock"
    Assert-True ($runnerText -match '\[SourceOracleOwnedMount\]::Create') "$runnerName lacks an owned per-run mount"
    Assert-True ($runnerText -match '\bWriteGeneratedFile\b') "$runnerName does not manifest the generated run token"
    Assert-True ($runnerText -match '\$mount\.Cleanup\(\)') "$runnerName lacks same-handle mount cleanup"
    $launchCommand = if ($runnerName -eq 'Run-SourceClientOracle.ps1') {
        '+garryspad_source_client_oracle_run'
    } else {
        '+garryspad_source_oracle_run'
    }
    Assert-True (
        $runnerText.IndexOf(
            "'$launchCommand', `$runID",
            [StringComparison]::Ordinal
        ) -ge 0
    ) "$runnerName does not bind the launch token to a process-local command"

    Assert-Throws {
        & $runnerPath -GModRoot 'C:\definitely-not-a-real-gmod-root' 2>$null | Out-Null
    } "$runnerName bypassed its default-deny launch interlock"
}

$probeScripts = @(
    'Addon\lua\autorun\garryspad_source_oracle.lua',
    'ClientAddon\lua\autorun\client\garryspad_source_client_oracle.lua'
)
foreach ($relativeProbe in $probeScripts) {
    $probeText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $toolRoot $relativeProbe)
    Assert-True ($probeText -match '\bconcommand\.Add\b') "$relativeProbe lacks the process-local launch gate"
    Assert-True ($probeText -match '\bcommand_line_enabled\s*=\s*true\b') "$relativeProbe cannot attest command-line enablement"
    Assert-True ($probeText -match '\bcommand_line_run_id\s*=\s*runID\b') "$relativeProbe does not attest the command-line run ID"
}

$clientLoaderPath = Join-Path $toolRoot (
    'ClientAddon\lua\autorun\server\garryspad_source_client_oracle_loader.lua'
)
$clientLoaderText = Get-Content -Raw -Encoding UTF8 -LiteralPath $clientLoaderPath
$loaderGateIndex = $clientLoaderText.IndexOf('concommand.Add', [StringComparison]::Ordinal)
$loaderReceiverIndex = $clientLoaderText.IndexOf(
    'util.AddNetworkString("garryspad_oracle_ping")',
    [StringComparison]::Ordinal
)
Assert-True ($loaderGateIndex -ge 0 -and $loaderReceiverIndex -gt $loaderGateIndex) (
    'Client server loader registers network behavior before its exact run-token gate'
)
Assert-True ($clientLoaderText -match '\brun_token\.txt\b') (
    'Client server loader is not bound to the generated run token'
)

Write-Output 'Source oracle runner safety tests passed (no GMod process was started or stopped)'
