#!/usr/bin/env python3

"""Static, cross-platform contract check for the checked-in iPad host."""

from __future__ import annotations

import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET


APP_TARGET_ID = "D10000000000000000000001"
UI_TEST_TARGET_ID = "D20000000000000000000001"
APP_BUNDLE_ID = "org.example.GarrysPAD"


def fail(message: str) -> None:
    raise SystemExit(f"iPad host validation failed: {message}")


def require_text(path: pathlib.Path) -> str:
    if not path.is_file():
        fail(f"required file is missing: {path}")
    return path.read_text(encoding="utf-8")


def require_fragments(label: str, text: str, fragments: list[str]) -> None:
    missing = [fragment for fragment in fragments if fragment not in text]
    if missing:
        fail(f"{label} is missing contract fragments: {missing!r}")


def main() -> None:
    root = (
        pathlib.Path(sys.argv[1]).resolve()
        if len(sys.argv) == 2
        else pathlib.Path.cwd().resolve()
    )
    if len(sys.argv) > 2:
        fail("usage: validate-host-project.py [repository-root]")

    host_root = root / "Apps" / "GarrysPAD"
    project_path = host_root / "GarrysPAD.xcodeproj" / "project.pbxproj"
    scheme_path = (
        host_root
        / "GarrysPAD.xcodeproj"
        / "xcshareddata"
        / "xcschemes"
        / "GarrysPAD.xcscheme"
    )
    app_path = host_root / "App" / "GarrysPADApp.swift"
    ui_test_path = host_root / "UITests" / "GarrysPADLaunchTests.swift"
    asset_catalog_path = host_root / "Resources" / "Assets.xcassets"
    workflow_path = root / ".github" / "workflows" / "validate-ipados.yml"

    project = require_text(project_path)
    require_fragments(
        "project",
        project,
        [
            f"{APP_TARGET_ID} /* GarrysPAD */",
            f"{UI_TEST_TARGET_ID} /* GarrysPADUITests */",
            'productType = "com.apple.product-type.application";',
            'productType = "com.apple.product-type.bundle.ui-testing";',
            "isa = XCLocalSwiftPackageReference;",
            "relativePath = ../..;",
            "productName = GModApp;",
            "IPHONEOS_DEPLOYMENT_TARGET = 16.0;",
            "TARGETED_DEVICE_FAMILY = 2;",
            "SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";",
            "SUPPORTS_MACCATALYST = NO;",
            f"PRODUCT_BUNDLE_IDENTIFIER = {APP_BUNDLE_ID};",
            "CODE_SIGN_STYLE = Automatic;",
            "TEST_TARGET_NAME = GarrysPAD;",
        ],
    )
    if "CODE_SIGNING_ALLOWED" in project or "CODE_SIGNING_REQUIRED" in project:
        fail("signing must be disabled by CI overrides, not project settings")
    if re.search(r"TARGETED_DEVICE_FAMILY\s*=\s*[^;]*1", project):
        fail("the host must not include iPhone device family 1")
    if project.count('productType = "com.apple.product-type.application";') != 1:
        fail("expected exactly one application target")
    if project.count("productName = GModApp;") != 1:
        fail("expected exactly one local GModApp product dependency")

    app_source = require_text(app_path)
    require_fragments(
        "application source",
        app_source,
        [
            "import GModApp",
            "@main",
            "GModMainView()",
            '.accessibilityIdentifier(Self.rootAccessibilityIdentifier)',
            'rootAccessibilityIdentifier = "garrys-pad-root"',
        ],
    )

    ui_test_source = require_text(ui_test_path)
    require_fragments(
        "UI launch smoke",
        ui_test_source,
        [
            "XCUIApplication()",
            "app.launch()",
            '.matching(identifier: "garrys-pad-root")',
            "waitForExistence(timeout: 30)",
        ],
    )

    if not scheme_path.is_file():
        fail(f"shared scheme is missing: {scheme_path}")
    try:
        scheme = ET.parse(scheme_path).getroot()
    except ET.ParseError as error:
        fail(f"shared scheme is not valid XML: {error}")
    if scheme.tag != "Scheme":
        fail(f"unexpected shared scheme root: {scheme.tag!r}")

    buildable_ids = {
        element.attrib.get("BlueprintIdentifier")
        for element in scheme.iter("BuildableReference")
    }
    if APP_TARGET_ID not in buildable_ids or UI_TEST_TARGET_ID not in buildable_ids:
        fail("shared scheme does not reference both app and UI-test targets")
    testable_ids = {
        element.find("BuildableReference").attrib.get("BlueprintIdentifier")
        for element in scheme.iter("TestableReference")
        if element.find("BuildableReference") is not None
    }
    if testable_ids != {UI_TEST_TARGET_ID}:
        fail(f"unexpected shared scheme test targets: {sorted(testable_ids)!r}")

    for json_path in (
        asset_catalog_path / "Contents.json",
        asset_catalog_path / "AccentColor.colorset" / "Contents.json",
    ):
        try:
            json.loads(require_text(json_path))
        except json.JSONDecodeError as error:
            fail(f"asset catalog JSON is invalid at {json_path}: {error}")

    workflow = require_text(workflow_path)
    require_fragments(
        "iPadOS workflow",
        workflow,
        [
            'APP_PROJECT: Apps/GarrysPAD/GarrysPAD.xcodeproj',
            "xcrun simctl install",
            "xcrun simctl launch",
            "GarrysPADUITests/GarrysPADLaunchTests/testRootIsAccessibleAfterLaunch",
            "CODE_SIGNING_ALLOWED=NO",
        ],
    )

    print("iPad host static contract passed")
    print(f"  project: {project_path.relative_to(root)}")
    print(f"  app target: GarrysPAD ({APP_BUNDLE_ID})")
    print("  platform: iPad only, iPadOS 16.0")
    print("  local package product: GModApp")
    print("  UI launch smoke: garrys-pad-root")


if __name__ == "__main__":
    main()
