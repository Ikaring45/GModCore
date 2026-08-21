$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'SourceOracleVPhysicsAttestationCommon.ps1')

function Assert-Button06([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-ExactString(
    [object]$InputObject,
    [string]$Name,
    [string]$Expected
) {
    $actual = Get-SourceOracleVPhysicsString `
        -InputObject $InputObject -Name $Name -MaximumLength 512
    Assert-Button06 ($actual -ceq $Expected) "$Name differs from the fixed metadata"
}

$metadataPath = Join-Path $toolRoot `
    'VPhysicsAttestation-Button06-AllowlistMetadata.json'
$metadata = Read-SourceOracleVPhysicsBoundedJSON `
    -Path $metadataPath -MaximumBytes 65536 -Field 'button_06 metadata'

Assert-SourceOracleVPhysicsObjectShape `
    -InputObject $metadata `
    -Field 'metadata' `
    -Names @(
        'schema', 'kind', 'allowlist', 'model_files', 'provenance',
        'structural_expectations'
    )
Assert-Button06 `
    ((Get-SourceOracleVPhysicsInteger `
        -InputObject $metadata -Name 'schema' -Minimum 1 -Maximum 1) -eq 1) `
    'Unsupported button_06 metadata schema'
Assert-ExactString `
    -InputObject $metadata `
    -Name 'kind' `
    -Expected 'owned-model-vphysics-attestation-allowlist-metadata'

$allowlist = $metadata.allowlist
Assert-SourceOracleVPhysicsObjectShape `
    -InputObject $allowlist `
    -Field 'allowlist' `
    -Names @('schema', 'models')
Assert-Button06 (@($allowlist.models).Count -eq 1) `
    'Metadata must authorize exactly one model'
$allowed = @($allowlist.models)[0]
$request = [pscustomobject]@{
    schema = [int64]1
    request_id = '00000000000000000000000000000000'
    model_path = $allowed.model_path
    phy_path = $allowed.phy_path
    expected_mdl_sha256 = $allowed.mdl_sha256
    expected_phy_sha256 = $allowed.phy_sha256
    ownership_reference = $allowed.ownership_reference
    policy = [pscustomobject]@{
        search_path = 'GAME'
        allow_workshop = $false
        allow_installed_addons = $false
        allow_user_lua = $false
        allow_network = $false
    }
    limits = [pscustomobject]@{
        maximum_mdl_bytes = [int64]2540
        maximum_phy_bytes = [int64]880
        maximum_solids = [int64]1
        maximum_convexes = [int64]1
        maximum_vertices_per_convex = [int64]256
        maximum_total_vertices = [int64]256
        maximum_result_bytes = [int64]65536
        timeout_seconds = [int64]20
    }
}
[void](Assert-SourceOracleVPhysicsRequestObject `
    -Request $request -Allowlist $allowlist)

$expectedFiles = [ordered]@{
    mdl = [pscustomobject]@{
        path = 'models/maxofs2d/button_06.mdl'; bytes = 2540
        sha = '85dca39870932c39dd1bcd51afbb0fc09aaf8d90fadfeb222e7b49cd784e0f07'
        crc = '2fd818b2'; offset = 184532170
    }
    vvd = [pscustomobject]@{
        path = 'models/maxofs2d/button_06.vvd'; bytes = 14656
        sha = 'ad2ff21e37e87ac824684ccc789ccf34e6909dcd3b8b8eefec77a4ba46053c01'
        crc = '8325ea27'; offset = 184535590
    }
    vtx_dx90 = [pscustomobject]@{
        path = 'models/maxofs2d/button_06.dx90.vtx'; bytes = 3257
        sha = 'ab46b68a919be34561c6c22b78d0300e4b4cca10d68eccb0fbee199cf1af1a75'
        crc = '5a5682b1'; offset = 184528913
    }
    phy = [pscustomobject]@{
        path = 'models/maxofs2d/button_06.phy'; bytes = 880
        sha = '8901ecd8be29b5a3e5b688843bdbea13f34c7b76c5a63cb435f9ef1174527ef3'
        crc = 'a3f1f516'; offset = 184534710
    }
}
$files = @($metadata.model_files)
Assert-Button06 ($files.Count -eq $expectedFiles.Count) `
    'Metadata must contain exactly MDL, VVD, DX90 VTX, and PHY'
foreach ($file in $files) {
    Assert-SourceOracleVPhysicsObjectShape `
        -InputObject $file `
        -Field 'model_files entry' `
        -Names @(
            'kind', 'logical_path', 'byte_count', 'sha256', 'studio_checksum',
            'vpk_crc32', 'vpk_offset', 'vpk_preload_bytes'
        )
    $kind = Get-SourceOracleVPhysicsString `
        -InputObject $file -Name 'kind' -MaximumLength 16
    Assert-Button06 $expectedFiles.Contains($kind) "Unexpected model file kind: $kind"
    $expected = $expectedFiles[$kind]
    Assert-ExactString $file 'logical_path' $expected.path
    Assert-ExactString $file 'sha256' $expected.sha
    Assert-SourceOracleVPhysicsSHA256 -Value $file.sha256 -Field "$kind.sha256"
    Assert-ExactString $file 'vpk_crc32' $expected.crc
    Assert-Button06 `
        ((Get-SourceOracleVPhysicsInteger `
            -InputObject $file -Name 'byte_count' -Minimum 1 -Maximum 33554432) `
            -eq $expected.bytes) `
        "$kind byte count differs from the fixed metadata"
    Assert-Button06 `
        ((Get-SourceOracleVPhysicsInteger `
            -InputObject $file -Name 'studio_checksum' `
            -Minimum ([int64][int32]::MinValue) -Maximum ([int64][int32]::MaxValue)) `
            -eq -1817891700) `
        "$kind Studio checksum differs from its companions"
    Assert-Button06 `
        ((Get-SourceOracleVPhysicsInteger `
            -InputObject $file -Name 'vpk_offset' -Minimum 0 -Maximum 269683852) `
            -eq $expected.offset) `
        "$kind VPK offset differs from the fixed directory index"
    Assert-Button06 `
        ((Get-SourceOracleVPhysicsInteger `
            -InputObject $file -Name 'vpk_preload_bytes' -Minimum 0 -Maximum 0) `
            -eq 0) `
        "$kind unexpectedly requires VPK preload bytes"
}

$mdl = @($files | Where-Object { $_.kind -ceq 'mdl' })[0]
$phy = @($files | Where-Object { $_.kind -ceq 'phy' })[0]
Assert-Button06 ($allowed.model_path -ceq $mdl.logical_path) `
    'Allowlist MDL path differs from the exact file metadata'
Assert-Button06 ($allowed.phy_path -ceq $phy.logical_path) `
    'Allowlist PHY path differs from the exact file metadata'
Assert-Button06 ($allowed.mdl_sha256 -ceq $mdl.sha256) `
    'Allowlist MDL hash differs from the exact file metadata'
Assert-Button06 ($allowed.phy_sha256 -ceq $phy.sha256) `
    'Allowlist PHY hash differs from the exact file metadata'

$provenance = $metadata.provenance
Assert-SourceOracleVPhysicsSHA256 `
    -Value $provenance.content_pack.root_manifest_sha256 `
    -Field 'root_manifest_sha256'
Assert-SourceOracleVPhysicsSHA256 `
    -Value $provenance.directory_vpk.sha256 `
    -Field 'directory_vpk.sha256'
Assert-SourceOracleVPhysicsSHA256 `
    -Value $provenance.chunk_vpk.manifest_sha256 `
    -Field 'chunk_vpk.manifest_sha256'
Assert-Button06 (-not [bool]$provenance.chunk_vpk.whole_chunk_rehashed) `
    'Metadata incorrectly claims a whole chunk rehash'
Assert-Button06 (-not [bool]$provenance.bounded_read.whole_content_pack_revalidated) `
    'Metadata incorrectly claims a whole content-pack revalidation'
Assert-Button06 `
    ([int64]$provenance.bounded_read.total_selected_bytes -eq 553002) `
    'Bounded selected-byte accounting changed'

$structural = $metadata.structural_expectations
Assert-ExactString $structural 'status' 'unattested'
Assert-Button06 ($null -eq $structural.util_is_valid_model) `
    'Metadata must not claim util.IsValidModel before the original oracle run'
Assert-Button06 ($null -eq $structural.util_is_valid_prop) `
    'Metadata must not claim util.IsValidProp before the original oracle run'
Assert-Button06 (-not [bool]$structural.runtime_physics_eligible) `
    'Unattested structural data was promoted to runtime physics eligibility'
$expectedStructuralFacts = [ordered]@{
    mdl_version = 48; phy_header_bytes = 16; phy_identifier = 0
    phy_solid_count = 1; solid_zero_serialized_byte_count = 632
    serialization_version = 256; model_type = 0; tree_node_count = 1
    terminal_node_count = 1; compact_ledge_count = 1
    triangle_count = 20; unique_point_count = 12
}
foreach ($fact in $expectedStructuralFacts.GetEnumerator()) {
    Assert-Button06 `
        ([int64]$structural.($fact.Key) -eq [int64]$fact.Value) `
        "Structural fact $($fact.Key) differs from the bounded decode"
}
Assert-ExactString $structural 'serialization_identifier' 'VPHY'

Write-Output (
    'button_06 allowlist metadata passed static validation ' +
    '(unattested; no content pack, installed game, process, or network read)'
)
