$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$common = Join-Path $toolRoot 'SourceOracleVPhysicsSandboxWorkspace.ps1'
. $common

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

function Copy-JSONValue([object]$Value) {
    return $Value | ConvertTo-Json -Depth 32 -Compress | ConvertFrom-Json
}

function Write-TestBytes([string]$Path, [string]$Value) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllBytes($Path, [Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-TestSHA([string]$Path) {
    return (Get-SourceOracleSandboxFileFingerprint -Path $Path -MaximumBytes 4096).sha256
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = [IO.Path]::Combine(
    $tempParent,
    'source-oracle-vphysics-sandbox-' + [Guid]::NewGuid().ToString('N')
)
Assert-True (
    $fixtureRoot.StartsWith($tempParent + '\', [StringComparison]::OrdinalIgnoreCase)
) 'Synthetic fixture escaped the system temp directory'
[void][IO.Directory]::CreateDirectory($fixtureRoot)

try {
    $sourceRoot = [IO.Path]::Combine($fixtureRoot, 'fresh-app-4020')
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    $sourceFiles = [ordered]@{
        'srcds.exe' = 'synthetic srcds executable bytes'
        'bin/win64/engine.dll' = 'synthetic engine module bytes'
        'bin/win64/server.dll' = 'synthetic game server module bytes'
        'bin/win64/vphysics.dll' = 'synthetic vphysics module bytes'
        'bin/win64/tier0.dll' = 'synthetic tier0 module bytes'
        'owned/attested_prop.mdl' = 'IDST synthetic model bytes'
        'owned/attested_prop.phy' = 'VPHY synthetic collision bytes'
    }
    foreach ($pair in $sourceFiles.GetEnumerator()) {
        Write-TestBytes `
            -Path (Get-SourceOracleSandboxChildPath -Root $sourceRoot -RelativePath $pair.Key) `
            -Value $pair.Value
    }

    $modelPath = 'models/owned_fixture/attested_prop.mdl'
    $phyPath = 'models/owned_fixture/attested_prop.phy'
    $entries = @(
        [pscustomobject][ordered]@{
            role = 'server_executable'; source_path = 'srcds.exe'
            input_path = 'server/srcds.exe'; sha256 = Get-TestSHA (
                Get-SourceOracleSandboxChildPath -Root $sourceRoot -RelativePath 'srcds.exe'
            ); maximum_bytes = [int64]4096
        },
        [pscustomobject][ordered]@{
            role = 'engine_module'; source_path = 'bin/win64/engine.dll'
            input_path = 'server/bin/win64/engine.dll'; sha256 = Get-TestSHA (
                Get-SourceOracleSandboxChildPath -Root $sourceRoot `
                    -RelativePath 'bin/win64/engine.dll'
            ); maximum_bytes = [int64]4096
        },
        [pscustomobject][ordered]@{
            role = 'game_server_module'; source_path = 'bin/win64/server.dll'
            input_path = 'server/bin/win64/server.dll'; sha256 = Get-TestSHA (
                Get-SourceOracleSandboxChildPath -Root $sourceRoot `
                    -RelativePath 'bin/win64/server.dll'
            ); maximum_bytes = [int64]4096
        },
        [pscustomobject][ordered]@{
            role = 'vphysics_module'; source_path = 'bin/win64/vphysics.dll'
            input_path = 'server/bin/win64/vphysics.dll'; sha256 = Get-TestSHA (
                Get-SourceOracleSandboxChildPath -Root $sourceRoot `
                    -RelativePath 'bin/win64/vphysics.dll'
            ); maximum_bytes = [int64]4096
        },
        [pscustomobject][ordered]@{
            role = 'tier0_module'; source_path = 'bin/win64/tier0.dll'
            input_path = 'server/bin/win64/tier0.dll'; sha256 = Get-TestSHA (
                Get-SourceOracleSandboxChildPath -Root $sourceRoot `
                    -RelativePath 'bin/win64/tier0.dll'
            ); maximum_bytes = [int64]4096
        },
        [pscustomobject][ordered]@{
            role = 'model_mdl'; source_path = 'owned/attested_prop.mdl'
            input_path = 'oracle_game/models/owned_fixture/attested_prop.mdl'
            sha256 = Get-TestSHA (
                Get-SourceOracleSandboxChildPath -Root $sourceRoot `
                    -RelativePath 'owned/attested_prop.mdl'
            ); maximum_bytes = [int64]4096
        },
        [pscustomobject][ordered]@{
            role = 'model_phy'; source_path = 'owned/attested_prop.phy'
            input_path = 'oracle_game/models/owned_fixture/attested_prop.phy'
            sha256 = Get-TestSHA (
                Get-SourceOracleSandboxChildPath -Root $sourceRoot `
                    -RelativePath 'owned/attested_prop.phy'
            ); maximum_bytes = [int64]4096
        }
    )
    $spec = [pscustomobject][ordered]@{
        schema = [int64]1
        kind = 'fresh-steamcmd-app-4020-x86-64-attestation-input'
        steam = [pscustomobject][ordered]@{
            app_id = [int64]4020
            branch = 'x86-64'
            build_id = '24721252'
        }
        ownership_reference = 'synthetic-non-launch-fixture'
        server = [pscustomobject][ordered]@{
            executable_input_path = 'server/srcds.exe'
            engine_input_path = 'server/bin/win64/engine.dll'
            game_server_input_path = 'server/bin/win64/server.dll'
            vphysics_input_path = 'server/bin/win64/vphysics.dll'
            tier0_input_path = 'server/bin/win64/tier0.dll'
        }
        model = [pscustomobject][ordered]@{
            model_path = $modelPath
            phy_path = $phyPath
        }
        files = $entries
    }
    $specPath = [IO.Path]::Combine($fixtureRoot, 'allowlist.json')
    Write-SourceOracleSandboxUTF8 -Path $specPath `
        -Text (($spec | ConvertTo-Json -Depth 16) + "`r`n")

    $workspace = [IO.Path]::Combine($fixtureRoot, 'workspace')
    $state = New-SourceOracleVPhysicsSandboxWorkspace `
        -SourceRoot $sourceRoot -InputSpecPath $specPath -WorkspacePath $workspace
    Assert-True (-not [bool]$state.probe_enabled) 'Generator enabled a probe'
    Assert-True ([bool]$state.prerequisites_verified) 'Generator did not verify prerequisites'
    $validated = Assert-SourceOracleVPhysicsSandboxWorkspace -WorkspacePath $workspace
    Assert-True ($validated.steam.app_id -eq 4020) 'Workspace lost AppID 4020 binding'

    $wsbPath = [IO.Path]::Combine($workspace, 'SourceVPhysicsAttestation.wsb')
    $wsb = [IO.File]::ReadAllText($wsbPath, [Text.Encoding]::UTF8)
    Assert-True ($wsb.Contains('<Networking>Disable</Networking>')) (
        'Sandbox networking is not disabled'
    )
    Assert-True ($wsb.Contains('<ReadOnly>true</ReadOnly>')) (
        'Sandbox input mapping is not read-only'
    )
    Assert-True ($wsb.Contains('<ReadOnly>false</ReadOnly>')) (
        'Sandbox output mapping is not writable'
    )
    Assert-True (-not $wsb.Contains('<LogonCommand>')) (
        'Prerequisite config contains a launch command'
    )
    $mount = [IO.File]::ReadAllText(
        [IO.Path]::Combine($workspace, 'input\oracle_game\cfg\mount.cfg')
    )
    $depots = [IO.File]::ReadAllText(
        [IO.Path]::Combine($workspace, 'input\oracle_game\cfg\mountdepots.txt')
    )
    Assert-True ($mount -ceq "`"mountcfg`"`r`n{`r`n}`r`n") 'mount.cfg is not empty'
    Assert-True ($depots -ceq "`"gamedepotsystem`"`r`n{`r`n}`r`n") (
        'mountdepots.txt is not empty'
    )

    $originalWSB = $wsb
    Write-SourceOracleSandboxUTF8 -Path $wsbPath `
        -Text $wsb.Replace('<Networking>Disable</Networking>', '<Networking>Enable</Networking>')
    Assert-Throws {
        Assert-SourceOracleVPhysicsSandboxWorkspace -WorkspacePath $workspace | Out-Null
    } 'Networking-enabled sandbox config was accepted'
    Write-SourceOracleSandboxUTF8 -Path $wsbPath -Text $originalWSB

    $outputCanary = [IO.Path]::Combine($workspace, 'output\unexpected.txt')
    Write-TestBytes -Path $outputCanary -Value 'must be rejected'
    Assert-Throws {
        Assert-SourceOracleVPhysicsSandboxWorkspace -WorkspacePath $workspace | Out-Null
    } 'Non-empty writable output was accepted'
    [IO.File]::Delete($outputCanary)

    $tamperedInput = [IO.Path]::Combine(
        $workspace,
        'input\server\bin\win64\vphysics.dll'
    )
    [IO.File]::AppendAllText($tamperedInput, 'tamper', [Text.Encoding]::UTF8)
    Assert-Throws {
        Assert-SourceOracleVPhysicsSandboxWorkspace -WorkspacePath $workspace | Out-Null
    } 'Input changed after manifest verification was accepted'

    $badAddonSpec = Copy-JSONValue $spec
    $badAddonSpec.files[0].source_path = 'garrysmod/addons/foreign/srcds.exe'
    Assert-Throws {
        Assert-SourceOracleVPhysicsSandboxInputSpec -Spec $badAddonSpec | Out-Null
    } 'Inherited garrysmod/addons path was accepted'

    $missingRoleSpec = Copy-JSONValue $spec
    $missingRoleSpec.files = @($missingRoleSpec.files | Where-Object {
        $_.role -cne 'vphysics_module'
    })
    Assert-Throws {
        Assert-SourceOracleVPhysicsSandboxInputSpec -Spec $missingRoleSpec | Out-Null
    } 'Spec without exact VPhysics DLL allowlist was accepted'

    $wrongHashSpec = Copy-JSONValue $spec
    $wrongHashSpec.files[0].sha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $wrongHashPath = [IO.Path]::Combine($fixtureRoot, 'wrong-hash.json')
    Write-SourceOracleSandboxUTF8 -Path $wrongHashPath `
        -Text (($wrongHashSpec | ConvertTo-Json -Depth 16) + "`r`n")
    Assert-Throws {
        New-SourceOracleVPhysicsSandboxWorkspace `
            -SourceRoot $sourceRoot `
            -InputSpecPath $wrongHashPath `
            -WorkspacePath ([IO.Path]::Combine($fixtureRoot, 'wrong-hash-workspace')) | Out-Null
    } 'Generator copied a server binary whose SHA-256 did not match'

    $parserErrors = [Collections.Generic.List[object]]::new()
    foreach ($scriptName in @(
        'SourceOracleVPhysicsSandboxWorkspace.ps1',
        'New-SourceOracleVPhysicsSandboxWorkspace.ps1',
        'Test-SourceOracleVPhysicsSandboxWorkspace.ps1'
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
    Assert-True ($parserErrors.Count -eq 0) (
        "PowerShell parser found $($parserErrors.Count) error(s)"
    )

    foreach ($scriptName in @(
        'SourceOracleVPhysicsSandboxWorkspace.ps1',
        'New-SourceOracleVPhysicsSandboxWorkspace.ps1'
    )) {
        $text = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $toolRoot $scriptName)
        foreach ($forbidden in @(
            '\bStart-Process\b',
            '\bCreateProcess(?:W)?\b',
            '\bLoadLibrary',
            '\bNew-NetFirewallRule\b',
            '\bnetsh(?:\.exe)?\b',
            '\bwsb(?:\.exe)?\s+(?:start|exec)\b',
            '\bsteamcmd(?:\.exe)?\s+[+-]'
        )) {
            Assert-True ($text -notmatch $forbidden) (
                "$scriptName contains forbidden launch or firewall behavior: $forbidden"
            )
        }
    }

    Write-Output (
        'Clean AppID 4020 VPhysics sandbox workspace tests passed ' +
        '(synthetic/static only; no download, sandbox, GMod, DLL, or firewall action occurred)'
    )
} finally {
    if ([IO.Directory]::Exists($fixtureRoot)) {
        [IO.Directory]::Delete($fixtureRoot, $true)
    }
}
