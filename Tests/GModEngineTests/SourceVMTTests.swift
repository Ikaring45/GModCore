import XCTest
import GModEngine

final class SourceVMTTests: XCTestCase {
    func testOrderedDocumentPreservesSpellingDuplicatesProxiesAndExplicitTypes() throws {
        let document = try SourceVMTDocument.parse(
            source: #"""
            "VertexLitGeneric"
            {
                "$BaseTexture" "models/example/a"
                "$basetexture" "models/example/b"
                "$number" "2.5"
                "$enabled" "-2"
                "$color" "[1 0.5 0.25]"
                "$transform" "center .5 .5 scale 2 1 rotate 90 translate .1 .2"
                "$matrix" "[1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1]"
                "Proxies"
                {
                    "Sine" { "resultVar" "$alpha" }
                    "Sine" { "resultVar" "$detailblendfactor" }
                }
            }
            """#
        )

        XCTAssertEqual(document.shader, "VertexLitGeneric")
        XCTAssertEqual(
            document.entries(named: "$BASETEXTURE").map(\.key),
            ["$BaseTexture", "$basetexture"]
        )
        XCTAssertEqual(
            try scalar(document.firstEntry(named: "$basetexture")),
            "models/example/a"
        )
        XCTAssertEqual(
            try scalar(document.lastEntry(named: "$basetexture")),
            "models/example/b"
        )
        XCTAssertEqual(try document.number(named: "$number"), 2.5)
        XCTAssertEqual(try document.boolean(named: "$enabled"), true)
        XCTAssertEqual(
            try document.vector(named: "$color", componentCount: 3...3),
            [1, 0.5, 0.25]
        )
        XCTAssertEqual(
            try document.matrix(named: "$transform"),
            .textureTransform(
                center: SourceVMTVector2(x: 0.5, y: 0.5),
                scale: SourceVMTVector2(x: 2, y: 1),
                rotationDegrees: 90,
                translation: SourceVMTVector2(x: 0.1, y: 0.2)
            )
        )
        XCTAssertEqual(
            try document.matrix(named: "$matrix"),
            .matrix4x4([
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1
            ])
        )
        XCTAssertEqual(document.proxies.map(\.name), ["Sine", "Sine"])
        XCTAssertEqual(
            try scalar(document.proxies[1].parameters.first),
            "$detailblendfactor"
        )
    }

    func testVBSPNestedPatchAppliesOuterReplaceToImmediatePatchNotFinalShader() throws {
        let sources = [
            "materials/base.vmt": #"""
            "UnlitGeneric"
            {
                "$Existing" "base"
                "$Existing" "duplicate-remains"
                "Proxies"
                {
                    "Sine" { "resultVar" "$alpha" }
                }
            }
            """#,
            "materials/middle.vmt": #"""
            "Patch"
            {
                "include" "materials/base.vmt"
                "insert"
                {
                    "$existing" "middle"
                    "$new" "inserted"
                    "IgnoredObject" { "value" "not-inserted" }
                    "Proxies"
                    {
                        "LinearRamp" { "resultVar" "$frame" }
                    }
                }
            }
            """#
        ]
        let resolver = SourceVMTIncludeResolver { sources[$0] }
        let document = try SourceVMTDocument.parse(
            source: #"""
            "Patch"
            {
                "include" "materials/middle.vmt"
                "replace"
                {
                    "$EXISTING" "final"
                    "$not-present" "must-not-appear"
                    "Proxies"
                    {
                        "Sine" { "resultVar" "$color" }
                        "Missing" { "resultVar" "$ignored" }
                    }
                }
            }
            """#,
            sourceName: "materials/final.vmt",
            resolver: resolver
        )

        XCTAssertEqual(document.shader, "UnlitGeneric")
        let duplicateValues = try document.entries(named: "$existing").map(scalar)
        // VBSP ExpandPatchFile does not recursively resolve middle.vmt before
        // applying the outer replace. Since the immediate Patch root has no
        // $existing scalar, "final" is discarded; the middle insert wins when
        // that Patch is expanded on the following loop iteration.
        XCTAssertEqual(duplicateValues, ["middle", "duplicate-remains"])
        XCTAssertEqual(document.firstEntry(named: "$existing")?.key, "$Existing")
        XCTAssertEqual(try document.string(named: "$new"), "inserted")
        XCTAssertNil(document.firstEntry(named: "$not-present"))
        XCTAssertNil(document.firstEntry(named: "IgnoredObject"))

        // Official materialpatch.cpp ignores TYPE_NONE subkey/object entries;
        // Patch cannot recursively insert or replace proxy blocks.
        XCTAssertEqual(document.proxies.map(\.name), ["Sine"])
        XCTAssertEqual(
            try scalar(document.proxies[0].parameters.first),
            "$alpha"
        )
    }

    func testVBSPInsertAssignmentHidesReplaceFromTheSamePatch() throws {
        let sources = [
            "materials/base.vmt": #"""
            "UnlitGeneric"
            {
                "$existing" "base"
            }
            """#
        ]
        let document = try SourceVMTDocument.parse(
            source: #"""
            "Patch"
            {
                "include" "materials/base.vmt"
                "insert"
                {
                    "$existing" "inserted"
                    "$new" "inserted-new"
                }
                "replace"
                {
                    "$existing" "replace-must-not-run"
                }
            }
            """#,
            sourceName: "materials/both.vmt",
            resolver: SourceVMTIncludeResolver { sources[$0] }
        )

        // materialpatch.cpp assigns the included KeyValues tree after insert,
        // then searches that assigned tree for "replace". The original Patch's
        // replace section is therefore no longer reachable.
        XCTAssertEqual(document.shader, "UnlitGeneric")
        XCTAssertEqual(try document.string(named: "$existing"), "inserted")
        XCTAssertEqual(try document.string(named: "$new"), "inserted-new")
    }

    func testPatchMissingCycleAndDepthAreExplicit() throws {
        XCTAssertThrowsError(
            try SourceVMTDocument.parse(
                source: #""Patch" { "include" "materials/missing.vmt" }"#
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceVMTError,
                .includeResolverRequired("materials/missing.vmt")
            )
        }

        let cycleSources = [
            "materials/b.vmt": #""Patch" { "include" "MATERIALS\A.VMT" }"#
        ]
        XCTAssertThrowsError(
            try SourceVMTDocument.parse(
                source: #""Patch" { "include" "materials/b.vmt" }"#,
                sourceName: "materials/a.vmt",
                resolver: SourceVMTIncludeResolver { cycleSources[$0] }
            )
        ) { error in
            guard case let SourceVMTError.includeCycle(paths) = error else {
                return XCTFail("expected includeCycle, got \(error)")
            }
            // A command-less Patch is not assigned its include by VBSP's
            // implementation. Our explicit cycle guard catches that no-op
            // include loop instead of waiting for the ten-iteration warning.
            XCTAssertEqual(paths.last, "materials/b.vmt")
        }

        let depthSources = [
            "materials/b.vmt": #""Patch" { "include" "materials/base.vmt" }"#,
            "materials/base.vmt": #""UnlitGeneric" { "$x" "1" }"#
        ]
        XCTAssertThrowsError(
            try SourceVMTDocument.parse(
                source: #""Patch" { "include" "materials/b.vmt" }"#,
                sourceName: "materials/a.vmt",
                resolver: SourceVMTIncludeResolver { depthSources[$0] },
                maximumPatchDepth: 1
            )
        ) { error in
            guard case SourceVMTError.maximumPatchDepthExceeded(1, _) = error else {
                return XCTFail("expected maximumPatchDepthExceeded, got \(error)")
            }
        }
    }

    func testTypedConversionRejectsMalformedValuesWithoutGuessing() throws {
        let document = try SourceVMTDocument.parse(
            source: #"""
            "UnlitGeneric"
            {
                "$unknown" "custom addon payload"
                "$number" "12units"
                "$bool" "true"
                "$vector" "[1 nope 3]"
                "$matrix" "center .5 .5 rotate 0"
            }
            """#
        )
        XCTAssertEqual(try document.string(named: "$unknown"), "custom addon payload")
        XCTAssertThrowsError(try document.number(named: "$number"))
        XCTAssertThrowsError(try document.boolean(named: "$bool"))
        XCTAssertThrowsError(try document.vector(named: "$vector"))
        XCTAssertThrowsError(try document.matrix(named: "$matrix"))
    }

    private func scalar(_ entry: SourceKeyValuesParser.Entry?) throws -> String {
        let entry = try XCTUnwrap(entry)
        guard case let .string(value) = entry.value else {
            return try XCTUnwrap(nil as String?, "expected scalar VMT value")
        }
        return value
    }
}
