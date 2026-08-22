[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InstalledServerRoot,
    [Parameter(Mandatory)] [string]$StagePath
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'SourceOracleVPhysicsSandboxWorkspace.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsAttestationCommon.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsBuild24721267Input.ps1')

$state = New-SourceOracleVPhysicsBuild24721267Stage `
    -InstalledServerRoot $InstalledServerRoot `
    -StagePath $StagePath
$state | ConvertTo-Json -Depth 8
