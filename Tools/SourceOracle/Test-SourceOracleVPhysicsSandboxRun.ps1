$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'SourceOracleRunnerCommon.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsSandboxWorkspace.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsAttestationCommon.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsSandboxRun.ps1')

function Assert-RunStatic([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$metadata = Read-SourceOracleVPhysicsBoundedJSON `
    -Path (Join-Path $toolRoot 'VPhysicsAttestation-Button06-AllowlistMetadata.json') `
    -MaximumBytes 65536 `
    -Field 'button metadata'
$request = New-SourceOracleVPhysicsFixedRequest `
    -RequestID '0123456789abcdef0123456789abcdef' `
    -Metadata $metadata
Assert-RunStatic `
    ([string]$request.model_path -ceq 'models/maxofs2d/button_06.mdl') `
    'Run request is not bound to button_06'
Assert-RunStatic `
    ([int64]$request.limits.timeout_seconds -eq 20 -and
     [int64]$request.limits.maximum_result_bytes -eq 65536) `
    'Run request timeout or result bound changed'

$temporary = Join-Path ([IO.Path]::GetTempPath()) (
    'garryspad-vphysics-run-static-' + [Guid]::NewGuid().ToString('N')
)
try {
    $inputPath = Join-Path $temporary 'input'
    $requestPath = Join-Path $temporary 'request'
    $outputPath = Join-Path $temporary 'output'
    foreach ($path in @($inputPath, $requestPath, $outputPath)) {
        [void][IO.Directory]::CreateDirectory($path)
    }
    $text = New-SourceOracleVPhysicsLaunchWSBText `
        -InputPath $inputPath `
        -RequestPath $requestPath `
        -OutputPath $outputPath
    $xmlPath = Join-Path $temporary 'launch.wsb'
    [IO.File]::WriteAllText($xmlPath, $text, [Text.UTF8Encoding]::new($false))
    $xml = Read-SourceOracleSandboxXML -Path $xmlPath
    Assert-RunStatic `
        ($xml.SelectSingleNode('/Configuration/Networking').InnerText -ceq 'Disable') `
        'Launch WSB does not disable networking'
    Assert-RunStatic `
        (@($xml.SelectNodes('/Configuration/MappedFolders/MappedFolder')).Count -eq 3) `
        'Launch WSB does not have exactly three mappings'
    $readOnlyValues = @($xml.SelectNodes(
        '/Configuration/MappedFolders/MappedFolder/ReadOnly'
    ) | ForEach-Object { $_.InnerText })
    Assert-RunStatic `
        (@($readOnlyValues | Where-Object { $_ -ceq 'true' }).Count -eq 2 -and
         @($readOnlyValues | Where-Object { $_ -ceq 'false' }).Count -eq 1) `
        'Launch WSB does not separate read-only input/request from writable output'
    Assert-RunStatic `
        ($xml.SelectSingleNode('/Configuration/LogonCommand/Command').InnerText -ceq
            $script:VPhysicsSandboxRunGuestCommand) `
        'Launch WSB command is not the fixed guest bootstrap'
} finally {
    if ([IO.Directory]::Exists($temporary)) {
        [IO.Directory]::Delete($temporary, $true)
    }
}

$failureRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'garryspad-vphysics-failure-static-' + [Guid]::NewGuid().ToString('N')
)
try {
    [void][IO.Directory]::CreateDirectory($failureRoot)
    $failurePath = Join-Path $failureRoot 'failure.json'
    $failure = [pscustomobject][ordered]@{
        schema = [int64]1
        kind = 'source-oracle-vphysics-sandbox-guest-failure'
        run_id = '11111111111111111111111111111111'
        request_id = '22222222222222222222222222222222'
        error = 'synthetic bounded failure'
        srcds_exit_code = [int64]7
        srcds_timed_out = $false
        stdout_tail = 'stdout tail'
        stderr_tail = 'stderr tail'
    }
    [IO.File]::WriteAllText(
        $failurePath,
        (($failure | ConvertTo-Json -Compress) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $validatedFailure = Read-SourceOracleVPhysicsGuestFailure `
        -Path $failurePath `
        -RunID '11111111111111111111111111111111' `
        -RequestID '22222222222222222222222222222222'
    Assert-RunStatic ([int64]$validatedFailure.srcds_exit_code -eq 7) `
        'Authenticated bounded failure diagnostics were rejected'
} finally {
    if ([IO.Directory]::Exists($failureRoot)) {
        [IO.Directory]::Delete($failureRoot, $true)
    }
}

$spec = Read-SourceOracleVPhysicsSandboxInputSpec -Path (
    Join-Path $toolRoot 'VPhysicsSandbox-AppID4020-x86-64-build24721267-InputSpec.json'
)
$bootstrap = @($spec.files | Where-Object {
    [string]$_.role -ceq 'sandbox_bootstrap' -and
    [string]$_.input_path -ceq $script:VPhysicsSandboxRunGuestScript
})
Assert-RunStatic ($bootstrap.Count -eq 1) `
    'Fixed input spec must contain exactly one sandbox bootstrap'
Assert-RunStatic `
    (@($spec.files | Where-Object {
        [string]$_.role -ceq 'probe_lua'
    }).Count -eq 1) `
    'Fixed input spec must contain exactly one probe'
Assert-RunStatic `
    (@($spec.files | Where-Object {
        [string]$_.input_path -match '(?i)(^|/)addons(/|$)'
    }).Count -eq 0) `
    'Fixed input spec includes addons content'

$scripts = @(
    'SourceOracleVPhysicsSandboxRun.ps1',
    'Run-SourceOracleVPhysicsSandboxGuest.ps1',
    'Invoke-SourceOracleVPhysicsSandboxRun.ps1',
    'Test-SourceOracleVPhysicsSandboxRun.ps1'
)
$parseErrors = [Collections.Generic.List[object]]::new()
foreach ($name in $scripts) {
    $tokens = $null
    $errors = $null
    $path = Join-Path $toolRoot $name
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )
    foreach ($error in $errors) { $parseErrors.Add($error) }
}
Assert-RunStatic ($parseErrors.Count -eq 0) `
    "VPhysics Sandbox runner scripts contain $($parseErrors.Count) parser error(s)"

$guestText = Get-Content -LiteralPath (
    Join-Path $toolRoot 'Run-SourceOracleVPhysicsSandboxGuest.ps1'
) -Raw -Encoding UTF8
foreach ($required in @(
    "'-noworkshop'",
    "'-insecure'",
    "'+sv_lan'",
    "'+gamemode'",
    "'+map'",
    "'+garryspad_source_vphysics_attestation_run'",
    "'C:\GarrysPAD\Output'",
    "'C:\Windows\System32\shutdown.exe'",
    'RedirectStandardOutput = true',
    'RedirectStandardError = true',
    'TailCharacters = 4096',
    "'.pending-'"
)) {
    Assert-RunStatic ($guestText.Contains($required)) `
        "Guest bootstrap is missing fixed token $required"
}

$hostText = Get-Content -LiteralPath (
    Join-Path $toolRoot 'SourceOracleVPhysicsSandboxRun.ps1'
) -Raw -Encoding UTF8
foreach ($required in @(
    '$brokerExitCode',
    'Assert-SourceOracleVPhysicsFinalOutput',
    'Wait-SourceOracleWindowsSandboxGuestShutdown',
    'stdout_tail',
    'stderr_tail'
)) {
    Assert-RunStatic ($hostText.Contains($required)) `
        "Host runner is missing broker/result contract token $required"
}
Assert-RunStatic `
    ($hostText -notmatch 'if\s*\(\$owned\.HasExited\)\s*\{\s*break\s*\}') `
    'Host runner still mistakes broker exit for guest completion'
foreach ($forbidden in @(
    '(?i)Copy-Item[^\r\n]*-Recurse',
    '(?i)Start-Process',
    '(?i)Enable-NetAdapter',
    '(?i)New-NetFirewallRule',
    '(?i)garrysmod[/\\]addons'
)) {
    Assert-RunStatic ($guestText -notmatch $forbidden) `
        "Guest bootstrap contains forbidden behavior $forbidden"
}

$disabled = $false
try {
    Invoke-SourceOracleVPhysicsSandboxSingleRun `
        -WorkspacePath 'C:\does-not-exist' `
        -RunPath 'C:\does-not-exist-run'
} catch {
    $disabled = $_.Exception.Message -match 'explicit switch'
}
Assert-RunStatic $disabled 'Real Windows Sandbox launch is not default-deny'

Write-Output (
    'VPhysics Windows Sandbox single-run tests passed ' +
    '(static only; no installed server, process, sandbox, DLL, or network action)'
)
