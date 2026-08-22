#!/usr/bin/env bash

set -euo pipefail

repo_root="${1:-$(pwd -P)}"
source_file="$repo_root/Sources/GModMetal/GModMetalView.swift"
color_contract_file="$repo_root/Sources/GModMetal/GModMetalWorldColorSpaceContract.swift"

if [[ ! -f "$source_file" ]]; then
  echo "GModMetalView.swift was not found at: $source_file" >&2
  exit 1
fi

if [[ ! -f "$color_contract_file" ]]; then
  echo "GModMetalWorldColorSpaceContract.swift was not found at: $color_contract_file" >&2
  exit 1
fi

temp_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
work_dir="$(mktemp -d "$temp_parent/gmod-ipados-metal.XXXXXX")"

cleanup() {
  case "$work_dir" in
    "$temp_parent"/gmod-ipados-metal.*)
      rm -rf -- "$work_dir"
      ;;
    *)
      echo "Refusing to remove unexpected temporary path: $work_dir" >&2
      ;;
  esac
}
trap cleanup EXIT

metal_source="$work_dir/GModMetalViewShaders.metal"
metal_air="$work_dir/GModMetalViewShaders.air"
metal_library="$work_dir/GModMetalViewShaders.metallib"

python3 - "$source_file" "$color_contract_file" "$metal_source" <<'PY'
import pathlib
import re
import sys

source_path = pathlib.Path(sys.argv[1])
contract_path = pathlib.Path(sys.argv[2])
output_path = pathlib.Path(sys.argv[3])
swift_source = source_path.read_text(encoding="utf-8")
contract_source = contract_path.read_text(encoding="utf-8")

marker = "private static let shaderSource"
marker_index = swift_source.find(marker)
if marker_index < 0:
    raise SystemExit(f"Embedded Metal marker not found in {source_path}")

opening_index = swift_source.find('"""', marker_index + len(marker))
if opening_index < 0:
    raise SystemExit("Embedded Metal source has no opening triple quote")
closing_index = swift_source.find('"""', opening_index + 3)
if closing_index < 0:
    raise SystemExit("Embedded Metal source has no closing triple quote")

contract_marker = "static let metalShaderSupport"
contract_marker_index = contract_source.find(contract_marker)
if contract_marker_index < 0:
    raise SystemExit(f"Metal color support marker not found in {contract_path}")
contract_opening = contract_source.find('"""', contract_marker_index)
contract_closing = contract_source.find('"""', contract_opening + 3)
if contract_opening < 0 or contract_closing < 0:
    raise SystemExit("Metal color support has an invalid triple-quoted string")

suffix_opening = swift_source.find('"""', closing_index + 3)
suffix_closing = swift_source.find('"""', suffix_opening + 3)
if suffix_opening < 0 or suffix_closing < 0:
    raise SystemExit("Embedded Metal source has no concatenated shader suffix")

metal = (
    swift_source[opening_index + 3 : closing_index]
    + contract_source[contract_opening + 3 : contract_closing]
    + swift_source[suffix_opening + 3 : suffix_closing]
)
expected_functions = {
    "worldVertexMain",
    "dynamicEntityVertexMain",
    "worldFragmentMain",
    "worldTexturedFragmentMain",
    "worldLightmappedFragmentMain",
    "worldTexturedLightmappedFragmentMain",
    "worldMissingMaterialFragmentMain",
    "worldSkyboxFragmentMain",
    "worldSunSpriteVertexMain",
    "worldSunSpriteFragmentMain",
    "worldWaterSolidFragmentMain",
    "worldWaterNormalFragmentMain",
    "worldWaterCompositeSolidFragmentMain",
    "worldWaterCompositeNormalFragmentMain",
    "worldSceneCopyVertexMain",
    "worldSceneCopyFragmentMain",
    "surfaceVertexMain",
    "surfaceSolidFragmentMain",
    "surfaceTexturedFragmentMain",
}
declared_functions = set(
    re.findall(r"\b(?:vertex|fragment)\s+\w+(?:<[^>]+>)?\s+(\w+)\s*\(", metal)
)
missing_functions = sorted(expected_functions - declared_functions)
if missing_functions:
    raise SystemExit(
        "Embedded Metal source is missing functions: "
        + ", ".join(missing_functions)
    )

normalized_swift = re.sub(r"\s+", " ", swift_source)
required_pipeline_contract = {
    "let colorPixelFormat: MTLPixelFormat = GModMetalWorldColorSpaceContract.drawablePixelFormat",
    "let depthPixelFormat: MTLPixelFormat = .depth32Float",
    "view.colorPixelFormat = colorPixelFormat",
    "view.depthStencilPixelFormat = depthPixelFormat",
    "color.isBlendingEnabled = true",
    "color.rgbBlendOperation = .add",
    "color.alphaBlendOperation = .add",
    "color.sourceRGBBlendFactor = .one",
    "color.destinationRGBBlendFactor = .oneMinusSourceAlpha",
    "color.sourceAlphaBlendFactor = .one",
    "color.destinationAlphaBlendFactor = .oneMinusSourceAlpha",
    "worldDescriptor.colorAttachments[0].loadAction = .load",
    "descriptor.depthAttachment.loadAction = .clear",
    "descriptor.mipmapLevelCount = bitmap.mipLevels.count",
    "for (level, mip) in bitmap.mipLevels.enumerated()",
    "GModMetalSky3DProjectionContract.bakedClipPlanes",
    "GModMetalSurfaceTextureUploadContract.mipmapLevelCount",
    "$0.renderLayer == .sky3D && $0.waterSurface != nil",
    "private let dynamicEntityScene: GModMetalDynamicEntityScene?",
    "case clear",
    "static let maximumGeometryByteCount = 128 * 1_024 * 1_024",
    "static let maximumTextureCount = 512",
    "static let maximumTextureByteCount = 64 * 1_024 * 1_024",
    "private struct DynamicEntityUploadBudget",
    "static let maximumResourceCount = 1",
    "static let maximumByteCount = 16 * 1_024 * 1_024",
    "bitmap.alphaRepresentation == .straight",
    "GModMetalWorldSamplerConfiguration(",
    "renderLayer: .world",
    "resourceID: GModMetalDynamicEntityResourceID",
    "instance.identity.handle.rawValue",
    "constant DynamicEntityTransform &model [[buffer(2)]]",
    "var worldUploadBudget = WorldUploadBudget()",
    "clipPlane: GModMetalWaterClipPlaneContract.disabled",
    "draws3DSky: false",
    "compositeDescriptor.colorAttachments[0].loadAction = .load",
    "float fresnel = pow(1.0 - normalDotEye, 5.0)",
    "float2 normalOffset = tangentNormal.xy * normalAlpha",
    "float2 reflectionUV = baseUV + normalOffset * amounts.x",
    "float2 refractionUV = baseUV + normalOffset * amounts.y",
}
missing_contract = sorted(
    phrase for phrase in required_pipeline_contract if phrase not in normalized_swift
)
if missing_contract:
    raise SystemExit(
        "GModMetalView pipeline contract changed; update the exact smoke helper: "
        + ", ".join(missing_contract)
    )

texture_key_match = re.search(
    r"private struct DynamicEntityTextureKey: Hashable \{([^}]*)\}",
    swift_source,
    re.DOTALL,
)
if texture_key_match is None:
    raise SystemExit("Dynamic texture digest key declaration is missing")
if "resourceID" in texture_key_match.group(1):
    raise SystemExit(
        "Dynamic textures must deduplicate by bitmap digest, not resource ID"
    )

if swift_source.count("WorldUploadBudget()") != 1:
    raise SystemExit(
        "World texture upload budget must be created exactly once per frame"
    )
if "compositeEncoder.setRenderPipelineState(worldSceneCopyPipeline)" in normalized_swift:
    raise SystemExit(
        "Water targets must not replace the ordinary drawable scene"
    )

opaque_loop = normalized_swift.find(
    "for range in ranges where range.renderLayer == .world && "
    "range.waterSurface == nil"
)
dynamic_draw = normalized_swift.find(
    "drawDynamicEntities(",
    opaque_loop if opaque_loop >= 0 else 0,
)
water_pass = normalized_swift.find(
    "encoder.setDepthStencilState(waterDepthState)",
    dynamic_draw if dynamic_draw >= 0 else 0,
)
if not (0 <= opaque_loop < dynamic_draw < water_pass):
    raise SystemExit(
        "Dynamic prop pass must remain after opaque BSP and before water"
    )
world_call = normalized_swift.find("let drawResult = drawWorld(")
surface_pass = normalized_swift.find(
    "if let surfaceScene = activeSurfaceScene",
    world_call if world_call >= 0 else 0,
)
if not (0 <= world_call < surface_pass):
    raise SystemExit("Surface pass must remain after the world composite pass")

output_path.write_text(metal, encoding="utf-8", newline="\n")
print(f"Extracted {len(metal.encode('utf-8'))} bytes from {source_path}")
print("Embedded Metal functions:", ", ".join(sorted(expected_functions)))
PY

if [[ "${GMOD_METAL_STATIC_ONLY:-0}" == "1" ]]; then
  echo "Embedded Metal static contract passed (Apple compile intentionally skipped)"
  exit 0
fi

xcrun --sdk iphoneos metal \
  -Werror \
  -target air64-apple-ios16.0 \
  -c "$metal_source" \
  -o "$metal_air"
xcrun --sdk iphoneos metallib \
  "$metal_air" \
  -o "$metal_library"

if [[ ! -s "$metal_library" ]]; then
  echo "iphoneos metallib output is empty: $metal_library" >&2
  exit 1
fi

echo "iphoneos Metal compile and metallib link passed"

runtime_source="$repo_root/Tools/iPadValidation/MetalPipelineSmoke.swift"
runtime_binary="$work_dir/MetalPipelineSmoke"

if [[ ! -f "$runtime_source" ]]; then
  echo "Metal runtime smoke helper was not found at: $runtime_source" >&2
  exit 1
fi

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework Foundation \
  -framework Metal \
  "$runtime_source" \
  -o "$runtime_binary"

set +e
"$runtime_binary" "$metal_source"
runtime_status=$?
set -e

case "$runtime_status" in
  0)
    echo "Runtime Metal pipeline smoke passed"
    ;;
  78)
    echo "::notice::No Metal device is exposed by this macOS runner; iphoneos MSL compilation passed, but runtime pipeline creation remains a physical Apple-device gate."
    ;;
  *)
    echo "Runtime Metal pipeline smoke failed with exit code $runtime_status" >&2
    exit "$runtime_status"
    ;;
esac
