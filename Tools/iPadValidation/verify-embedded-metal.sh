#!/usr/bin/env bash

set -euo pipefail

repo_root="${1:-$(pwd -P)}"
source_file="$repo_root/Sources/GModMetal/GModMetalView.swift"

if [[ ! -f "$source_file" ]]; then
  echo "GModMetalView.swift was not found at: $source_file" >&2
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

python3 - "$source_file" "$metal_source" <<'PY'
import pathlib
import re
import sys

source_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
swift_source = source_path.read_text(encoding="utf-8")

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

metal = swift_source[opening_index + 3 : closing_index]
expected_functions = {
    "worldVertexMain",
    "worldFragmentMain",
    "worldTexturedFragmentMain",
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
    "let colorPixelFormat: MTLPixelFormat = .bgra8Unorm",
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
}
missing_contract = sorted(
    phrase for phrase in required_pipeline_contract if phrase not in normalized_swift
)
if missing_contract:
    raise SystemExit(
        "GModMetalView pipeline contract changed; update the exact smoke helper: "
        + ", ".join(missing_contract)
    )

output_path.write_text(metal, encoding="utf-8", newline="\n")
print(f"Extracted {len(metal.encode('utf-8'))} bytes from {source_path}")
print("Embedded Metal functions:", ", ".join(sorted(expected_functions)))
PY

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
