import Foundation

// Format evidence (definitions only; this is an independent bounded decoder):
// - Source SDK 2013, fixed at c8f4c6351162fbff83bfa5a428d45d1e6eed3824,
//   `src/common/studiobyteswap.cpp` defines the modern VPHY header and compact
//   surface fields used here.
// - VPhysics-Jolt, inspected at 4c9016b0426ec5272e7b7b5e16ec7977bae22a9d,
//   corroborates the compact ledge/tree record layout. It is a format reference
//   only; no implementation code is copied.
//
// This decoder deliberately retains raw IVP coordinates and serialized values.
// It does not select a surface property, convert axes or units, or claim final
// mass/inertia values. A real owned fixture plus an independent VPhysics oracle
// is required before any decoded result can become attested or feed
// `util.IsValidProp`.

public struct SourceVPhysicsCollisionDecodeBudget: Sendable, Equatable {
    public let maximumSourceDataBytes: Int
    public let maximumPayloadBytes: Int
    public let maximumTreeNodes: Int
    public let maximumTreeDepth: Int
    public let maximumLedges: Int
    public let maximumTriangles: Int
    public let maximumPoints: Int

    public init(
        maximumSourceDataBytes: Int,
        maximumPayloadBytes: Int,
        maximumTreeNodes: Int,
        maximumTreeDepth: Int,
        maximumLedges: Int,
        maximumTriangles: Int,
        maximumPoints: Int
    ) {
        self.maximumSourceDataBytes = maximumSourceDataBytes
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumTreeNodes = maximumTreeNodes
        self.maximumTreeDepth = maximumTreeDepth
        self.maximumLedges = maximumLedges
        self.maximumTriangles = maximumTriangles
        self.maximumPoints = maximumPoints
    }
}

public enum SourceVPhysicsCollisionVerification: Sendable, Equatable {
    /// Structurally decoded, but not compared with an owned real PHY fixture
    /// and an independent VPhysics result.
    case unattested
}

public enum SourceVPhysicsCollisionUnsupportedByteOrder: Sendable, Equatable {
    case bigEndian
}

public enum SourceVPhysicsCollisionUnavailableReason: Error, Sendable, Equatable {
    case unsupportedByteOrder(SourceVPhysicsCollisionUnsupportedByteOrder)
    case unsupportedSerializationIdentifier(UInt32)
    case unsupportedVersion(UInt16)
    case unsupportedModelType(Int16)
    case unsupportedAxisMap(byteCount: Int)
}

public struct SourceVPhysicsCollisionByteRange: Sendable, Equatable {
    public let offset: Int
    public let byteCount: Int

    public var endOffset: Int { offset + byteCount }

    fileprivate init(offset: Int, byteCount: Int) {
        self.offset = offset
        self.byteCount = byteCount
    }
}

public enum SourceVPhysicsCollisionInvalidReason: Error, Sendable, Equatable {
    case invalidBudget(field: String, value: Int)
    case sourceDataExceedsBudget(actual: Int, cap: Int)
    case missingSolidZero
    case duplicateSolidZero(count: Int)
    case invalidSerializedByteCount(actual: Int)
    case payloadExceedsBudget(actual: Int, cap: Int)
    case solidFrameDoesNotMatchSourceData
    case rangeOutOfBounds(
        field: String,
        offset: Int,
        byteCount: Int,
        allowed: SourceVPhysicsCollisionByteRange
    )
    case integerOverflow(field: String)
    case surfaceByteCountNotPositive(Int32)
    case surfaceByteCountMismatch(declared: Int, actual: Int)
    case negativeAxisMapByteCount(Int32)
    case compactSurfaceByteCountNotPositive(Int)
    case compactSurfaceByteCountMismatch(surface: Int, compact: Int)
    case nonFinite(field: String)
    case negativeValue(field: String)
    case zeroRelativeOffset(field: String)
    case misaligned(field: String, offset: Int, alignment: Int)
    case treeDepthExceeded(actual: Int, cap: Int)
    case treeNodeCountExceeded(actual: Int, cap: Int)
    case nodeCycleOrAlias(offset: Int)
    case ledgeCountExceeded(actual: Int, cap: Int)
    case ledgeAlias(offset: Int)
    case invalidTriangleCount(ledgeOffset: Int, actual: Int16)
    case triangleCountExceeded(actual: Int, cap: Int)
    case pointCountExceeded(actual: Int, cap: Int)
    case invalidDeclaredLedgeByteCount(ledgeOffset: Int, declared: Int, required: Int)
    case overlappingRanges(firstField: String, secondField: String)
    case degenerateTriangle(ledgeOffset: Int, triangle: Int)
    case degenerateLedge(ledgeOffset: Int)
    case internalDecoderFailure
}

public enum SourceVPhysicsCollisionDecodeOutcome: Sendable, Equatable {
    case decoded(SourceVPhysicsCollisionSnapshot)
    case unavailable(SourceVPhysicsCollisionUnavailableReason)
    case invalid(SourceVPhysicsCollisionInvalidReason)
}

/// A vector exactly as serialized by IVP. No Source/Jolt axis or unit
/// conversion has been applied.
public struct SourceVPhysicsRawIVPVector3: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float

    fileprivate init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct SourceVPhysicsCollideHeaderSnapshot: Sendable, Equatable {
    public let byteRange: SourceVPhysicsCollisionByteRange
    public let serializationIdentifier: UInt32
    public let version: UInt16
    public let modelType: Int16
}

public struct SourceVPhysicsSurfaceHeaderSnapshot: Sendable, Equatable {
    public let byteRange: SourceVPhysicsCollisionByteRange
    public let surfaceByteCount: Int
    public let rawDragAxisAreas: SourceVPhysicsRawIVPVector3
    public let axisMapByteCount: Int
}

public struct SourceVPhysicsCompactSurfaceSnapshot: Sendable, Equatable {
    public let byteRange: SourceVPhysicsCollisionByteRange
    public let rawMassCenter: SourceVPhysicsRawIVPVector3
    public let rawRotationInertia: SourceVPhysicsRawIVPVector3
    public let rawUpperLimitRadius: Float
    public let rawMaximumDeviation: UInt8
    public let declaredByteCount: Int
    public let ledgeTreeRootRelativeOffset: Int32
    public let reservedWords: [Int32]
}

public struct SourceVPhysicsLedgeTreeNodeSnapshot: Sendable, Equatable {
    public let byteRange: SourceVPhysicsCollisionByteRange
    public let depth: Int
    public let rightNodeRelativeOffset: Int32
    public let compactLedgeRelativeOffset: Int32
    public let rawCenter: SourceVPhysicsRawIVPVector3
    public let rawRadius: Float
    public let rawBoxSizes: [UInt8]
    public let rawReservedByte: UInt8
    public let isTerminal: Bool
    public let leftChildOffset: Int?
    public let rightChildOffset: Int?
    public let compactLedgeOffset: Int?
}

public struct SourceVPhysicsCompactEdgeSnapshot: Sendable, Equatable {
    public let rawWord: UInt32
    public let startPointIndex: UInt16
    public let oppositeIndex: Int16
    public let isVirtual: Bool
}

public struct SourceVPhysicsCompactTriangleSnapshot: Sendable, Equatable {
    public let byteRange: SourceVPhysicsCollisionByteRange
    public let rawWord: UInt32
    public let triangleIndex: UInt16
    public let pierceIndex: UInt16
    public let materialIndex: UInt8
    public let isVirtual: Bool
    public let edges: [SourceVPhysicsCompactEdgeSnapshot]
}

public struct SourceVPhysicsRawIVPPointSnapshot: Sendable, Equatable {
    public let byteRange: SourceVPhysicsCollisionByteRange
    public let position: SourceVPhysicsRawIVPVector3
    /// The fourth 32-bit lane is retained without assigning it a coordinate
    /// meaning that the pinned evidence does not establish.
    public let fourthLaneBitPattern: UInt32
}

public struct SourceVPhysicsCompactLedgeSnapshot: Sendable, Equatable {
    public let headerByteRange: SourceVPhysicsCollisionByteRange
    public let triangleTableByteRange: SourceVPhysicsCollisionByteRange
    public let pointTableByteRange: SourceVPhysicsCollisionByteRange
    public let declaredByteRange: SourceVPhysicsCollisionByteRange
    public let pointTableRelativeOffset: Int32
    public let clientDataOrTreeOffset: Int32
    public let rawFlags: UInt32
    public let hasChildrenFlag: UInt8
    public let isCompactFlag: UInt8
    public let reservedFlagBits: UInt8
    public let declaredByteCount: Int
    public let reservedWord: Int16
    public let triangles: [SourceVPhysicsCompactTriangleSnapshot]
    public let points: [SourceVPhysicsRawIVPPointSnapshot]
}

/// Immutable structural view of solid 0's modern COLLIDE_POLY bytes.
///
/// `sourceData` is the original complete PHY Data supplied by the caller. All
/// ranges in this snapshot are absolute ranges into that value; geometry bytes
/// are not copied into a second authoritative buffer.
public struct SourceVPhysicsCollisionSnapshot: Sendable, Equatable {
    public let sourceData: Data
    public let solidIndex: Int
    public let payloadByteRange: SourceVPhysicsCollisionByteRange
    public let collideHeader: SourceVPhysicsCollideHeaderSnapshot
    public let surfaceHeader: SourceVPhysicsSurfaceHeaderSnapshot
    public let compactSurface: SourceVPhysicsCompactSurfaceSnapshot
    public let treeNodes: [SourceVPhysicsLedgeTreeNodeSnapshot]
    public let ledges: [SourceVPhysicsCompactLedgeSnapshot]
    public let verification: SourceVPhysicsCollisionVerification
}

public enum SourceVPhysicsCollisionDecoder {
    private static let collideHeaderByteCount = 8
    private static let surfaceHeaderByteCount = 20
    private static let serializedHeaderByteCount = 28
    private static let compactSurfaceByteCount = 48
    private static let ledgeTreeNodeByteCount = 28
    private static let compactLedgeHeaderByteCount = 16
    private static let compactTriangleByteCount = 16
    private static let rawPointByteCount = 16
    private static let naturalRecordAlignment = 4

    private static let vphysicsIdentifier: UInt32 = 0x5948_5056 // "VPHY" in LE bytes.
    private static let byteSwappedVPhysicsIdentifier: UInt32 = 0x5650_4859 // "YHPV".
    private static let supportedVersion: UInt16 = 0x0100
    private static let collidePolyModelType: Int16 = 0

    /// Decodes only modern little-endian VPHY version 0x0100, COLLIDE_POLY,
    /// solid 0. Unsupported formats remain distinguishable from malformed data.
    public static func decodeSolidZero(
        in sourceData: Data,
        envelope: SourcePHYCollisionEnvelopeSnapshot,
        budget: SourceVPhysicsCollisionDecodeBudget
    ) -> SourceVPhysicsCollisionDecodeOutcome {
        if let invalidBudget = validate(budget: budget) {
            return .invalid(invalidBudget)
        }
        guard sourceData.count <= budget.maximumSourceDataBytes else {
            return .invalid(.sourceDataExceedsBudget(
                actual: sourceData.count,
                cap: budget.maximumSourceDataBytes
            ))
        }

        let solidZeroFrames = envelope.serializedSolids.filter { $0.index == 0 }
        guard !solidZeroFrames.isEmpty else {
            return .invalid(.missingSolidZero)
        }
        guard solidZeroFrames.count == 1 else {
            return .invalid(.duplicateSolidZero(count: solidZeroFrames.count))
        }
        let solid = solidZeroFrames[0]
        guard solid.serializedByteCount > 0 else {
            return .invalid(.invalidSerializedByteCount(actual: solid.serializedByteCount))
        }
        guard solid.serializedByteCount <= budget.maximumPayloadBytes else {
            return .invalid(.payloadExceedsBudget(
                actual: solid.serializedByteCount,
                cap: budget.maximumPayloadBytes
            ))
        }

        let wholeSourceRange = SourceVPhysicsCollisionByteRange(
            offset: 0,
            byteCount: sourceData.count
        )
        let payloadEnd: Int
        do {
            payloadEnd = try checkedEnd(
                start: solid.payloadOffset,
                byteCount: solid.serializedByteCount,
                field: "solid[0].payload"
            )
        } catch let reason as SourceVPhysicsCollisionInvalidReason {
            return .invalid(reason)
        } catch {
            return .invalid(.internalDecoderFailure)
        }
        guard solid.payloadOffset >= 0, payloadEnd <= sourceData.count else {
            return .invalid(.rangeOutOfBounds(
                field: "solid[0].payload",
                offset: solid.payloadOffset,
                byteCount: solid.serializedByteCount,
                allowed: wholeSourceRange
            ))
        }
        let payloadRange = SourceVPhysicsCollisionByteRange(
            offset: solid.payloadOffset,
            byteCount: solid.serializedByteCount
        )
        guard sourceData[solid.payloadOffset..<payloadEnd]
            .elementsEqual(solid.serializedPayload)
        else {
            return .invalid(.solidFrameDoesNotMatchSourceData)
        }

        do {
            let reader = SourceVPhysicsCollisionReader(
                data: sourceData,
                allowedRange: payloadRange
            )
            let collideHeaderRange = try reader.range(
                at: payloadRange.offset,
                byteCount: collideHeaderByteCount,
                field: "collideheader_t"
            )
            let identifier = try reader.uint32(
                at: collideHeaderRange.offset,
                field: "collideheader_t.vphysicsID"
            )
            if identifier == byteSwappedVPhysicsIdentifier {
                return .unavailable(.unsupportedByteOrder(.bigEndian))
            }
            guard identifier == vphysicsIdentifier else {
                return .unavailable(.unsupportedSerializationIdentifier(identifier))
            }
            let version = try reader.uint16(
                at: collideHeaderRange.offset + 4,
                field: "collideheader_t.version"
            )
            guard version == supportedVersion else {
                return .unavailable(.unsupportedVersion(version))
            }
            let modelType = try reader.int16(
                at: collideHeaderRange.offset + 6,
                field: "collideheader_t.modelType"
            )
            guard modelType == collidePolyModelType else {
                return .unavailable(.unsupportedModelType(modelType))
            }

            let surfaceHeaderOffset = try checkedEnd(
                start: payloadRange.offset,
                byteCount: collideHeaderByteCount,
                field: "compactsurfaceheader_t offset"
            )
            let surfaceHeaderRange = try reader.range(
                at: surfaceHeaderOffset,
                byteCount: surfaceHeaderByteCount,
                field: "compactsurfaceheader_t"
            )
            let surfaceByteCountRaw = try reader.int32(
                at: surfaceHeaderOffset,
                field: "compactsurfaceheader_t.surfaceSize"
            )
            guard surfaceByteCountRaw > 0 else {
                throw SourceVPhysicsCollisionInvalidReason
                    .surfaceByteCountNotPositive(surfaceByteCountRaw)
            }
            let surfaceByteCount = Int(surfaceByteCountRaw)
            let actualSurfaceByteCount = payloadRange.byteCount - serializedHeaderByteCount
            guard surfaceByteCount == actualSurfaceByteCount else {
                throw SourceVPhysicsCollisionInvalidReason.surfaceByteCountMismatch(
                    declared: surfaceByteCount,
                    actual: actualSurfaceByteCount
                )
            }
            let dragAxisAreas = try reader.vector3(
                at: surfaceHeaderOffset + 4,
                field: "compactsurfaceheader_t.dragAxisAreas"
            )
            try requireFinite(
                dragAxisAreas,
                field: "compactsurfaceheader_t.dragAxisAreas"
            )
            let axisMapByteCountRaw = try reader.int32(
                at: surfaceHeaderOffset + 16,
                field: "compactsurfaceheader_t.axisMapSize"
            )
            guard axisMapByteCountRaw >= 0 else {
                throw SourceVPhysicsCollisionInvalidReason
                    .negativeAxisMapByteCount(axisMapByteCountRaw)
            }
            guard axisMapByteCountRaw == 0 else {
                return .unavailable(.unsupportedAxisMap(
                    byteCount: Int(axisMapByteCountRaw)
                ))
            }

            let compactSurfaceOffset = try checkedEnd(
                start: payloadRange.offset,
                byteCount: serializedHeaderByteCount,
                field: "compactsurface_t offset"
            )
            let compactSurfaceRange = try reader.range(
                at: compactSurfaceOffset,
                byteCount: compactSurfaceByteCount,
                field: "compactsurface_t"
            )
            let rawMassCenter = try reader.vector3(
                at: compactSurfaceOffset,
                field: "compactsurface_t.mass_center"
            )
            try requireFinite(rawMassCenter, field: "compactsurface_t.mass_center")
            let rawRotationInertia = try reader.vector3(
                at: compactSurfaceOffset + 12,
                field: "compactsurface_t.rotation_inertia"
            )
            try requireFinite(
                rawRotationInertia,
                field: "compactsurface_t.rotation_inertia"
            )
            let rawUpperLimitRadius = try reader.float32(
                at: compactSurfaceOffset + 24,
                field: "compactsurface_t.upper_limit_radius"
            )
            guard rawUpperLimitRadius.isFinite else {
                throw SourceVPhysicsCollisionInvalidReason.nonFinite(
                    field: "compactsurface_t.upper_limit_radius"
                )
            }
            guard rawUpperLimitRadius >= 0 else {
                throw SourceVPhysicsCollisionInvalidReason.negativeValue(
                    field: "compactsurface_t.upper_limit_radius"
                )
            }
            let packedSurfaceWord = try reader.uint32(
                at: compactSurfaceOffset + 28,
                field: "compactsurface_t.bitfields"
            )
            let rawMaximumDeviation = UInt8(packedSurfaceWord & 0xFF)
            let compactDeclaredByteCount = Int(packedSurfaceWord >> 8)
            guard compactDeclaredByteCount > 0 else {
                throw SourceVPhysicsCollisionInvalidReason
                    .compactSurfaceByteCountNotPositive(compactDeclaredByteCount)
            }
            guard compactDeclaredByteCount == surfaceByteCount else {
                throw SourceVPhysicsCollisionInvalidReason
                    .compactSurfaceByteCountMismatch(
                        surface: surfaceByteCount,
                        compact: compactDeclaredByteCount
                    )
            }
            let rootRelativeOffset = try reader.int32(
                at: compactSurfaceOffset + 32,
                field: "compactsurface_t.offset_ledgetree_root"
            )
            let reservedWords = try (0..<3).map { index in
                try reader.int32(
                    at: compactSurfaceOffset + 36 + (index * 4),
                    field: "compactsurface_t.dummy[\(index)]"
                )
            }

            var occupied = SourceVPhysicsOccupiedRanges()
            try occupied.register(collideHeaderRange, field: "collideheader_t")
            try occupied.register(surfaceHeaderRange, field: "compactsurfaceheader_t")
            try occupied.register(compactSurfaceRange, field: "compactsurface_t")

            let rootOffset = try checkedRelativeOffset(
                base: compactSurfaceOffset,
                relative: rootRelativeOffset,
                field: "compactsurface_t.offset_ledgetree_root"
            )
            try requireAlignment(
                rootOffset,
                alignment: naturalRecordAlignment,
                field: "ledge tree root"
            )

            let treeResult = try decodeLedgeTree(
                reader: reader,
                rootOffset: rootOffset,
                budget: budget,
                occupied: &occupied
            )
            let ledges = try decodeLedges(
                reader: reader,
                offsets: treeResult.ledgeOffsets,
                budget: budget,
                occupied: &occupied
            )

            return .decoded(SourceVPhysicsCollisionSnapshot(
                sourceData: sourceData,
                solidIndex: 0,
                payloadByteRange: payloadRange,
                collideHeader: SourceVPhysicsCollideHeaderSnapshot(
                    byteRange: collideHeaderRange,
                    serializationIdentifier: identifier,
                    version: version,
                    modelType: modelType
                ),
                surfaceHeader: SourceVPhysicsSurfaceHeaderSnapshot(
                    byteRange: surfaceHeaderRange,
                    surfaceByteCount: surfaceByteCount,
                    rawDragAxisAreas: dragAxisAreas,
                    axisMapByteCount: 0
                ),
                compactSurface: SourceVPhysicsCompactSurfaceSnapshot(
                    byteRange: compactSurfaceRange,
                    rawMassCenter: rawMassCenter,
                    rawRotationInertia: rawRotationInertia,
                    rawUpperLimitRadius: rawUpperLimitRadius,
                    rawMaximumDeviation: rawMaximumDeviation,
                    declaredByteCount: compactDeclaredByteCount,
                    ledgeTreeRootRelativeOffset: rootRelativeOffset,
                    reservedWords: reservedWords
                ),
                treeNodes: treeResult.nodes,
                ledges: ledges,
                verification: .unattested
            ))
        } catch let reason as SourceVPhysicsCollisionInvalidReason {
            return .invalid(reason)
        } catch {
            return .invalid(.internalDecoderFailure)
        }
    }

    private static func validate(
        budget: SourceVPhysicsCollisionDecodeBudget
    ) -> SourceVPhysicsCollisionInvalidReason? {
        let positiveFields = [
            ("maximumSourceDataBytes", budget.maximumSourceDataBytes),
            ("maximumPayloadBytes", budget.maximumPayloadBytes),
            ("maximumTreeNodes", budget.maximumTreeNodes),
            ("maximumLedges", budget.maximumLedges),
            ("maximumTriangles", budget.maximumTriangles),
            ("maximumPoints", budget.maximumPoints)
        ]
        if let invalid = positiveFields.first(where: { $0.1 <= 0 }) {
            return .invalidBudget(field: invalid.0, value: invalid.1)
        }
        guard budget.maximumTreeDepth >= 0 else {
            return .invalidBudget(
                field: "maximumTreeDepth",
                value: budget.maximumTreeDepth
            )
        }
        return nil
    }

    private struct TreeResult {
        let nodes: [SourceVPhysicsLedgeTreeNodeSnapshot]
        let ledgeOffsets: [Int]
    }

    private struct TreeWorkItem {
        let offset: Int
        let depth: Int
    }

    private static func decodeLedgeTree(
        reader: SourceVPhysicsCollisionReader,
        rootOffset: Int,
        budget: SourceVPhysicsCollisionDecodeBudget,
        occupied: inout SourceVPhysicsOccupiedRanges
    ) throws -> TreeResult {
        var stack = [TreeWorkItem(offset: rootOffset, depth: 0)]
        var visitedNodeOffsets: Set<Int> = []
        var visitedLedgeOffsets: Set<Int> = []
        var nodes: [SourceVPhysicsLedgeTreeNodeSnapshot] = []
        var ledgeOffsets: [Int] = []
        nodes.reserveCapacity(min(budget.maximumTreeNodes, 64))
        ledgeOffsets.reserveCapacity(min(budget.maximumLedges, 16))

        while let work = stack.popLast() {
            guard work.depth <= budget.maximumTreeDepth else {
                throw SourceVPhysicsCollisionInvalidReason.treeDepthExceeded(
                    actual: work.depth,
                    cap: budget.maximumTreeDepth
                )
            }
            guard visitedNodeOffsets.insert(work.offset).inserted else {
                throw SourceVPhysicsCollisionInvalidReason.nodeCycleOrAlias(
                    offset: work.offset
                )
            }
            guard nodes.count < budget.maximumTreeNodes else {
                throw SourceVPhysicsCollisionInvalidReason.treeNodeCountExceeded(
                    actual: nodes.count + 1,
                    cap: budget.maximumTreeNodes
                )
            }
            try requireAlignment(
                work.offset,
                alignment: naturalRecordAlignment,
                field: "compactledgenode_t"
            )
            let nodeRange = try reader.range(
                at: work.offset,
                byteCount: ledgeTreeNodeByteCount,
                field: "compactledgenode_t"
            )
            try occupied.register(
                nodeRange,
                field: "compactledgenode_t@\(work.offset)"
            )

            let rightRelativeOffset = try reader.int32(
                at: work.offset,
                field: "compactledgenode_t.offset_right_node"
            )
            let ledgeRelativeOffset = try reader.int32(
                at: work.offset + 4,
                field: "compactledgenode_t.offset_compact_ledge"
            )
            let rawCenter = try reader.vector3(
                at: work.offset + 8,
                field: "compactledgenode_t.center"
            )
            try requireFinite(rawCenter, field: "compactledgenode_t.center")
            let rawRadius = try reader.float32(
                at: work.offset + 20,
                field: "compactledgenode_t.radius"
            )
            guard rawRadius.isFinite else {
                throw SourceVPhysicsCollisionInvalidReason.nonFinite(
                    field: "compactledgenode_t.radius"
                )
            }
            guard rawRadius >= 0 else {
                throw SourceVPhysicsCollisionInvalidReason.negativeValue(
                    field: "compactledgenode_t.radius"
                )
            }
            let rawBoxSizes = try (0..<3).map { index in
                try reader.uint8(
                    at: work.offset + 24 + index,
                    field: "compactledgenode_t.box_sizes[\(index)]"
                )
            }
            let reservedByte = try reader.uint8(
                at: work.offset + 27,
                field: "compactledgenode_t.free_0"
            )

            let isTerminal = rightRelativeOffset == 0
            var leftChildOffset: Int?
            var rightChildOffset: Int?
            var compactLedgeOffset: Int?
            if isTerminal {
                guard ledgeRelativeOffset != 0 else {
                    throw SourceVPhysicsCollisionInvalidReason.zeroRelativeOffset(
                        field: "terminal compactledgenode_t.offset_compact_ledge"
                    )
                }
                let ledgeOffset = try checkedRelativeOffset(
                    base: work.offset,
                    relative: ledgeRelativeOffset,
                    field: "compactledgenode_t.offset_compact_ledge"
                )
                try requireAlignment(
                    ledgeOffset,
                    alignment: naturalRecordAlignment,
                    field: "compactledge_t"
                )
                _ = try reader.range(
                    at: ledgeOffset,
                    byteCount: compactLedgeHeaderByteCount,
                    field: "compactledge_t"
                )
                guard visitedLedgeOffsets.insert(ledgeOffset).inserted else {
                    throw SourceVPhysicsCollisionInvalidReason.ledgeAlias(
                        offset: ledgeOffset
                    )
                }
                guard ledgeOffsets.count < budget.maximumLedges else {
                    throw SourceVPhysicsCollisionInvalidReason.ledgeCountExceeded(
                        actual: ledgeOffsets.count + 1,
                        cap: budget.maximumLedges
                    )
                }
                compactLedgeOffset = ledgeOffset
                ledgeOffsets.append(ledgeOffset)
            } else {
                let leftOffset = try checkedEnd(
                    start: work.offset,
                    byteCount: ledgeTreeNodeByteCount,
                    field: "compactledgenode_t left child"
                )
                let rightOffset = try checkedRelativeOffset(
                    base: work.offset,
                    relative: rightRelativeOffset,
                    field: "compactledgenode_t.offset_right_node"
                )
                try requireAlignment(
                    leftOffset,
                    alignment: naturalRecordAlignment,
                    field: "compactledgenode_t left child"
                )
                try requireAlignment(
                    rightOffset,
                    alignment: naturalRecordAlignment,
                    field: "compactledgenode_t right child"
                )
                _ = try reader.range(
                    at: leftOffset,
                    byteCount: ledgeTreeNodeByteCount,
                    field: "compactledgenode_t left child"
                )
                _ = try reader.range(
                    at: rightOffset,
                    byteCount: ledgeTreeNodeByteCount,
                    field: "compactledgenode_t right child"
                )
                leftChildOffset = leftOffset
                rightChildOffset = rightOffset
                if ledgeRelativeOffset != 0 {
                    let hullOffset = try checkedRelativeOffset(
                        base: work.offset,
                        relative: ledgeRelativeOffset,
                        field: "internal compactledgenode_t.offset_compact_ledge"
                    )
                    try requireAlignment(
                        hullOffset,
                        alignment: naturalRecordAlignment,
                        field: "internal compactledge_t"
                    )
                    _ = try reader.range(
                        at: hullOffset,
                        byteCount: compactLedgeHeaderByteCount,
                        field: "internal compactledge_t"
                    )
                    compactLedgeOffset = hullOffset
                }
                let nextDepth = try checkedEnd(
                    start: work.depth,
                    byteCount: 1,
                    field: "compactledgenode_t child depth"
                )
                // Push right first so the iterative DFS emits the same stable
                // left-before-right order as the serialized tree definition.
                stack.append(TreeWorkItem(offset: rightOffset, depth: nextDepth))
                stack.append(TreeWorkItem(offset: leftOffset, depth: nextDepth))
            }

            nodes.append(SourceVPhysicsLedgeTreeNodeSnapshot(
                byteRange: nodeRange,
                depth: work.depth,
                rightNodeRelativeOffset: rightRelativeOffset,
                compactLedgeRelativeOffset: ledgeRelativeOffset,
                rawCenter: rawCenter,
                rawRadius: rawRadius,
                rawBoxSizes: rawBoxSizes,
                rawReservedByte: reservedByte,
                isTerminal: isTerminal,
                leftChildOffset: leftChildOffset,
                rightChildOffset: rightChildOffset,
                compactLedgeOffset: compactLedgeOffset
            ))
        }

        guard !ledgeOffsets.isEmpty else {
            throw SourceVPhysicsCollisionInvalidReason.ledgeCountExceeded(
                actual: 0,
                cap: budget.maximumLedges
            )
        }
        return TreeResult(nodes: nodes, ledgeOffsets: ledgeOffsets)
    }

    private static func decodeLedges(
        reader: SourceVPhysicsCollisionReader,
        offsets: [Int],
        budget: SourceVPhysicsCollisionDecodeBudget,
        occupied: inout SourceVPhysicsOccupiedRanges
    ) throws -> [SourceVPhysicsCompactLedgeSnapshot] {
        var snapshots: [SourceVPhysicsCompactLedgeSnapshot] = []
        snapshots.reserveCapacity(offsets.count)
        var totalTriangles = 0
        var totalPoints = 0

        for ledgeOffset in offsets {
            let headerRange = try reader.range(
                at: ledgeOffset,
                byteCount: compactLedgeHeaderByteCount,
                field: "compactledge_t"
            )
            try occupied.register(
                headerRange,
                field: "compactledge_t@\(ledgeOffset)"
            )
            let pointRelativeOffset = try reader.int32(
                at: ledgeOffset,
                field: "compactledge_t.c_point_offset"
            )
            let clientDataOrTreeOffset = try reader.int32(
                at: ledgeOffset + 4,
                field: "compactledge_t.client_data"
            )
            let rawFlags = try reader.uint32(
                at: ledgeOffset + 8,
                field: "compactledge_t.flags"
            )
            let hasChildrenFlag = UInt8(rawFlags & 0x3)
            let isCompactFlag = UInt8((rawFlags >> 2) & 0x3)
            let reservedFlagBits = UInt8((rawFlags >> 4) & 0xF)
            let declaredUnits = Int(rawFlags >> 8)
            let declaredByteCount = try checkedProduct(
                declaredUnits,
                16,
                field: "compactledge_t.size_div_16"
            )
            let triangleCountRaw = try reader.int16(
                at: ledgeOffset + 12,
                field: "compactledge_t.n_triangles"
            )
            guard triangleCountRaw > 0 else {
                throw SourceVPhysicsCollisionInvalidReason.invalidTriangleCount(
                    ledgeOffset: ledgeOffset,
                    actual: triangleCountRaw
                )
            }
            let triangleCount = Int(triangleCountRaw)
            let (nextTriangleTotal, triangleTotalOverflow) = totalTriangles
                .addingReportingOverflow(triangleCount)
            guard !triangleTotalOverflow,
                  nextTriangleTotal <= budget.maximumTriangles
            else {
                throw SourceVPhysicsCollisionInvalidReason.triangleCountExceeded(
                    actual: triangleTotalOverflow ? Int.max : nextTriangleTotal,
                    cap: budget.maximumTriangles
                )
            }
            let reservedWord = try reader.int16(
                at: ledgeOffset + 14,
                field: "compactledge_t.for_future_use"
            )
            let triangleBytes = try checkedProduct(
                triangleCount,
                compactTriangleByteCount,
                field: "compactledge_t triangle table"
            )
            let triangleTableOffset = try checkedEnd(
                start: ledgeOffset,
                byteCount: compactLedgeHeaderByteCount,
                field: "compactledge_t triangle table offset"
            )
            let triangleTableRange = try reader.range(
                at: triangleTableOffset,
                byteCount: triangleBytes,
                field: "compactledge_t triangle table"
            )
            try occupied.register(
                triangleTableRange,
                field: "compacttriangle_t table@\(triangleTableOffset)"
            )
            let requiredLedgeBytes = try checkedEnd(
                start: compactLedgeHeaderByteCount,
                byteCount: triangleBytes,
                field: "compactledge_t required bytes"
            )
            guard declaredByteCount >= requiredLedgeBytes else {
                throw SourceVPhysicsCollisionInvalidReason.invalidDeclaredLedgeByteCount(
                    ledgeOffset: ledgeOffset,
                    declared: declaredByteCount,
                    required: requiredLedgeBytes
                )
            }
            let declaredRange = try reader.range(
                at: ledgeOffset,
                byteCount: declaredByteCount,
                field: "compactledge_t declared bytes"
            )
            var triangles: [SourceVPhysicsCompactTriangleSnapshot] = []
            triangles.reserveCapacity(triangleCount)
            var maximumPointIndex = 0
            var referencedPointIndices: Set<Int> = []
            for triangleIndex in 0..<triangleCount {
                let triangleOffset = try checkedEnd(
                    start: triangleTableOffset,
                    byteCount: triangleIndex * compactTriangleByteCount,
                    field: "compacttriangle_t offset"
                )
                let triangleRange = SourceVPhysicsCollisionByteRange(
                    offset: triangleOffset,
                    byteCount: compactTriangleByteCount
                )
                let rawWord = try reader.uint32(
                    at: triangleOffset,
                    field: "compacttriangle_t.flags"
                )
                var edges: [SourceVPhysicsCompactEdgeSnapshot] = []
                edges.reserveCapacity(3)
                for edgeIndex in 0..<3 {
                    let rawEdge = try reader.uint32(
                        at: triangleOffset + 4 + (edgeIndex * 4),
                        field: "compacttriangle_t.edge[\(edgeIndex)]"
                    )
                    let pointIndex = UInt16(rawEdge & 0xFFFF)
                    let unsignedOpposite = Int32((rawEdge >> 16) & 0x7FFF)
                    let signedOpposite = unsignedOpposite >= 0x4000
                        ? unsignedOpposite - 0x8000
                        : unsignedOpposite
                    maximumPointIndex = max(maximumPointIndex, Int(pointIndex))
                    referencedPointIndices.insert(Int(pointIndex))
                    edges.append(SourceVPhysicsCompactEdgeSnapshot(
                        rawWord: rawEdge,
                        startPointIndex: pointIndex,
                        oppositeIndex: Int16(signedOpposite),
                        isVirtual: (rawEdge & 0x8000_0000) != 0
                    ))
                }
                triangles.append(SourceVPhysicsCompactTriangleSnapshot(
                    byteRange: triangleRange,
                    rawWord: rawWord,
                    triangleIndex: UInt16(rawWord & 0xFFF),
                    pierceIndex: UInt16((rawWord >> 12) & 0xFFF),
                    materialIndex: UInt8((rawWord >> 24) & 0x7F),
                    isVirtual: (rawWord & 0x8000_0000) != 0,
                    edges: edges
                ))
            }

            let pointCount = maximumPointIndex + 1
            let (nextPointTotal, pointTotalOverflow) = totalPoints
                .addingReportingOverflow(pointCount)
            guard !pointTotalOverflow, nextPointTotal <= budget.maximumPoints else {
                throw SourceVPhysicsCollisionInvalidReason.pointCountExceeded(
                    actual: pointTotalOverflow ? Int.max : nextPointTotal,
                    cap: budget.maximumPoints
                )
            }
            let pointTableOffset = try checkedRelativeOffset(
                base: ledgeOffset,
                relative: pointRelativeOffset,
                field: "compactledge_t.c_point_offset"
            )
            try requireAlignment(
                pointTableOffset,
                alignment: naturalRecordAlignment,
                field: "IVP point table"
            )
            let pointBytes = try checkedProduct(
                pointCount,
                rawPointByteCount,
                field: "IVP point table"
            )
            let pointTableRange = try reader.range(
                at: pointTableOffset,
                byteCount: pointBytes,
                field: "IVP point table"
            )
            try occupied.register(
                pointTableRange,
                field: "IVP point table@\(pointTableOffset)"
            )

            var points: [SourceVPhysicsRawIVPPointSnapshot] = []
            points.reserveCapacity(pointCount)
            for pointIndex in 0..<pointCount {
                let pointOffset = try checkedEnd(
                    start: pointTableOffset,
                    byteCount: pointIndex * rawPointByteCount,
                    field: "IVP point offset"
                )
                let position = try reader.vector3(
                    at: pointOffset,
                    field: "IVP point[\(pointIndex)]"
                )
                try requireFinite(position, field: "IVP point[\(pointIndex)]")
                points.append(SourceVPhysicsRawIVPPointSnapshot(
                    byteRange: SourceVPhysicsCollisionByteRange(
                        offset: pointOffset,
                        byteCount: rawPointByteCount
                    ),
                    position: position,
                    fourthLaneBitPattern: try reader.uint32(
                        at: pointOffset + 12,
                        field: "IVP point[\(pointIndex)].fourthLane"
                    )
                ))
            }

            for (triangleIndex, triangle) in triangles.enumerated() {
                let indices = triangle.edges.map { Int($0.startPointIndex) }
                guard Set(indices).count == 3,
                      isNonDegenerateTriangle(
                          points[indices[0]].position,
                          points[indices[1]].position,
                          points[indices[2]].position
                      )
                else {
                    throw SourceVPhysicsCollisionInvalidReason.degenerateTriangle(
                        ledgeOffset: ledgeOffset,
                        triangle: triangleIndex
                    )
                }
            }
            guard spansThreeDimensions(
                referencedPointIndices.sorted().map { points[$0].position }
            ) else {
                throw SourceVPhysicsCollisionInvalidReason.degenerateLedge(
                    ledgeOffset: ledgeOffset
                )
            }

            snapshots.append(SourceVPhysicsCompactLedgeSnapshot(
                headerByteRange: headerRange,
                triangleTableByteRange: triangleTableRange,
                pointTableByteRange: pointTableRange,
                declaredByteRange: declaredRange,
                pointTableRelativeOffset: pointRelativeOffset,
                clientDataOrTreeOffset: clientDataOrTreeOffset,
                rawFlags: rawFlags,
                hasChildrenFlag: hasChildrenFlag,
                isCompactFlag: isCompactFlag,
                reservedFlagBits: reservedFlagBits,
                declaredByteCount: declaredByteCount,
                reservedWord: reservedWord,
                triangles: triangles,
                points: points
            ))
            totalTriangles = nextTriangleTotal
            totalPoints = nextPointTotal
        }
        return snapshots
    }

    private static func checkedEnd(
        start: Int,
        byteCount: Int,
        field: String
    ) throws -> Int {
        let (end, overflow) = start.addingReportingOverflow(byteCount)
        guard start >= 0, byteCount >= 0, !overflow else {
            throw SourceVPhysicsCollisionInvalidReason.integerOverflow(field: field)
        }
        return end
    }

    private static func checkedProduct(
        _ lhs: Int,
        _ rhs: Int,
        field: String
    ) throws -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard lhs >= 0, rhs >= 0, !overflow else {
            throw SourceVPhysicsCollisionInvalidReason.integerOverflow(field: field)
        }
        return product
    }

    private static func checkedRelativeOffset(
        base: Int,
        relative: Int32,
        field: String
    ) throws -> Int {
        guard relative != 0 else {
            throw SourceVPhysicsCollisionInvalidReason.zeroRelativeOffset(field: field)
        }
        let (result, overflow) = base.addingReportingOverflow(Int(relative))
        guard !overflow else {
            throw SourceVPhysicsCollisionInvalidReason.integerOverflow(field: field)
        }
        return result
    }

    private static func requireAlignment(
        _ offset: Int,
        alignment: Int,
        field: String
    ) throws {
        guard offset.isMultiple(of: alignment) else {
            throw SourceVPhysicsCollisionInvalidReason.misaligned(
                field: field,
                offset: offset,
                alignment: alignment
            )
        }
    }

    private static func requireFinite(
        _ vector: SourceVPhysicsRawIVPVector3,
        field: String
    ) throws {
        guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
            throw SourceVPhysicsCollisionInvalidReason.nonFinite(field: field)
        }
    }

    private static func isNonDegenerateTriangle(
        _ first: SourceVPhysicsRawIVPVector3,
        _ second: SourceVPhysicsRawIVPVector3,
        _ third: SourceVPhysicsRawIVPVector3
    ) -> Bool {
        let ab = (
            Double(second.x) - Double(first.x),
            Double(second.y) - Double(first.y),
            Double(second.z) - Double(first.z)
        )
        let ac = (
            Double(third.x) - Double(first.x),
            Double(third.y) - Double(first.y),
            Double(third.z) - Double(first.z)
        )
        let cross = (
            (ab.1 * ac.2) - (ab.2 * ac.1),
            (ab.2 * ac.0) - (ab.0 * ac.2),
            (ab.0 * ac.1) - (ab.1 * ac.0)
        )
        let squared = (cross.0 * cross.0)
            + (cross.1 * cross.1)
            + (cross.2 * cross.2)
        return squared.isFinite && squared > 0
    }

    private static func spansThreeDimensions(
        _ points: [SourceVPhysicsRawIVPVector3]
    ) -> Bool {
        guard points.count >= 4 else { return false }
        let origin = points[0]
        guard let secondIndex = points.indices.dropFirst().first(where: {
            points[$0] != origin
        }) else { return false }
        let second = points[secondIndex]
        let ab = (
            Double(second.x) - Double(origin.x),
            Double(second.y) - Double(origin.y),
            Double(second.z) - Double(origin.z)
        )
        var normal: (Double, Double, Double)?
        for index in points.indices where index != 0 && index != secondIndex {
            let candidate = points[index]
            let ac = (
                Double(candidate.x) - Double(origin.x),
                Double(candidate.y) - Double(origin.y),
                Double(candidate.z) - Double(origin.z)
            )
            let cross = (
                (ab.1 * ac.2) - (ab.2 * ac.1),
                (ab.2 * ac.0) - (ab.0 * ac.2),
                (ab.0 * ac.1) - (ab.1 * ac.0)
            )
            let squared = (cross.0 * cross.0)
                + (cross.1 * cross.1)
                + (cross.2 * cross.2)
            if squared.isFinite, squared > 0 {
                normal = cross
                break
            }
        }
        guard let normal else { return false }
        for point in points {
            let delta = (
                Double(point.x) - Double(origin.x),
                Double(point.y) - Double(origin.y),
                Double(point.z) - Double(origin.z)
            )
            let volume = (normal.0 * delta.0)
                + (normal.1 * delta.1)
                + (normal.2 * delta.2)
            if volume.isFinite, volume != 0 {
                return true
            }
        }
        return false
    }
}

private struct SourceVPhysicsCollisionReader {
    let data: Data
    let allowedRange: SourceVPhysicsCollisionByteRange

    func range(
        at offset: Int,
        byteCount: Int,
        field: String
    ) throws -> SourceVPhysicsCollisionByteRange {
        let end: Int
        let (candidateEnd, overflow) = offset.addingReportingOverflow(byteCount)
        guard offset >= 0, byteCount >= 0, !overflow else {
            throw SourceVPhysicsCollisionInvalidReason.integerOverflow(field: field)
        }
        end = candidateEnd
        guard offset >= allowedRange.offset,
              end <= allowedRange.endOffset,
              end <= data.count
        else {
            throw SourceVPhysicsCollisionInvalidReason.rangeOutOfBounds(
                field: field,
                offset: offset,
                byteCount: byteCount,
                allowed: allowedRange
            )
        }
        return SourceVPhysicsCollisionByteRange(offset: offset, byteCount: byteCount)
    }

    func uint8(at offset: Int, field: String) throws -> UInt8 {
        _ = try range(at: offset, byteCount: 1, field: field)
        return data[offset]
    }

    func uint16(at offset: Int, field: String) throws -> UInt16 {
        _ = try range(at: offset, byteCount: 2, field: field)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
        }
    }

    func int16(at offset: Int, field: String) throws -> Int16 {
        Int16(bitPattern: try uint16(at: offset, field: field))
    }

    func uint32(at offset: Int, field: String) throws -> UInt32 {
        _ = try range(at: offset, byteCount: 4, field: field)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            UInt32(raw[offset])
                | (UInt32(raw[offset + 1]) << 8)
                | (UInt32(raw[offset + 2]) << 16)
                | (UInt32(raw[offset + 3]) << 24)
        }
    }

    func int32(at offset: Int, field: String) throws -> Int32 {
        Int32(bitPattern: try uint32(at: offset, field: field))
    }

    func float32(at offset: Int, field: String) throws -> Float {
        Float(bitPattern: try uint32(at: offset, field: field))
    }

    func vector3(
        at offset: Int,
        field: String
    ) throws -> SourceVPhysicsRawIVPVector3 {
        _ = try range(at: offset, byteCount: 12, field: field)
        return SourceVPhysicsRawIVPVector3(
            x: try float32(at: offset, field: "\(field).x"),
            y: try float32(at: offset + 4, field: "\(field).y"),
            z: try float32(at: offset + 8, field: "\(field).z")
        )
    }
}

private struct SourceVPhysicsOccupiedRanges {
    private var entries: [(
        field: String,
        range: SourceVPhysicsCollisionByteRange
    )] = []

    mutating func register(
        _ range: SourceVPhysicsCollisionByteRange,
        field: String
    ) throws {
        if let overlap = entries.first(where: {
            range.offset < $0.range.endOffset
                && $0.range.offset < range.endOffset
        }) {
            throw SourceVPhysicsCollisionInvalidReason.overlappingRanges(
                firstField: overlap.field,
                secondField: field
            )
        }
        entries.append((field: field, range: range))
    }
}
