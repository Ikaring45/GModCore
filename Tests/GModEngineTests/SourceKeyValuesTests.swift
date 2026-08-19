import Foundation
import XCTest
import GModEngine

final class SourceKeyValuesTests: XCTestCase {
    func testFixtureParsesCommentsQuotedBareNestedDuplicatesAndConditionals() throws {
        let source = try fixtureSource()
        var parser = SourceKeyValuesParser(
            source: source,
            options: .init(
                usesEscapeSequences: false,
                preserveKeyCase: true,
                preserveConditionals: true
            )
        )

        let roots = try parser.parse()
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].key, "Root")
        guard case let .object(entries) = roots[0].value else {
            return XCTFail("expected a root object")
        }

        XCTAssertEqual(
            entries.map(\.key),
            ["Quoted Key", "bareKey", "Nested", "Same", "Same", "Conditional"]
        )
        XCTAssertEqual(entries[0].value, .string("quoted value"))
        XCTAssertEqual(entries[1].value, .string("bareValue"))
        XCTAssertEqual(entries[3].value, .string("first"))
        XCTAssertEqual(entries[4].value, .string("last"))
        XCTAssertEqual(entries[5].conditional, "$WIN32")

        guard case let .object(nested) = entries[2].value else {
            return XCTFail("expected a nested object")
        }
        XCTAssertEqual(nested.count, 1)
        XCTAssertEqual(nested[0].key, "Child")
        XCTAssertEqual(nested[0].value, .string("yes"))
        XCTAssertNil(nested[0].conditional)
    }

    func testEscapeSequencesCanBeEnabledOrPreservedLiterally() throws {
        let source = #""Root" { "Value" "line\nquote\"slash\\tail" }"#

        var decodedParser = SourceKeyValuesParser(
            source: source,
            options: .init(usesEscapeSequences: true, preserveKeyCase: true)
        )
        let decoded = try singleStringValue(from: decodedParser.parse())
        XCTAssertEqual(decoded, "line\nquote\"slash\\tail")

        var literalParser = SourceKeyValuesParser(
            source: source,
            options: .init(usesEscapeSequences: false, preserveKeyCase: true)
        )
        let literal = try singleStringValue(from: literalParser.parse())
        XCTAssertEqual(literal, #"line\nquote\"slash\\tail"#)
    }

    func testLuaConversionUsesLastDuplicateAndHonorsCaseAndOrder() throws {
        let source = try fixtureSource()
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })

        try runtime.execute(
            """
            local source = [=[\(source)]=]
            local folded = util.KeyValuesToTable(source, false, false)
            assert(folded["quoted key"] == "quoted value")
            assert(folded.barekey == "bareValue")
            assert(folded.nested.child == "yes")
            assert(folded.same == "last")

            local preserved = util.KeyValuesToTable(source, false, true)
            assert(preserved["Quoted Key"] == "quoted value")
            assert(preserved["quoted key"] == nil)
            assert(preserved.Same == "last")

            local ordered = util.KeyValuesToTablePreserveOrder(source, false, true)
            assert(#ordered == 6)
            assert(ordered[4].Key == "Same" and ordered[4].Value == "first")
            assert(ordered[5].Key == "Same" and ordered[5].Value == "last")
            assert(ordered[6].Conditional == "$WIN32")
            """,
            sourceName: "=(Source KeyValues XCTest)"
        )
    }

    func testMalformedInputReportsSpecificParserErrors() throws {
        XCTAssertThrowsError(
            try parse(#""Root" { "Key" "unterminated"#)
        ) { error in
            guard case SourceKeyValuesError.unterminatedString = error else {
                return XCTFail("expected unterminatedString, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try parse(#""Root" { "Key" "Value""#)
        ) { error in
            guard case SourceKeyValuesError.missingClosingBrace = error else {
                return XCTFail("expected missingClosingBrace, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try parse(#""Root" { "Key" "Value" [$WIN32"#)
        ) { error in
            guard case SourceKeyValuesError.unterminatedConditional = error else {
                return XCTFail("expected unterminatedConditional, got \(error)")
            }
        }
    }

    private func fixtureSource() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "SourceKeyValuesV1Fixture",
                withExtension: "txt",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "SourceKeyValuesV1Fixture",
                withExtension: "txt"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parse(_ source: String) throws -> [SourceKeyValuesParser.Entry] {
        var parser = SourceKeyValuesParser(source: source)
        return try parser.parse()
    }

    private func singleStringValue(
        from roots: [SourceKeyValuesParser.Entry]
    ) throws -> String {
        let root = try XCTUnwrap(roots.first)
        guard case let .object(entries) = root.value,
              let entry = entries.first,
              case let .string(value) = entry.value else {
            throw SourceKeyValuesTestError.unexpectedShape
        }
        return value
    }
}

private enum SourceKeyValuesTestError: Error {
    case unexpectedShape
}
