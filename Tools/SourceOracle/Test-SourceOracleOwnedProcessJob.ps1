[CmdletBinding()]
param(
    [switch]$JobRoot,
    [switch]$JobChild,
    [string]$ExecutablePath,
    [string]$RoundTrip
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# The two internal modes are harmless fixtures used by the isolation test.
# JobRoot synchronously waits on JobChild, keeping both processes active.
$expectedRoundTrip = 'space "quote" trailing\\'
if ($JobChild) {
    Start-Sleep -Seconds 120
    exit 0
}
if ($JobRoot) {
    if ($RoundTrip -cne $expectedRoundTrip) {
        [Console]::Error.WriteLine('argv round-trip mismatch')
        exit 41
    }
    if (-not [IO.Path]::IsPathRooted($ExecutablePath)) {
        [Console]::Error.WriteLine('fixture executable was not absolute')
        exit 42
    }

    & $ExecutablePath `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -File $PSCommandPath `
        -JobChild
    exit $LASTEXITCODE
}

function Wait-SourceOracleCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock]$Condition,
        [Parameter(Mandatory)] [string]$FailureMessage,
        [int]$TimeoutMilliseconds = 15000
    )

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 25
    } while ([datetime]::UtcNow -lt $deadline)
    throw $FailureMessage
}

$sourcePath = Join-Path $PSScriptRoot 'SourceOracleOwnedProcessJob.cs'
if ($null -eq ('SourceOracleOwnedProcessJob' -as [type])) {
    Add-Type -Path $sourcePath
}

$pwshPath = (Get-Process -Id $PID).Path
if (-not [IO.Path]::IsPathRooted($pwshPath)) {
    throw 'The test host executable path is not absolute'
}

$ownedTree = $null
$unrelated = $null
$ownedExitCode = [uint32]71
$unrelatedExitCode = [uint32]72

try {
    $ownedArguments = [string[]]@(
        '-NoLogo'
        '-NoProfile'
        '-NonInteractive'
        '-File'
        $PSCommandPath
        '-JobRoot'
        '-ExecutablePath'
        $pwshPath
        '-RoundTrip'
        $expectedRoundTrip
    )
    $unrelatedArguments = [string[]]@(
        '-NoLogo'
        '-NoProfile'
        '-NonInteractive'
        '-Command'
        'Start-Sleep -Seconds 120'
    )

    $ownedTree = [SourceOracleOwnedProcessJob]::Start(
        $pwshPath,
        $ownedArguments,
        $PSScriptRoot
    )
    $unrelated = [SourceOracleOwnedProcessJob]::Start(
        $pwshPath,
        $unrelatedArguments,
        $PSScriptRoot
    )

    Wait-SourceOracleCondition -FailureMessage (
        'The owned root did not create its assigned child; root exit={0}' -f
        $(if ($ownedTree.HasExited) { $ownedTree.ExitCode } else { 'running' })
    ) -Condition {
        -not $ownedTree.HasExited -and $ownedTree.ActiveProcessCount -ge 2
    }
    Wait-SourceOracleCondition `
        -FailureMessage 'The unrelated fixture did not remain active' `
        -Condition {
            -not $unrelated.HasExited -and $unrelated.ActiveProcessCount -eq 1
        }

    $ownedPID = $ownedTree.ProcessId
    $unrelatedPID = $unrelated.ProcessId
    $ownedCountBefore = $ownedTree.ActiveProcessCount
    if (-not $ownedTree.TerminateAndWait(10000, $ownedExitCode)) {
        throw 'Timed out terminating the owned root and child Job Object'
    }
    if (-not $ownedTree.HasExited) {
        throw 'The owned root handle was not signaled after job termination'
    }
    if ($ownedTree.ActiveProcessCount -ne 0) {
        throw 'The owned Job Object still reports active processes'
    }
    if ($ownedTree.ExitCode -ne [int]$ownedExitCode) {
        throw "The owned root reported unexpected exit code $($ownedTree.ExitCode)"
    }

    # The second PowerShell is deliberately outside the terminated Job Object.
    # Its own retained Job handle is used for cleanup below; no PID kill occurs.
    if ($unrelated.HasExited -or $unrelated.ActiveProcessCount -ne 1) {
        throw 'Terminating the owned Job Object also terminated the unrelated process'
    }

    if (-not $unrelated.TerminateAndWait(10000, $unrelatedExitCode)) {
        throw 'Timed out cleaning up the unrelated fixture through its Job handle'
    }

    [pscustomobject]@{
        test = 'SourceOracleOwnedProcessJob isolation'
        owned_root_pid = $ownedPID
        unrelated_root_pid = $unrelatedPID
        owned_processes_before_termination = $ownedCountBefore
        owned_processes_after_termination = $ownedTree.ActiveProcessCount
        unrelated_survived_owned_termination = $true
        safe_argv_round_trip = $true
        cleanup_used_retained_job_handles = $true
        status = 'PASS'
    } | ConvertTo-Json -Compress
}
finally {
    # Cleanup remains handle-based even when an assertion fails. Dispose closes
    # KILL_ON_JOB_CLOSE jobs; the explicit call also waits for deterministic QA.
    if ($null -ne $ownedTree) {
        try { [void]$ownedTree.TerminateAndWait(10000, $ownedExitCode) }
        catch { Write-Warning "Owned fixture cleanup failed: $($_.Exception.Message)" }
        $ownedTree.Dispose()
    }
    if ($null -ne $unrelated) {
        try { [void]$unrelated.TerminateAndWait(10000, $unrelatedExitCode) }
        catch { Write-Warning "Unrelated fixture cleanup failed: $($_.Exception.Message)" }
        $unrelated.Dispose()
    }
}
