$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'SourceOracleVPhysicsSandboxWorkspace.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsAttestationCommon.ps1')
. (Join-Path $toolRoot 'SourceOracleVPhysicsBuild24721267Input.ps1')

function Assert-BuildInput([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$inputs = Read-SourceOracleVPhysicsBuild24721267Inputs
$spec = $inputs.spec
$metadata = $inputs.metadata
$files = @($spec.files)
Assert-BuildInput ($files.Count -eq 127) 'Fixed build input must contain exactly 127 files'
Assert-BuildInput `
    ([string]$spec.server.executable_input_path -ceq
        'server/srcds_console_win64.exe') `
    'Fixed build input does not select the x64 CUI srcds executable'
Assert-BuildInput `
    (@($files | Where-Object {
        [string]$_.source_path -in @('srcds.exe', 'srcds_win64.exe')
    }).Count -eq 0) `
    'Fixed x64 CUI input still includes a 32-bit or GUI srcds executable'

$requiredRuntime = @(
    'srcds_console_win64.exe',
    'steamclient64.dll',
    'tier0_s64.dll',
    'vstdlib_s64.dll',
    'bin/win64/dedicated.dll',
    'bin/win64/filesystem_stdio.dll',
    'bin/win64/engine.dll',
    'bin/win64/inputsystem.dll',
    'bin/win64/materialsystem.dll',
    'bin/win64/datacache.dll',
    'bin/win64/studiorender.dll',
    'bin/win64/vphysics.dll',
    'bin/win64/vgui2.dll',
    'bin/win64/shaderapiempty.dll',
    'bin/win64/server.dll',
    'bin/win64/lua_shared.dll',
    'bin/win64/soundemittersystem.dll',
    'bin/win64/scenefilecache.dll',
    'bin/win64/tier0.dll',
    'bin/win64/vstdlib.dll',
    'bin/win64/steam_api64.dll',
    'bin/win64/unicode.dll',
    'bin/win64/resources.dll',
    'steamapps/appmanifest_4020.acf'
)
$sourcePaths = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($entry in $files) {
    [void]$sourcePaths.Add([string]$entry.source_path)
    Assert-SourceOracleSandboxSHA256 `
        -Value ([string]$entry.sha256) `
        -Field "fixed input $($entry.source_path) SHA-256"
    Assert-BuildInput ([int64]$entry.maximum_bytes -gt 0) `
        "Fixed input has no byte bound: $($entry.source_path)"
    Assert-BuildInput `
        ([string]$entry.source_path -notmatch '(?i)(^|/)addons(/|$)') `
        "Fixed input inherits addons: $($entry.source_path)"
}
foreach ($path in $requiredRuntime) {
    Assert-BuildInput $sourcePaths.Contains($path) "Fixed runtime is missing $path"
}

$isolatedLua = @($files | Where-Object {
    [string]$_.role -ceq 'isolated_game_lua'
})
Assert-BuildInput ($isolatedLua.Count -eq 88) `
    'Fixed clean game root must contain exactly 88 shipped startup Lua files'
Assert-BuildInput `
    (@($isolatedLua | Where-Object {
        -not [string]$_.source_path.StartsWith(
            'garrysmod/lua/includes/',
            [StringComparison]::Ordinal
        ) -and -not [string]$_.source_path.StartsWith(
            'garrysmod/lua/drive/',
            [StringComparison]::Ordinal
        )
    }).Count -eq 0) `
    'Fixed clean game root includes Lua outside includes/ and drive/'

$exactCleanInputs = [ordered]@{
    'garrysmod/steam.inf' = 'oracle_game/steam.inf'
    'garrysmod/maps/gm_flatgrass.bsp' = 'oracle_game/maps/gm_flatgrass.bsp'
    'sourceengine/scripts/surfaceproperties.txt' =
        'server/sourceengine/scripts/surfaceproperties.txt'
    'sourceengine/scripts/surfaceproperties_hl2.txt' =
        'server/sourceengine/scripts/surfaceproperties_hl2.txt'
    'sourceengine/scripts/surfaceproperties_manifest.txt' =
        'server/sourceengine/scripts/surfaceproperties_manifest.txt'
    'tool/VPhysicsSandboxGameRoot/gameinfo.txt' = 'oracle_game/gameinfo.txt'
    'tool/VPhysicsSandboxGameRoot/gamemodes/garryspad_attestation/garryspad_attestation.txt' =
        'oracle_game/gamemodes/garryspad_attestation/garryspad_attestation.txt'
    'tool/VPhysicsSandboxGameRoot/gamemodes/garryspad_attestation/gamemode/init.lua' =
        'oracle_game/gamemodes/garryspad_attestation/gamemode/init.lua'
    'tool/VPhysicsSandboxGameRoot/gamemodes/garryspad_attestation/gamemode/shared.lua' =
        'oracle_game/gamemodes/garryspad_attestation/gamemode/shared.lua'
    'tool/VPhysicsAttestationAddon/lua/autorun/server/garryspad_source_vphysics_attestation.lua' =
        'oracle_game/lua/autorun/server/garryspad_source_vphysics_attestation.lua'
    'tool/Run-SourceOracleVPhysicsSandboxGuest.ps1' =
        'sandbox/Run-SourceOracleVPhysicsSandboxGuest.ps1'
}
foreach ($pair in $exactCleanInputs.GetEnumerator()) {
    $matches = @($files | Where-Object {
        [string]$_.source_path -ceq $pair.Key -and
        [string]$_.input_path -ceq $pair.Value
    })
    Assert-BuildInput ($matches.Count -eq 1) `
        "Fixed clean game root is missing $($pair.Key)"
}
Assert-BuildInput `
    (@($files | Where-Object {
        [string]$_.role -ceq 'probe_lua'
    }).Count -eq 1) `
    'Fixed clean game root must contain exactly one probe Lua file'

$modelEntries = @($files | Where-Object {
    [string]$_.role -in @('model_mdl', 'model_phy', 'model_render_asset')
})
Assert-BuildInput ($modelEntries.Count -eq 4) `
    'Fixed input does not contain exactly MDL, PHY, VVD, and DX90 VTX'
foreach ($modelFile in @($metadata.model_files)) {
    $matches = @($modelEntries | Where-Object {
        [string]$_.input_path -ceq ('oracle_game/' + [string]$modelFile.logical_path)
    })
    Assert-BuildInput ($matches.Count -eq 1) `
        "Fixed input is missing $($modelFile.logical_path)"
    Assert-BuildInput ([string]$matches[0].sha256 -ceq [string]$modelFile.sha256) `
        "Fixed input hash differs for $($modelFile.logical_path)"
}

$scripts = @(
    'SourceOracleVPhysicsBuild24721267Input.ps1',
    'New-SourceOracleVPhysicsBuild24721267Stage.ps1',
    'Test-SourceOracleVPhysicsBuild24721267Input.ps1'
)
$parseErrors = [Collections.Generic.List[object]]::new()
foreach ($name in $scripts) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $toolRoot $name),
        [ref]$tokens,
        [ref]$errors
    )
    foreach ($error in $errors) { $parseErrors.Add($error) }
    $text = Get-Content -LiteralPath (Join-Path $toolRoot $name) -Raw -Encoding UTF8
    foreach ($forbidden in @(
        '\bStart-Process\b',
        '\bCreateProcess(?:W)?\b',
        '\bLoadLibrary',
        '\bNew-NetFirewallRule\b',
        '\bnetsh(?:\.exe)?\b',
        '\bWindowsSandbox(?:\.exe)?\b',
        '\bsrcds(?:_win64)?\.exe\s'
    )) {
        Assert-BuildInput ($text -notmatch $forbidden) `
            "$name contains forbidden launch behavior: $forbidden"
    }
}
Assert-BuildInput ($parseErrors.Count -eq 0) `
    "Fixed build input scripts contain $($parseErrors.Count) parser error(s)"

Write-Output (
    'AppID 4020 build 24721267 input tests passed ' +
    '(static only; no installed server, VPK payload, process, sandbox, or network read)'
)
