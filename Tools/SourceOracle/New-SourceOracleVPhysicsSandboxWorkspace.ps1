[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SourceRoot,
    [Parameter(Mandatory)] [string]$InputSpecPath,
    [Parameter(Mandatory)] [string]$WorkspacePath
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'SourceOracleVPhysicsSandboxWorkspace.ps1')

$state = New-SourceOracleVPhysicsSandboxWorkspace `
    -SourceRoot $SourceRoot `
    -InputSpecPath $InputSpecPath `
    -WorkspacePath $WorkspacePath
$state | ConvertTo-Json -Depth 12
