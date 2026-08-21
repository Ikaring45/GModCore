[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$WorkspacePath,
    [Parameter(Mandatory)] [string]$RunPath,
    [switch]$AllowSingleSandboxLaunch
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'SourceOracleRunnerCommon.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsSandboxWorkspace.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsAttestationCommon.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsSandboxRun.ps1')

$result = Invoke-SourceOracleVPhysicsSandboxSingleRun `
    -WorkspacePath $WorkspacePath `
    -RunPath $RunPath `
    -AllowSingleSandboxLaunch:$AllowSingleSandboxLaunch
$result | ConvertTo-Json -Depth 64
