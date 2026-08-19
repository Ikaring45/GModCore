[CmdletBinding()]
param(
    [string]$GModRoot = 'C:\Program Files (x86)\Steam\steamapps\common\GarrysMod',
    [ValidateRange(15, 300)]
    [int]$TimeoutSeconds = 90,
    [switch]$AllowRealGModLaunch
)

$ErrorActionPreference = 'Stop'

$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'SourceOracleRunnerCommon.ps1')

if (-not $AllowRealGModLaunch) {
    throw 'Real GMod launch is safety-interlocked; review the runner and pass -AllowRealGModLaunch explicitly'
}

$addonSource = Join-Path $toolRoot 'ClientAddon'
$gmodExecutable = Join-Path $GModRoot 'gmod.exe'
$gameRoot = Join-Path $GModRoot 'garrysmod'
$addonsRoot = Join-Path $gameRoot 'addons'
$runID = [Guid]::NewGuid().ToString('N')
$gameResult = Join-Path $gameRoot 'data\garryspad_oracle\client_latest.json'
$resultsRoot = Join-Path $toolRoot 'Results'
$savedResult = Join-Path $resultsRoot "client-$runID.json"

if (-not (Test-Path -LiteralPath $gmodExecutable -PathType Leaf)) {
    throw "Garry's Mod executable not found: $gmodExecutable"
}
if (-not (Test-Path -LiteralPath $addonSource -PathType Container)) {
    throw "Client oracle addon source not found: $addonSource"
}

$mount = $null
$ownedJob = $null
$launchMutex = $null
$launchStartedAt = $null
$ownedJobStopped = $true
try {
    Import-SourceOracleOwnedProcessJob
    Import-SourceOracleOwnedMount
    $launchMutex = Enter-SourceOracleLaunchMutex -GModRoot $GModRoot
    Assert-SourceOracleNoRunningGMod
    Assert-SourceOracleNoStaleMounts -AddonsRoot $addonsRoot
    New-Item -ItemType Directory -Path $addonsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $mount = [SourceOracleOwnedMount]::Create(
        [IO.Path]::GetFullPath($GModRoot),
        [IO.Path]::GetFullPath($addonsRoot),
        $runID
    )
    $mount.CopyTree([IO.Path]::GetFullPath($addonSource))
    $mount.WriteGeneratedFile('lua\garryspad_oracle_client\run_token.txt', $runID)

    $arguments = @(
        '-console', '-condebug', '-windowed', '-w', '640', '-h', '480',
        '-nosound', '-nojoy', '-noworkshop', '-disableluarefresh', '-insecure',
        '+map', 'gm_flatgrass',
        '+garryspad_source_client_oracle_run', $runID
    )
    $launchStartedAt = Get-Date
    $ownedJob = [SourceOracleOwnedProcessJob]::Start(
        [IO.Path]::GetFullPath($gmodExecutable),
        [string[]]$arguments,
        [IO.Path]::GetFullPath($GModRoot)
    )

    $validatedResult = $null
    $lastValidationError = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($ownedJob.ActiveProcessCount -eq 0) { break }
        if (Test-Path -LiteralPath $gameResult -PathType Leaf) {
            $resultWriteTime = (Get-Item -LiteralPath $gameResult).LastWriteTimeUtc
            if ($resultWriteTime -ge $launchStartedAt.ToUniversalTime()) {
                try {
                    $validatedResult = Read-SourceOracleResult `
                        -Path $gameResult `
                        -RunID $runID `
                        -Realm 'CLIENT'
                    break
                } catch {
                    $lastValidationError = $_.Exception.Message
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }

    if ($null -eq $validatedResult) {
        $exitDescription = try {
            if ($ownedJob.HasExited) { "owned root exited with code $($ownedJob.ExitCode)" }
            else { "timed out after $TimeoutSeconds seconds" }
        } catch {
            "timed out after $TimeoutSeconds seconds"
        }
        $validationDescription = if ($lastValidationError) {
            "; last candidate was rejected: $lastValidationError"
        } else { '' }
        throw "Garry's Mod client oracle produced no authenticated result ($exitDescription$validationDescription)"
    }

    Copy-Item -LiteralPath $gameResult -Destination $savedResult
    Read-SourceOracleResult -Path $savedResult -RunID $runID -Realm 'CLIENT' | Out-Null
    Write-Output $savedResult
}
finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    if ($null -ne $ownedJob) {
        try {
            $ownedJobStopped = $ownedJob.TerminateAndWait(10000, [uint32]0xE0450003)
            if (-not $ownedJobStopped) {
                $cleanupFailures.Add('Timed out waiting for the owned GMod Job to stop')
            }
        } catch {
            $ownedJobStopped = $false
            $cleanupFailures.Add("Owned GMod Job cleanup failed: $($_.Exception.Message)")
        } finally {
            $ownedJob.Dispose()
        }
    }
    if ($ownedJobStopped) {
        try {
            Assert-SourceOracleNoRunningGMod
        } catch {
            $ownedJobStopped = $false
            $cleanupFailures.Add(
                "The owned Job ended, but another gmod.exe exists. " +
                "It was not stopped and the per-run mount is being preserved: " +
                $_.Exception.Message
            )
        }
    }
    if ($null -ne $mount) {
        try {
            if ($ownedJobStopped) {
                $mount.Cleanup()
            } else {
                $cleanupFailures.Add(
                    "Owned process shutdown was not proven; mount preserved at $($mount.TargetPath)"
                )
            }
        } catch {
            $cleanupFailures.Add(
                "Owned mount cleanup was refused; mount preserved at $($mount.TargetPath): " +
                $_.Exception.Message
            )
        } finally {
            $mount.Dispose()
        }
    }
    if ($null -ne $launchMutex) {
        try { $launchMutex.ReleaseMutex() }
        finally { $launchMutex.Dispose() }
    }
    if ($cleanupFailures.Count -ne 0) {
        throw ($cleanupFailures -join [Environment]::NewLine)
    }
}
