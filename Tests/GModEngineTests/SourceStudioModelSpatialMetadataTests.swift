import Foundation
import Testing
@testable import GModEngine

@Suite("Bounded Source Studio model spatial metadata")
struct SourceStudioModelSpatialMetadataTests {
    private let checksum: Int32 = 0x1357_2468

    @Test("public v48 header fields decode into an immutable Source-coordinate snapshot")
    func decodesSpatialMetadata() throws {
        let metadata = try decode(makeMDL())

        #expect(metadata.checksum == checksum)
        #expect(metadata.modelName == Paths.mdl)
        #expect(metadata.eyePosition == SourceVector3(1, 2, 3))
        #expect(metadata.illuminationPosition == SourceVector3(-4, 5, 6))
        #expect(metadata.hullMinimum == SourceVector3(-16, -17, 0))
        #expect(metadata.hullMaximum == SourceVector3(16, 17, 72))
        #expect(metadata.viewBoundingBoxMinimum == SourceVector3(-24, -25, -8))
        #expect(metadata.viewBoundingBoxMaximum == SourceVector3(24, 25, 80))
        #expect(metadata.flags == Int32(bitPattern: 0x8123_4567))
        #expect(metadata.surfaceProperty == "metal_barrel")
    }

    @Test("every published vector component must be finite")
    func rejectsNonFiniteVectors() throws {
        let fields: [(offset: Int, name: String)] = [
            (80, "studiohdr_t.eyeposition.x"),
            (92, "studiohdr_t.illumposition.x"),
            (104, "studiohdr_t.hull_min.x"),
            (116, "studiohdr_t.hull_max.x"),
            (128, "studiohdr_t.view_bbmin.x"),
            (140, "studiohdr_t.view_bbmax.x")
        ]
        for field in fields {
            var bytes = [UInt8](makeMDL())
            putUInt32(Float.nan.bitPattern, at: field.offset, into: &bytes)
            let payload = try loadPayload(mdl: Data(bytes))
            do {
                _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                    payload,
                    budget: decodeBudget()
                )
                Issue.record("expected non-finite rejection for \(field.name)")
            } catch let error as SourceStudioModelSpatialMetadataDecodeError {
                #expect(error == .nonFiniteFloat(field: field.name, offset: field.offset))
            }
        }
    }

    @Test("hull and clipping bounds preserve authored minimum-to-maximum ordering")
    func rejectsReversedBounds() throws {
        var hullBytes = [UInt8](makeMDL())
        putFloat(17, at: 104, into: &hullBytes)
        let hullPayload = try loadPayload(mdl: Data(hullBytes))
        do {
            _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                hullPayload,
                budget: decodeBudget()
            )
            Issue.record("expected reversed hull rejection")
        } catch let error as SourceStudioModelSpatialMetadataDecodeError {
            #expect(error == .invalidBounds(
                field: "studiohdr_t.hull",
                minimum: SourceVector3(17, -17, 0),
                maximum: SourceVector3(16, 17, 72)
            ))
        }

        var viewBytes = [UInt8](makeMDL())
        putFloat(81, at: 136, into: &viewBytes)
        let viewPayload = try loadPayload(mdl: Data(viewBytes))
        do {
            _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                viewPayload,
                budget: decodeBudget()
            )
            Issue.record("expected reversed view bounds rejection")
        } catch let error as SourceStudioModelSpatialMetadataDecodeError {
            #expect(error == .invalidBounds(
                field: "studiohdr_t.view_bb",
                minimum: SourceVector3(-24, -25, 81),
                maximum: SourceVector3(24, 25, 80)
            ))
        }
    }

    @Test("surface property offset must name a byte inside the validated MDL")
    func rejectsInvalidSurfacePropertyOffsets() throws {
        var zeroBytes = [UInt8](makeMDL())
        putInt32(0, at: 308, into: &zeroBytes)
        let zeroPayload = try loadPayload(mdl: Data(zeroBytes))
        do {
            _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                zeroPayload,
                budget: decodeBudget()
            )
            Issue.record("expected zero surface-property offset rejection")
        } catch let error as SourceStudioModelSpatialMetadataDecodeError {
            #expect(error == .invalidOffset(field: "studiohdr_t.surfaceprop", value: 0))
        }

        var outsideBytes = [UInt8](makeMDL())
        putInt32(Int32(outsideBytes.count), at: 308, into: &outsideBytes)
        let outsidePayload = try loadPayload(mdl: Data(outsideBytes))
        do {
            _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                outsidePayload,
                budget: decodeBudget()
            )
            Issue.record("expected out-of-range surface-property offset rejection")
        } catch let error as SourceStudioModelSpatialMetadataDecodeError {
            #expect(error == .outOfBounds(
                field: "studiohdr_t.surfaceprop",
                start: outsideBytes.count,
                byteCount: 1,
                length: outsideBytes.count
            ))
        }
    }

    @Test("surface property requires a NUL within the validated MDL")
    func rejectsUnterminatedSurfaceProperty() throws {
        var bytes = [UInt8](makeMDL())
        let start = bytes.count - 3
        putInt32(Int32(start), at: 308, into: &bytes)
        bytes.replaceSubrange(start..<bytes.count, with: [0x61, 0x62, 0x63])
        let payload = try loadPayload(mdl: Data(bytes))

        do {
            _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                payload,
                budget: decodeBudget()
            )
            Issue.record("expected unterminated surface property rejection")
        } catch let error as SourceStudioModelSpatialMetadataDecodeError {
            #expect(error == .unterminatedString(
                field: "studiohdr_t.surfaceprop",
                start: start
            ))
        }
    }

    @Test("surface property scanning stops at the caller byte cap")
    func enforcesSurfacePropertyBudget() throws {
        let payload = try loadPayload(mdl: makeMDL())
        do {
            _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                payload,
                budget: SourceStudioModelSpatialMetadataDecodeBudget(
                    maximumSurfacePropertyBytes: 4
                )
            )
            Issue.record("expected surface-property cap rejection")
        } catch let error as SourceStudioModelSpatialMetadataDecodeError {
            #expect(error == .stringByteCountExceeded(
                field: "studiohdr_t.surfaceprop",
                value: 5,
                cap: 4
            ))
        }
    }

    @Test("surface property is validated UTF-8 and decode budgets cannot be negative")
    func rejectsInvalidUTF8AndBudget() throws {
        var bytes = [UInt8](makeMDL())
        bytes[Offsets.surfaceProperty] = 0xFF
        bytes[Offsets.surfaceProperty + 1] = 0
        let payload = try loadPayload(mdl: Data(bytes))
        do {
            _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                payload,
                budget: decodeBudget()
            )
            Issue.record("expected invalid UTF-8 rejection")
        } catch let error as SourceStudioModelSpatialMetadataDecodeError {
            #expect(error == .stringIsNotUTF8(
                field: "studiohdr_t.surfaceprop",
                start: Offsets.surfaceProperty
            ))
        }

        do {
            _ = try SourceStudioModelSpatialMetadataDecoder.decode(
                payload,
                budget: SourceStudioModelSpatialMetadataDecodeBudget(
                    maximumSurfacePropertyBytes: -1
                )
            )
            Issue.record("expected invalid budget rejection")
        } catch let error as SourceStudioModelSpatialMetadataDecodeError {
            #expect(error == .invalidBudget(
                field: "maximumSurfacePropertyBytes",
                value: -1
            ))
        }
    }
}

private extension SourceStudioModelSpatialMetadataTests {
    enum Paths {
        static let mdl = "models/props/spatial_metadata_test.mdl"
        static let vvd = "models/props/spatial_metadata_test.vvd"
        static let vtx = "models/props/spatial_metadata_test.dx90.vtx"
    }

    enum Offsets {
        static let surfaceProperty = 432
    }

    func decodeBudget() -> SourceStudioModelSpatialMetadataDecodeBudget {
        SourceStudioModelSpatialMetadataDecodeBudget(maximumSurfacePropertyBytes: 64)
    }

    func decode(_ mdl: Data) throws -> SourceStudioModelSpatialMetadataSnapshot {
        try SourceStudioModelSpatialMetadataDecoder.decode(
            loadPayload(mdl: mdl),
            budget: decodeBudget()
        )
    }

    func loadPayload(mdl: Data) throws -> SourceStudioImmutableRenderPayload {
        let loader = SourceStudioModelAssetLoader(
            reader: SpatialMetadataMemoryAssetReader(files: [
                Paths.mdl: mdl,
                Paths.vvd: makeVVD(),
                Paths.vtx: makeVTX()
            ]),
            budget: SourceStudioModelAssetBudget(
                maximumBytesByKind: [.mdl: 1_024, .vvd: 128, .vtx: 128],
                maximumTotalBytes: 1_280,
                maximumVVDVertices: 1,
                maximumVVDFixups: 0,
                maximumVTXBodyParts: 0
            )
        )
        let outcome = loader.load(
            paths: SourceStudioModelAssetPaths(
                mdl: Paths.mdl,
                vvd: Paths.vvd,
                vtx: Paths.vtx
            ),
            requirement: .render
        )
        return try #require(outcome.asset).renderPayload
    }

    func makeMDL() -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)
        putUInt32(SourceStudioModel.magic, at: 0, into: &bytes)
        putInt32(48, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putCString(Paths.mdl, at: 12, capacity: 64, into: &bytes)
        putInt32(Int32(bytes.count), at: 76, into: &bytes)
        putVector(SourceVector3(1, 2, 3), at: 80, into: &bytes)
        putVector(SourceVector3(-4, 5, 6), at: 92, into: &bytes)
        putVector(SourceVector3(-16, -17, 0), at: 104, into: &bytes)
        putVector(SourceVector3(16, 17, 72), at: 116, into: &bytes)
        putVector(SourceVector3(-24, -25, -8), at: 128, into: &bytes)
        putVector(SourceVector3(24, 25, 80), at: 140, into: &bytes)
        putInt32(Int32(bitPattern: 0x8123_4567), at: 152, into: &bytes)
        putInt32(Int32(Offsets.surfaceProperty), at: 308, into: &bytes)
        putCString("metal_barrel", at: Offsets.surfaceProperty, capacity: 13, into: &bytes)
        return Data(bytes)
    }

    func makeVVD() -> Data {
        var bytes = [UInt8](repeating: 0, count: 64)
        putUInt32(0x5653_4449, at: 0, into: &bytes)
        putInt32(4, at: 4, into: &bytes)
        putInt32(checksum, at: 8, into: &bytes)
        putInt32(1, at: 12, into: &bytes)
        return Data(bytes)
    }

    func makeVTX() -> Data {
        var bytes = [UInt8](repeating: 0, count: 44)
        putInt32(7, at: 0, into: &bytes)
        putInt32(32, at: 4, into: &bytes)
        putUInt16(3, at: 8, into: &bytes)
        putUInt16(3, at: 10, into: &bytes)
        putInt32(3, at: 12, into: &bytes)
        putInt32(checksum, at: 16, into: &bytes)
        putInt32(1, at: 20, into: &bytes)
        putInt32(36, at: 24, into: &bytes)
        return Data(bytes)
    }
}

private struct SpatialMetadataMemoryAssetReader: SourceStudioBoundedAssetReading {
    let files: [String: Data]

    func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        guard let data = files[path.lowercased()] else { return .missing }
        guard data.count <= maximumBytes else { return .exceeded(actual: data.count) }
        return .data(data)
    }
}

private func putCString(
    _ value: String,
    at offset: Int,
    capacity: Int,
    into bytes: inout [UInt8]
) {
    let encoded = Array(value.utf8.prefix(capacity - 1))
    bytes.replaceSubrange(offset..<(offset + encoded.count), with: encoded)
    bytes[offset + encoded.count] = 0
}

private func putVector(_ value: SourceVector3, at offset: Int, into bytes: inout [UInt8]) {
    putFloat(value.x, at: offset, into: &bytes)
    putFloat(value.y, at: offset + 4, into: &bytes)
    putFloat(value.z, at: offset + 8, into: &bytes)
}

private func putFloat(_ value: Float, at offset: Int, into bytes: inout [UInt8]) {
    putUInt32(value.bitPattern, at: offset, into: &bytes)
}

private func putUInt16(_ value: UInt16, at offset: Int, into bytes: inout [UInt8]) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func putInt32(_ value: Int32, at offset: Int, into bytes: inout [UInt8]) {
    putUInt32(UInt32(bitPattern: value), at: offset, into: &bytes)
}

private func putUInt32(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}
