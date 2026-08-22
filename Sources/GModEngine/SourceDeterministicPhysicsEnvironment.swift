public enum SourceDeterministicPhysicsStaticSceneError:
    Error, Equatable, Sendable
{
    case bodyIsNotCanonicalWorld(SourcePhysicsBodyID)
    case emptyGeometry
    case emptyPart(Int)
    case nonFiniteVertex(part: Int, vertex: Int)
    case invalidTriangleIndex(part: Int, triangle: Int, index: Int)
    case degenerateTriangle(part: Int, triangle: Int)
    case materialIndexOutsideSevenBits(Int)
    case emptyContents
    case nonFiniteTransform
}

/// One indexed triangle in immutable BSP world geometry. Surface material is
/// optional because a BSP texture reference alone does not attest the resolved
/// VPhysics `surfaceproperties` index.
public struct SourceDeterministicPhysicsStaticTriangle: Equatable, Sendable {
    public let first: Int
    public let second: Int
    public let third: Int
    public let materialIndex: Int?

    public init(
        first: Int,
        second: Int,
        third: Int,
        materialIndex: Int? = nil
    ) throws {
        guard first >= 0, second >= 0, third >= 0 else {
            throw SourceDeterministicPhysicsStaticSceneError
                .invalidTriangleIndex(
                    part: -1,
                    triangle: -1,
                    index: Swift.min(first, Swift.min(second, third))
                )
        }
        guard first != second, second != third, first != third else {
            throw SourceDeterministicPhysicsStaticSceneError
                .degenerateTriangle(part: -1, triangle: -1)
        }
        if let materialIndex, !(0 ... 127).contains(materialIndex) {
            throw SourceDeterministicPhysicsStaticSceneError
                .materialIndexOutsideSevenBits(materialIndex)
        }
        self.first = first
        self.second = second
        self.third = third
        self.materialIndex = materialIndex
    }
}

/// How one immutable world-mesh part participates in hull collision.
///
/// VBSP brushes are closed convex volumes and retain the existing plane-clip
/// path. Displacements are authored as open triangle meshes and require exact
/// swept box-versus-triangle SAT; treating either representation as the other
/// creates false terrain walls or lets fast bodies tunnel through the surface.
public enum SourceDeterministicPhysicsStaticMeshTopology:
    Equatable, Sendable
{
    case closedConvexVolume
    case openTriangleMesh
}

/// One immutable BSP collision part represented as indexed triangles.
/// Geometry is kept separate from dynamic-body shape snapshots so an unknown
/// material never needs a guessed integer placeholder.
public struct SourceDeterministicPhysicsStaticMeshPart: Equatable, Sendable {
    public let vertices: [SourceVector3]
    public let triangles: [SourceDeterministicPhysicsStaticTriangle]
    public let topology: SourceDeterministicPhysicsStaticMeshTopology

    public init(
        vertices: [SourceVector3],
        triangles: [SourceDeterministicPhysicsStaticTriangle],
        topology: SourceDeterministicPhysicsStaticMeshTopology =
            .closedConvexVolume,
        partIndex: Int = 0
    ) throws {
        guard !vertices.isEmpty, !triangles.isEmpty else {
            throw SourceDeterministicPhysicsStaticSceneError.emptyPart(partIndex)
        }
        for (vertexIndex, vertex) in vertices.enumerated()
        where !vertex.isSourcePhysicsFinite {
            throw SourceDeterministicPhysicsStaticSceneError.nonFiniteVertex(
                part: partIndex,
                vertex: vertexIndex
            )
        }
        for (triangleIndex, triangle) in triangles.enumerated() {
            for index in [triangle.first, triangle.second, triangle.third]
            where !vertices.indices.contains(index) {
                throw SourceDeterministicPhysicsStaticSceneError
                    .invalidTriangleIndex(
                        part: partIndex,
                        triangle: triangleIndex,
                        index: index
                    )
            }
        }
        self.vertices = vertices
        self.triangles = triangles
        self.topology = topology
    }
}

public struct SourceDeterministicPhysicsStaticGeometry: Equatable, Sendable {
    public let parts: [SourceDeterministicPhysicsStaticMeshPart]

    public init(parts: [SourceDeterministicPhysicsStaticMeshPart]) throws {
        guard !parts.isEmpty else {
            throw SourceDeterministicPhysicsStaticSceneError.emptyGeometry
        }
        self.parts = parts
    }
}

/// Massless immutable world geometry kept outside the rigid-body collection.
///
/// Source worldspawn is addressable through a complete EHANDLE for traces, but
/// it is not a `prop_physics` and must never receive invented mass or inertia.
/// Consequently this scene participates in contact/query generation without
/// appearing in ``SourcePhysicsEnvironmentSnapshot.bodies``.
public struct SourceDeterministicPhysicsStaticScene: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID
    public let geometry: SourceDeterministicPhysicsStaticGeometry
    public let transform: SourceEntityTransform
    public let contents: SourceContents

    public init(
        bodyID: SourcePhysicsBodyID,
        geometry: SourceDeterministicPhysicsStaticGeometry,
        transform: SourceEntityTransform = .identity,
        contents: SourceContents
    ) throws {
        // Source reserves entry zero for worldspawn, but the full EHANDLE
        // serial still belongs to the current canonical entity-list lifetime.
        guard bodyID.entityIdentity.entryIndex == 0 else {
            throw SourceDeterministicPhysicsStaticSceneError
                .bodyIsNotCanonicalWorld(bodyID)
        }
        guard !contents.isEmpty else {
            throw SourceDeterministicPhysicsStaticSceneError.emptyContents
        }
        guard transform.origin.isSourcePhysicsFinite,
              transform.angles.pitch.isFinite,
              transform.angles.yaw.isFinite,
              transform.angles.roll.isFinite else {
            throw SourceDeterministicPhysicsStaticSceneError
                .nonFiniteTransform
        }
        self.bodyID = bodyID
        self.geometry = geometry
        self.transform = transform
        self.contents = contents
    }
}

/// Deterministic, CPU-only implementation of ``SourcePhysicsEnvironment``.
///
/// This backend consumes only geometry, mass, and principal inertia that have
/// already crossed the fail-closed physics contract. It never creates a box,
/// density, or inertia fallback. Dynamic props use verified convex parts,
/// while static world collision may use the verified triangle-mesh topology.
///
/// The solver is intentionally backend-independent and single-lane. Command
/// batches are applied transactionally in complete EHANDLE order. It provides
/// the first usable Source fixed-step path while a separately measured native
/// VPhysics-compatible backend can later implement the same public contract.
public final class SourceDeterministicPhysicsEnvironment:
    SourcePhysicsEnvironment
{
    /// Source/GMod's default `sv_gravity`, expressed in Source units/second².
    public static let sourceDefaultGravity = SourceVector3(0, 0, -800)

    public struct Configuration: Equatable, Sendable {
        public let gravity: SourceVector3
        public let contactSolverIterations: Int
        public let contactSlop: Float
        public let sleepLinearSpeed: Float
        public let sleepAngularSpeedDegrees: Float
        public let sleepAfterSettledTicks: UInt16
        public let impactWakeSpeed: Float

        public init(
            gravity: SourceVector3 =
                SourceDeterministicPhysicsEnvironment.sourceDefaultGravity,
            contactSolverIterations: Int = 8,
            contactSlop: Float = 0.001,
            sleepLinearSpeed: Float = 0.05,
            sleepAngularSpeedDegrees: Float = 0.05,
            sleepAfterSettledTicks: UInt16 = 20,
            impactWakeSpeed: Float = 0.1
        ) throws {
            guard gravity.isSourcePhysicsFinite else {
                throw Error.invalidConfiguration(field: "gravity")
            }
            guard contactSolverIterations > 0 else {
                throw Error.invalidConfiguration(
                    field: "contactSolverIterations"
                )
            }
            guard contactSlop.isFinite, contactSlop >= 0 else {
                throw Error.invalidConfiguration(field: "contactSlop")
            }
            guard sleepLinearSpeed.isFinite, sleepLinearSpeed >= 0 else {
                throw Error.invalidConfiguration(field: "sleepLinearSpeed")
            }
            guard sleepAngularSpeedDegrees.isFinite,
                  sleepAngularSpeedDegrees >= 0 else {
                throw Error.invalidConfiguration(
                    field: "sleepAngularSpeedDegrees"
                )
            }
            guard sleepAfterSettledTicks > 0 else {
                throw Error.invalidConfiguration(
                    field: "sleepAfterSettledTicks"
                )
            }
            guard impactWakeSpeed.isFinite, impactWakeSpeed >= 0 else {
                throw Error.invalidConfiguration(field: "impactWakeSpeed")
            }
            self.gravity = gravity
            self.contactSolverIterations = contactSolverIterations
            self.contactSlop = contactSlop
            self.sleepLinearSpeed = sleepLinearSpeed
            self.sleepAngularSpeedDegrees = sleepAngularSpeedDegrees
            self.sleepAfterSettledTicks = sleepAfterSettledTicks
            self.impactWakeSpeed = impactWakeSpeed
        }

        public static var sourceDefault: Configuration {
            // Every literal is validated by the public initializer. A failure
            // here would be a programming error, not recoverable content I/O.
            try! Configuration()
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidConfiguration(field: String)
        case duplicateBody(SourcePhysicsBodyID)
        case missingBody(SourcePhysicsBodyID)
        case duplicateConstraint(SourcePhysicsConstraintID)
        case retiredConstraint(SourcePhysicsConstraintID)
        case missingConstraint(SourcePhysicsConstraintID)
        case constraintBodyMissing(
            constraintID: SourcePhysicsConstraintID,
            bodyID: SourcePhysicsBodyID
        )
        case bodyHasLiveConstraint(
            bodyID: SourcePhysicsBodyID,
            constraintID: SourcePhysicsConstraintID
        )
        case nonFiniteConstraintResult(SourcePhysicsConstraintID)
        case breakableLengthConstraintUnavailable(SourcePhysicsConstraintID)
        case staticWorldConstraintEndpointUnavailable(
            constraintID: SourcePhysicsConstraintID,
            bodyID: SourcePhysicsBodyID
        )
        case bodyDoesNotSupportMotion(SourcePhysicsBodyID)
        case bodyMotionDisabled(SourcePhysicsBodyID)
        case nonFiniteMutationResult(
            bodyID: SourcePhysicsBodyID,
            operation: String
        )
        case commandSequenceNotIncreasing(previous: UInt64, current: UInt64)
        case simulationTickNotIncreasing(previous: UInt64, current: UInt64)
        case nonFiniteContactImpulse(
            firstBodyID: SourcePhysicsBodyID,
            secondBodyID: SourcePhysicsBodyID
        )
    }

    /// One solver-authored contact from the most recently committed fixed
    /// step. IDs retain their full Source generations and are always ordered.
    public struct ContactSnapshot: Equatable, Sendable {
        public let firstBodyID: SourcePhysicsBodyID
        public let secondBodyID: SourcePhysicsBodyID
        public let firstMaterialIndex: Int?
        public let secondMaterialIndex: Int?
        /// Unit normal pointing from `firstBodyID` toward `secondBodyID`.
        public let normal: SourceVector3
        public let position: SourceVector3
        public let penetration: Float
        public let simulationTick: UInt64
    }

    private struct BodyState: Equatable {
        let creation: SourcePhysicsBodyCreationCommand
        var massProperties: SourcePhysicsMassProperties
        var transform: SourceEntityTransform
        var linearVelocity: SourceVector3
        var angularVelocity: SourceVector3
        var damping: SourcePhysicsDamping
        var accumulatedCenterForce: SourceVector3
        var accumulatedCenterTorque: SourceVector3
        var isMotionEnabled: Bool
        var isGravityEnabled: Bool
        var isCollisionEnabled: Bool
        var isSleeping: Bool
        var settledTicks: UInt16
        var simulationTick: UInt64

        var bodyID: SourcePhysicsBodyID { creation.bodyID }
        var motionType: SourcePhysicsMotionType { creation.motionType }
        var supportsMotion: Bool { motionType != .staticBody }
        var isDynamic: Bool {
            motionType == .dynamicBody && isMotionEnabled
        }
        var isMovable: Bool { supportsMotion && isMotionEnabled }
    }

    private struct FixedConstraintState: Equatable {
        let creation: SourcePhysicsFixedConstraintCreationCommand
        let relativePose: SourcePhysicsFixedConstraintPose
        var simulationTick: UInt64

        var constraintID: SourcePhysicsConstraintID {
            creation.constraintID
        }
    }

    private struct LengthConstraintState: Equatable {
        let creation: SourcePhysicsLengthConstraintCreationCommand
        /// Stable fallback for a rigid constraint whose anchors become
        /// coincident before the solver can recover a direction.
        let initialReferenceToAttachedDirection: SourceVector3
        var simulationTick: UInt64

        var constraintID: SourcePhysicsConstraintID {
            creation.constraintID
        }
    }

    private struct NoCollideConstraintState: Equatable {
        let creation: SourcePhysicsNoCollideConstraintCreationCommand
        var simulationTick: UInt64

        var constraintID: SourcePhysicsConstraintID {
            creation.constraintID
        }
    }

    /// Symmetric dynamic-body collision exclusion key retaining complete body
    /// identities so an edict-slot reuse cannot inherit a stale relationship.
    private struct BodyPair: Hashable {
        let first: SourcePhysicsBodyID
        let second: SourcePhysicsBodyID

        init(_ lhs: SourcePhysicsBodyID, _ rhs: SourcePhysicsBodyID) {
            if SourceDeterministicPhysicsEnvironment.bodyIDPrecedes(lhs, rhs) {
                first = lhs
                second = rhs
            } else {
                first = rhs
                second = lhs
            }
        }
    }

    private struct Bounds {
        var minimums: SourceVector3
        var maximums: SourceVector3

        func intersects(_ other: Bounds) -> Bool {
            minimums.x <= other.maximums.x && maximums.x >= other.minimums.x &&
                minimums.y <= other.maximums.y && maximums.y >= other.minimums.y &&
                minimums.z <= other.maximums.z && maximums.z >= other.minimums.z
        }

        func contains(_ point: SourceVector3) -> Bool {
            point.x >= minimums.x && point.x <= maximums.x &&
                point.y >= minimums.y && point.y <= maximums.y &&
                point.z >= minimums.z && point.z <= maximums.z
        }

        func merged(with other: Bounds) -> Bounds {
            Bounds(
                minimums: SourceVector3(
                    min(minimums.x, other.minimums.x),
                    min(minimums.y, other.minimums.y),
                    min(minimums.z, other.minimums.z)
                ),
                maximums: SourceVector3(
                    max(maximums.x, other.maximums.x),
                    max(maximums.y, other.maximums.y),
                    max(maximums.z, other.maximums.z)
                )
            )
        }

        var center: SourceVector3 { (minimums + maximums) * 0.5 }
    }

    private struct WorldTriangle {
        let first: SourceVector3
        let second: SourceVector3
        let third: SourceVector3
        let materialIndex: Int?

        var vertices: [SourceVector3] { [first, second, third] }
        var edges: [SourceVector3] {
            [second - first, third - second, first - third]
        }
        var normal: SourceVector3 {
            (second - first).cross(third - first).normalizedOrZero
        }
        var center: SourceVector3 { (first + second + third) / 3 }
    }

    private struct WorldPart {
        let vertices: [SourceVector3]
        let triangles: [WorldTriangle]
        let bounds: Bounds
        let center: SourceVector3
        let faceNormals: [SourceVector3]
        let edges: [SourceVector3]
        let staticMeshTopology: SourceDeterministicPhysicsStaticMeshTopology
    }

    private struct WorldShape {
        let topology: SourcePhysicsShapeTopology
        let parts: [WorldPart]
        let bounds: Bounds
    }

    private struct StaticBroadphaseNode {
        let bounds: Bounds
        let leftChild: Int
        let rightChild: Int
        let firstPartOffset: Int
        let partCount: Int

        var isLeaf: Bool { partCount > 0 }
    }

    private struct StaticBroadphase {
        let nodes: [StaticBroadphaseNode]
        let orderedPartIndices: [Int]
    }

    struct StaticBroadphaseDiagnostics: Equatable {
        let totalPartCount: Int
        let candidatePartCount: Int
        let visitedNodeCount: Int
    }

    /// Per-contact-detection accounting for the mutable rigid-body
    /// broadphase. Counts describe collision-enabled bodies only after the
    /// explicit total, so disabled bodies remain observable without entering
    /// the sweep or changing legacy collision behavior.
    struct DynamicBroadphaseDiagnostics: Equatable {
        let totalBodyCount: Int
        let collisionEnabledBodyCount: Int
        let fullPairCount: Int
        let sweepCandidatePairCount: Int
        let narrowphaseCandidatePairCount: Int
    }

    private struct Contact {
        let firstBodyID: SourcePhysicsBodyID
        let secondBodyID: SourcePhysicsBodyID
        let firstMaterialIndex: Int?
        let secondMaterialIndex: Int?
        var normal: SourceVector3
        var position: SourceVector3
        var penetration: Float
    }

    private struct Projection {
        let minimum: Float
        let maximum: Float
    }

    private struct SegmentBoundsHit {
        let fraction: Float
        let normal: SourceVector3
        let startedSolid: Bool
        let allSolid: Bool
    }

    private struct ConvexSweepHit {
        let fraction: Float
        let normal: SourceVector3
        let materialIndex: Int?
        let startedSolid: Bool
        let allSolid: Bool
    }

    public let configuration: Configuration
    public let staticCollisionScene: SourceDeterministicPhysicsStaticScene?
    /// Every contact pair resolves fail-closed. The default empty table keeps
    /// construction source-compatible while ensuring an unconfigured solver
    /// cannot silently substitute invented inert coefficients.
    public let materialTable: SourcePhysicsMaterialTable

    /// The immutable BSP scene is transformed once, not rebuilt for every
    /// 0.015-second simulation step or query.
    private lazy var staticCollisionWorldShape: WorldShape? = {
        staticCollisionScene.map {
            makeWorldShape(geometry: $0.geometry, transform: $0.transform)
        }
    }()

    /// Built once from immutable world-brush bounds. Leaves retain original
    /// part indices and every query sorts candidates back into that order, so
    /// broadphase pruning cannot alter narrowphase ties or StartSolid choice.
    private lazy var staticCollisionBroadphase: StaticBroadphase? = {
        guard let shape = staticCollisionWorldShape else { return nil }
        return Self.makeStaticBroadphase(parts: shape.parts)
    }()

    public private(set) var latestContacts: [ContactSnapshot] = []

    private(set) var latestStaticBroadphaseDiagnostics:
        StaticBroadphaseDiagnostics
    private(set) var latestDynamicBroadphaseDiagnostics:
        DynamicBroadphaseDiagnostics

    private var bodies: [SourcePhysicsBodyID: BodyState] = [:]
    private var fixedConstraints: [
        SourcePhysicsConstraintID: FixedConstraintState
    ] = [:]
    private var lengthConstraints: [
        SourcePhysicsConstraintID: LengthConstraintState
    ] = [:]
    private var noCollideConstraints: [
        SourcePhysicsConstraintID: NoCollideConstraintState
    ] = [:]
    private var retiredConstraintIDs = Set<SourcePhysicsConstraintID>()
    private var simulationTick: UInt64 = 0
    private var hasSimulated = false
    private var lastProcessedCommandSequence: UInt64?
    /// Single-lane scratch storage. Capacity is reserved from the immutable
    /// scene at initialization and retained across every fixed tick/query.
    private var staticBroadphaseStack: [Int] = []
    private var staticCandidatePartIndices: [Int] = []

    public init(
        configuration: Configuration = .sourceDefault,
        staticCollisionScene: SourceDeterministicPhysicsStaticScene? = nil,
        materialTable: SourcePhysicsMaterialTable = .unconfigured
    ) {
        self.configuration = configuration
        self.staticCollisionScene = staticCollisionScene
        self.materialTable = materialTable
        let staticPartCount = staticCollisionScene?.geometry.parts.count ?? 0
        latestStaticBroadphaseDiagnostics = StaticBroadphaseDiagnostics(
            totalPartCount: staticPartCount,
            candidatePartCount: 0,
            visitedNodeCount: 0
        )
        latestDynamicBroadphaseDiagnostics = DynamicBroadphaseDiagnostics(
            totalBodyCount: 0,
            collisionEnabledBodyCount: 0,
            fullPairCount: 0,
            sweepCandidatePairCount: 0,
            narrowphaseCandidatePairCount: 0
        )
        staticBroadphaseStack.reserveCapacity(max(1, staticPartCount * 2))
        staticCandidatePartIndices.reserveCapacity(staticPartCount)
        // Pay immutable world transform/BVH allocation at environment setup,
        // never inside the first fixed simulation tick or gameplay query.
        if staticPartCount > 0 {
            _ = staticCollisionBroadphase
        }
    }

    private static func makeStaticBroadphase(
        parts: [WorldPart]
    ) -> StaticBroadphase? {
        guard !parts.isEmpty else { return nil }
        let maximumLeafPartCount = 8
        var orderedPartIndices = Array(parts.indices)
        var nodes: [StaticBroadphaseNode] = []
        nodes.reserveCapacity(parts.count * 2)

        func bounds(for range: Range<Int>) -> Bounds {
            var result = parts[orderedPartIndices[range.lowerBound]].bounds
            for offset in range.dropFirst() {
                result = result.merged(
                    with: parts[orderedPartIndices[offset]].bounds
                )
            }
            return result
        }

        func build(_ range: Range<Int>) -> Int {
            let nodeIndex = nodes.count
            let nodeBounds = bounds(for: range)
            nodes.append(StaticBroadphaseNode(
                bounds: nodeBounds,
                leftChild: -1,
                rightChild: -1,
                firstPartOffset: range.lowerBound,
                partCount: range.count
            ))
            guard range.count > maximumLeafPartCount else { return nodeIndex }

            var centroidMinimums = parts[
                orderedPartIndices[range.lowerBound]
            ].bounds.center
            var centroidMaximums = centroidMinimums
            for offset in range.dropFirst() {
                let centroid = parts[orderedPartIndices[offset]].bounds.center
                centroidMinimums = SourceVector3(
                    min(centroidMinimums.x, centroid.x),
                    min(centroidMinimums.y, centroid.y),
                    min(centroidMinimums.z, centroid.z)
                )
                centroidMaximums = SourceVector3(
                    max(centroidMaximums.x, centroid.x),
                    max(centroidMaximums.y, centroid.y),
                    max(centroidMaximums.z, centroid.z)
                )
            }
            let extents = centroidMaximums - centroidMinimums
            let axis: Int
            if extents.x >= extents.y, extents.x >= extents.z {
                axis = 0
            } else if extents.y >= extents.z {
                axis = 1
            } else {
                axis = 2
            }
            orderedPartIndices[range].sort { first, second in
                let firstValue = parts[first].bounds.center[axis]
                let secondValue = parts[second].bounds.center[axis]
                if firstValue != secondValue { return firstValue < secondValue }
                return first < second
            }

            let middle = range.lowerBound + range.count / 2
            let leftChild = build(range.lowerBound ..< middle)
            let rightChild = build(middle ..< range.upperBound)
            nodes[nodeIndex] = StaticBroadphaseNode(
                bounds: nodeBounds,
                leftChild: leftChild,
                rightChild: rightChild,
                firstPartOffset: 0,
                partCount: 0
            )
            return nodeIndex
        }

        _ = build(orderedPartIndices.startIndex ..< orderedPartIndices.endIndex)
        return StaticBroadphase(
            nodes: nodes,
            orderedPartIndices: orderedPartIndices
        )
    }

    private func prepareStaticCandidates(overlapping queryBounds: Bounds) {
        staticBroadphaseStack.removeAll(keepingCapacity: true)
        staticCandidatePartIndices.removeAll(keepingCapacity: true)
        guard let broadphase = staticCollisionBroadphase,
              !broadphase.nodes.isEmpty else {
            latestStaticBroadphaseDiagnostics = StaticBroadphaseDiagnostics(
                totalPartCount: staticCollisionScene?.geometry.parts.count ?? 0,
                candidatePartCount: 0,
                visitedNodeCount: 0
            )
            return
        }

        var visitedNodeCount = 0
        staticBroadphaseStack.append(0)
        while let nodeIndex = staticBroadphaseStack.popLast() {
            visitedNodeCount += 1
            let node = broadphase.nodes[nodeIndex]
            guard node.bounds.intersects(queryBounds) else { continue }
            if node.isLeaf {
                let end = node.firstPartOffset + node.partCount
                staticCandidatePartIndices.append(contentsOf:
                    broadphase.orderedPartIndices[node.firstPartOffset ..< end]
                )
            } else {
                // Push right first so left is visited first. The final sort is
                // still mandatory because BVH spatial order is not Source BSP
                // brush order.
                staticBroadphaseStack.append(node.rightChild)
                staticBroadphaseStack.append(node.leftChild)
            }
        }
        staticCandidatePartIndices.sort()
        latestStaticBroadphaseDiagnostics = StaticBroadphaseDiagnostics(
            totalPartCount: broadphase.orderedPartIndices.count,
            candidatePartCount: staticCandidatePartIndices.count,
            visitedNodeCount: visitedNodeCount
        )
    }

    private func motionBounds(
        start: SourceVector3,
        end: SourceVector3,
        minimums: SourceVector3,
        maximums: SourceVector3
    ) -> Bounds {
        Bounds(
            minimums: SourceVector3(
                min(start.x + minimums.x, end.x + minimums.x),
                min(start.y + minimums.y, end.y + minimums.y),
                min(start.z + minimums.z, end.z + minimums.z)
            ),
            maximums: SourceVector3(
                max(start.x + maximums.x, end.x + maximums.x),
                max(start.y + maximums.y, end.y + maximums.y),
                max(start.z + maximums.z, end.z + maximums.z)
            )
        )
    }

    /// Applies a whole host-FIFO slice or no part of it. Queries observe every
    /// create/delete/simulate command before them in the same slice.
    public func execute(
        _ batch: SourcePhysicsCommandBatch
    ) throws -> SourcePhysicsEnvironmentSnapshot {
        if let first = batch.commands.first,
           let previous = lastProcessedCommandSequence,
           first.sequence <= previous {
            throw Error.commandSequenceNotIncreasing(
                previous: previous,
                current: first.sequence
            )
        }

        var candidateBodies = bodies
        var candidateFixedConstraints = fixedConstraints
        var candidateLengthConstraints = lengthConstraints
        var candidateNoCollideConstraints = noCollideConstraints
        var candidateRetiredConstraintIDs = retiredConstraintIDs
        var candidateTick = simulationTick
        var candidateHasSimulated = hasSimulated
        var candidateContacts = latestContacts
        var queryResults: [SourcePhysicsQueryResultSnapshot] = []

        for command in batch.commands {
            switch command.payload {
            case let .createBody(creation):
                guard candidateBodies[creation.bodyID] == nil,
                      staticCollisionScene?.bodyID != creation.bodyID else {
                    throw Error.duplicateBody(creation.bodyID)
                }
                candidateBodies[creation.bodyID] = BodyState(
                    creation: creation,
                    massProperties: creation.massProperties,
                    transform: creation.transform,
                    linearVelocity: creation.linearVelocity,
                    angularVelocity: creation.angularVelocity,
                    damping: creation.damping,
                    accumulatedCenterForce: .zero,
                    accumulatedCenterTorque: .zero,
                    isMotionEnabled: creation.motionType != .staticBody,
                    isGravityEnabled: creation.isGravityEnabled,
                    isCollisionEnabled: creation.isCollisionEnabled,
                    isSleeping: creation.motionType == .staticBody ||
                        (creation.motionType == .dynamicBody &&
                            !creation.startsAwake),
                    settledTicks: 0,
                    simulationTick: candidateTick
                )

            case let .deleteBody(deletion):
                if let constraint = candidateFixedConstraints.values
                    .filter({
                        $0.creation.referenceBodyID == deletion.bodyID ||
                            $0.creation.attachedBodyID == deletion.bodyID
                    })
                    .min(by: {
                        $0.constraintID.rawValue < $1.constraintID.rawValue
                    }) {
                    throw Error.bodyHasLiveConstraint(
                        bodyID: deletion.bodyID,
                        constraintID: constraint.constraintID
                    )
                }
                if let constraint = candidateLengthConstraints.values
                    .filter({ state in
                        [state.creation.reference, state.creation.attached]
                            .contains { endpoint in
                                endpoint.kind == .body &&
                                    endpoint.bodyID == deletion.bodyID
                            }
                    })
                    .min(by: {
                        $0.constraintID.rawValue < $1.constraintID.rawValue
                    }) {
                    throw Error.bodyHasLiveConstraint(
                        bodyID: deletion.bodyID,
                        constraintID: constraint.constraintID
                    )
                }
                if let constraint = candidateNoCollideConstraints.values
                    .filter({
                        $0.creation.firstBodyID == deletion.bodyID ||
                            $0.creation.secondBodyID == deletion.bodyID
                    })
                    .min(by: {
                        $0.constraintID.rawValue < $1.constraintID.rawValue
                    }) {
                    throw Error.bodyHasLiveConstraint(
                        bodyID: deletion.bodyID,
                        constraintID: constraint.constraintID
                    )
                }
                guard candidateBodies.removeValue(forKey: deletion.bodyID) != nil else {
                    throw Error.missingBody(deletion.bodyID)
                }

            case let .mutateBody(command):
                guard var body = candidateBodies[command.bodyID] else {
                    throw Error.missingBody(command.bodyID)
                }
                try apply(command.mutation, to: &body)
                candidateBodies[command.bodyID] = body

            case let .createFixedConstraint(creation):
                guard candidateFixedConstraints[creation.constraintID] == nil,
                      candidateLengthConstraints[creation.constraintID] == nil,
                      candidateNoCollideConstraints[creation.constraintID] == nil else {
                    throw Error.duplicateConstraint(creation.constraintID)
                }
                guard !candidateRetiredConstraintIDs.contains(
                    creation.constraintID
                ) else {
                    throw Error.retiredConstraint(creation.constraintID)
                }
                guard let reference = candidateBodies[
                    creation.referenceBodyID
                ] else {
                    throw Error.constraintBodyMissing(
                        constraintID: creation.constraintID,
                        bodyID: creation.referenceBodyID
                    )
                }
                guard let attached = candidateBodies[
                    creation.attachedBodyID
                ] else {
                    throw Error.constraintBodyMissing(
                        constraintID: creation.constraintID,
                        bodyID: creation.attachedBodyID
                    )
                }
                candidateFixedConstraints[creation.constraintID] =
                    FixedConstraintState(
                        creation: creation,
                        relativePose: SourcePhysicsFixedConstraintPose(
                            reference: reference.transform,
                            attached: attached.transform
                        ),
                        simulationTick: candidateTick
                    )

            case let .createLengthConstraint(creation):
                guard candidateFixedConstraints[creation.constraintID] == nil,
                      candidateLengthConstraints[creation.constraintID] == nil,
                      candidateNoCollideConstraints[creation.constraintID] == nil else {
                    throw Error.duplicateConstraint(creation.constraintID)
                }
                guard !candidateRetiredConstraintIDs.contains(
                    creation.constraintID
                ) else {
                    throw Error.retiredConstraint(creation.constraintID)
                }
                guard creation.forceLimitKilogramInchesPerSecond == 0 else {
                    throw Error.breakableLengthConstraintUnavailable(
                        creation.constraintID
                    )
                }
                let referenceTransform = try constraintEndpointTransform(
                    creation.reference,
                    constraintID: creation.constraintID,
                    bodies: candidateBodies
                )
                let attachedTransform = try constraintEndpointTransform(
                    creation.attached,
                    constraintID: creation.constraintID,
                    bodies: candidateBodies
                )
                let referenceAnchor = referenceTransform
                    .transformPointFromLocal(creation.reference.localAnchor)
                let attachedAnchor = attachedTransform
                    .transformPointFromLocal(creation.attached.localAnchor)
                let anchorDelta = attachedAnchor - referenceAnchor
                let initialDirection: SourceVector3
                if anchorDelta.lengthSquared > 0 {
                    initialDirection = anchorDelta /
                        anchorDelta.lengthSquared.squareRoot()
                } else {
                    initialDirection = SourceVector3(1, 0, 0)
                }
                candidateLengthConstraints[creation.constraintID] =
                    LengthConstraintState(
                        creation: creation,
                        initialReferenceToAttachedDirection: initialDirection,
                        simulationTick: candidateTick
                    )

            case let .createNoCollideConstraint(creation):
                guard candidateFixedConstraints[creation.constraintID] == nil,
                      candidateLengthConstraints[creation.constraintID] == nil,
                      candidateNoCollideConstraints[creation.constraintID] == nil else {
                    throw Error.duplicateConstraint(creation.constraintID)
                }
                guard !candidateRetiredConstraintIDs.contains(
                    creation.constraintID
                ) else {
                    throw Error.retiredConstraint(creation.constraintID)
                }
                for bodyID in [creation.firstBodyID, creation.secondBodyID]
                    where candidateBodies[bodyID] == nil {
                    throw Error.constraintBodyMissing(
                        constraintID: creation.constraintID,
                        bodyID: bodyID
                    )
                }
                candidateNoCollideConstraints[creation.constraintID] =
                    NoCollideConstraintState(
                        creation: creation,
                        simulationTick: candidateTick
                    )

            case let .deleteConstraint(deletion):
                let removedFixed = candidateFixedConstraints.removeValue(
                    forKey: deletion.constraintID
                )
                let removedLength = candidateLengthConstraints.removeValue(
                    forKey: deletion.constraintID
                )
                let removedNoCollide = candidateNoCollideConstraints.removeValue(
                    forKey: deletion.constraintID
                )
                guard removedFixed != nil || removedLength != nil ||
                    removedNoCollide != nil else {
                    throw Error.missingConstraint(deletion.constraintID)
                }
                candidateRetiredConstraintIDs.insert(deletion.constraintID)

            case let .simulate(simulate):
                if candidateHasSimulated, simulate.simulationTick <= candidateTick {
                    throw Error.simulationTickNotIncreasing(
                        previous: candidateTick,
                        current: simulate.simulationTick
                    )
                }
                candidateContacts = try simulateOneFixedStep(
                    bodies: &candidateBodies,
                    fixedConstraints: &candidateFixedConstraints,
                    lengthConstraints: &candidateLengthConstraints,
                    noCollideConstraints: &candidateNoCollideConstraints,
                    simulationTick: simulate.simulationTick
                )
                candidateTick = simulate.simulationTick
                candidateHasSimulated = true

            case let .query(query):
                queryResults.append(try executeQuery(
                    query,
                    commandSequence: command.sequence,
                    simulationTick: candidateTick,
                    bodies: candidateBodies
                ))
            }
        }

        let finalSequence = batch.commands.last?.sequence ??
            lastProcessedCommandSequence
        let snapshot = try makeSnapshot(
            bodies: candidateBodies,
            fixedConstraints: candidateFixedConstraints,
            lengthConstraints: candidateLengthConstraints,
            noCollideConstraints: candidateNoCollideConstraints,
            simulationTick: candidateTick,
            lastProcessedCommandSequence: finalSequence,
            queryResults: queryResults
        )

        bodies = candidateBodies
        fixedConstraints = candidateFixedConstraints
        lengthConstraints = candidateLengthConstraints
        noCollideConstraints = candidateNoCollideConstraints
        retiredConstraintIDs = candidateRetiredConstraintIDs
        simulationTick = candidateTick
        hasSimulated = candidateHasSimulated
        latestContacts = candidateContacts
        lastProcessedCommandSequence = finalSequence
        return snapshot
    }

    private func apply(
        _ mutation: SourcePhysicsBodyMutation,
        to body: inout BodyState
    ) throws {
        func requireMotionSupport() throws {
            guard body.supportsMotion else {
                throw Error.bodyDoesNotSupportMotion(body.bodyID)
            }
        }
        func requireEnabledDynamicMotion() throws {
            guard body.motionType == .dynamicBody else {
                throw Error.bodyDoesNotSupportMotion(body.bodyID)
            }
            guard body.isMotionEnabled else {
                throw Error.bodyMotionDisabled(body.bodyID)
            }
        }
        func checked(
            _ value: SourceVector3,
            operation: String
        ) throws -> SourceVector3 {
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
                throw Error.nonFiniteMutationResult(
                    bodyID: body.bodyID,
                    operation: operation
                )
            }
            return value
        }

        switch mutation {
        case .wake:
            try requireEnabledDynamicMotion()
            wake(&body)
        case .sleep:
            try requireEnabledDynamicMotion()
            body.isSleeping = true
            body.settledTicks = 0
            body.linearVelocity = .zero
            body.angularVelocity = .zero
            body.accumulatedCenterForce = .zero
            body.accumulatedCenterTorque = .zero
        case let .setMotionEnabled(enabled):
            try requireMotionSupport()
            body.isMotionEnabled = enabled
            body.settledTicks = 0
            if enabled {
                if body.motionType == .dynamicBody {
                    body.isSleeping = false
                }
            } else {
                body.isSleeping = true
                body.linearVelocity = .zero
                body.angularVelocity = .zero
                body.accumulatedCenterForce = .zero
                body.accumulatedCenterTorque = .zero
            }
        case let .setGravityEnabled(enabled):
            body.isGravityEnabled = enabled
            if body.isDynamic { wake(&body) }
        case let .setCollisionEnabled(enabled):
            body.isCollisionEnabled = enabled
            if body.isDynamic { wake(&body) }
        case let .setLinearVelocity(value):
            try requireMotionSupport()
            body.linearVelocity = value
            if body.isDynamic { wake(&body) }
        case let .addLinearVelocity(delta):
            try requireMotionSupport()
            body.linearVelocity = try checked(
                body.linearVelocity + delta,
                operation: "addLinearVelocity"
            )
            if body.isDynamic { wake(&body) }
        case let .setAngularVelocity(value):
            try requireMotionSupport()
            body.angularVelocity = value
            if body.isDynamic { wake(&body) }
        case let .addAngularVelocity(delta):
            try requireMotionSupport()
            body.angularVelocity = try checked(
                body.angularVelocity + delta,
                operation: "addAngularVelocity"
            )
            if body.isDynamic { wake(&body) }
        case let .applyCenterForce(force):
            try requireEnabledDynamicMotion()
            body.accumulatedCenterForce = try checked(
                body.accumulatedCenterForce + force,
                operation: "applyCenterForce"
            )
            wake(&body)
        case let .applyForceOffset(force, worldPosition):
            try requireEnabledDynamicMotion()
            let offset = try checked(
                worldPosition - body.transform.origin,
                operation: "applyForceOffsetWorldOffset"
            )
            let angularImpulse = try checked(
                offset.cross(force),
                operation: "applyForceOffsetAngularImpulse"
            )
            body.linearVelocity = try checked(
                body.linearVelocity + force /
                    body.massProperties.massKilograms,
                operation: "applyForceOffsetLinearVelocity"
            )
            // r x impulse / inertia is radians/second. Source publishes
            // angular velocity in degrees/second, matching the contact solver.
            let angularVelocityDelta = try checked(
                inverseInertiaMultiply(
                    body: body,
                    worldVector: angularImpulse
                ) * (180 / Float.pi),
                operation: "applyForceOffsetAngularVelocityDelta"
            )
            body.angularVelocity = try checked(
                body.angularVelocity + angularVelocityDelta,
                operation: "applyForceOffsetAngularVelocity"
            )
            wake(&body)
        case let .applyCenterImpulse(impulse):
            try requireEnabledDynamicMotion()
            body.linearVelocity = try checked(
                body.linearVelocity + impulse /
                    body.massProperties.massKilograms,
                operation: "applyCenterImpulse"
            )
            wake(&body)
        case let .applyTorqueCenter(torqueImpulse):
            try requireEnabledDynamicMotion()
            // Valve AngularImpulse is already expressed in HL/world axes as
            // kilograms-degrees/second. Applying inverse principal inertia
            // therefore yields the immediate degrees/second delta directly;
            // unlike contact torque, there is no radians conversion here.
            let angularVelocityDelta = inverseInertiaMultiply(
                body: body,
                worldVector: torqueImpulse
            )
            body.angularVelocity = try checked(
                body.angularVelocity + angularVelocityDelta,
                operation: "applyTorqueCenter"
            )
            wake(&body)
        case let .setDamping(linear, angular):
            // The command constructor has already validated this pair. Build
            // the value again here so a backend can never retain partially
            // applied coefficients if the public contract changes.
            body.damping = try SourcePhysicsDamping(
                linear: linear,
                angular: angular
            )
        case let .setMassKilograms(massKilograms):
            // The public boundary guarantees the authored VPhysics mass. This
            // proportional inertia update is deliberately a policy of this
            // deterministic backend, not a claim about undocumented
            // IPhysicsObject::SetMass internals. The immutable creation ratio
            // retains the shape-authored principal-inertia proportions and
            // avoids compounding round-off across repeated mass changes.
            let authored = body.creation.massProperties
            let scale = massKilograms / authored.massKilograms
            body.massProperties = try SourcePhysicsMassProperties(
                massKilograms: massKilograms,
                principalInertia: authored.principalInertia * scale
            )
        case let .setPosition(position, teleport):
            // IPhysicsObject exposes SetPosition on every body, independent
            // of static/dynamic or motion-enabled state. This backend has no
            // collision sweep inside an assignment, so GLua's `teleport=true`
            // temporary collision suppression has no additional solver work;
            // the bit is still retained by FIFO/replay. No undocumented wake,
            // velocity, or contact-cache side effect is fabricated here.
            _ = teleport
            body.transform.origin = position
        case let .setAngles(angles):
            // GLua SetAngles is the angle-only projection of the same
            // IPhysicsObject position boundary. Preserve every other state.
            body.transform.angles = angles
        }
    }

    private func simulateOneFixedStep(
        bodies: inout [SourcePhysicsBodyID: BodyState],
        fixedConstraints: inout [
            SourcePhysicsConstraintID: FixedConstraintState
        ],
        lengthConstraints: inout [
            SourcePhysicsConstraintID: LengthConstraintState
        ],
        noCollideConstraints: inout [
            SourcePhysicsConstraintID: NoCollideConstraintState
        ],
        simulationTick: UInt64
    ) throws -> [ContactSnapshot] {
        let delta = SourcePhysicsContract.fixedTimeStepSeconds
        let orderedIDs = bodies.keys.sorted(by: Self.bodyIDPrecedes)
        var continuousContacts: [Contact] = []

        for bodyID in orderedIDs {
            guard var body = bodies[bodyID] else { continue }
            switch body.motionType {
            case .staticBody:
                break
            case .kinematicBody:
                guard body.isMotionEnabled else { break }
                body.transform.origin += body.linearVelocity * delta
                body.transform.angles = integrating(
                    body.transform.angles,
                    angularVelocity: body.angularVelocity,
                    delta: delta
                )
            case .dynamicBody:
                guard body.isMotionEnabled, !body.isSleeping else { break }
                let startTransform = body.transform
                if body.accumulatedCenterForce != .zero {
                    let nextVelocity = body.linearVelocity +
                        body.accumulatedCenterForce *
                        (delta / body.massProperties.massKilograms)
                    guard nextVelocity.x.isFinite,
                          nextVelocity.y.isFinite,
                          nextVelocity.z.isFinite else {
                        throw Error.nonFiniteMutationResult(
                            bodyID: body.bodyID,
                            operation: "integrateCenterForce"
                        )
                    }
                    body.linearVelocity = nextVelocity
                    body.accumulatedCenterForce = .zero
                }
                if body.accumulatedCenterTorque != .zero {
                    let angularAccelerationRadians = inverseInertiaMultiply(
                        body: body,
                        worldVector: body.accumulatedCenterTorque
                    )
                    let nextAngularVelocity = body.angularVelocity +
                        angularAccelerationRadians *
                        (delta * 180 / Float.pi)
                    guard nextAngularVelocity.x.isFinite,
                          nextAngularVelocity.y.isFinite,
                          nextAngularVelocity.z.isFinite else {
                        throw Error.nonFiniteMutationResult(
                            bodyID: body.bodyID,
                            operation: "integrateForceOffsetTorque"
                        )
                    }
                    body.angularVelocity = nextAngularVelocity
                    body.accumulatedCenterTorque = .zero
                }
                if body.isGravityEnabled {
                    body.linearVelocity += configuration.gravity * delta
                }
                // VPhysics exposes independent speed and rotational damping
                // coefficients. This deterministic backend advances them at
                // the one representable fixed tick using a clamped explicit
                // decay, preventing a large valid coefficient from reversing
                // velocity direction.
                let linearScale = max(0, 1 - body.damping.linear * delta)
                let angularScale = max(0, 1 - body.damping.angular * delta)
                body.linearVelocity *= linearScale
                body.angularVelocity *= angularScale
                body.transform.origin += body.linearVelocity * delta
                body.transform.angles = integrating(
                    body.transform.angles,
                    angularVelocity: body.angularVelocity,
                    delta: delta
                )
                if body.isCollisionEnabled,
                   let contact = continuousStaticContact(
                       body: body,
                       startTransform: startTransform
                   ) {
                    body.transform.origin = contact.clampedOrigin
                    continuousContacts.append(contact.contact)
                }
            }
            body.simulationTick = simulationTick
            bodies[bodyID] = body
        }

        var supportedBodies = Set<SourcePhysicsBodyID>()
        var firstIterationContacts: [Contact] = []
        let excludedPairs = Set(noCollideConstraints.values.map {
            BodyPair(
                $0.creation.firstBodyID,
                $0.creation.secondBodyID
            )
        })
        for iteration in 0 ..< configuration.contactSolverIterations {
            try solveFixedConstraints(
                &fixedConstraints,
                bodies: &bodies,
                supportedBodies: &supportedBodies
            )
            try solveLengthConstraints(
                &lengthConstraints,
                bodies: &bodies,
                supportedBodies: &supportedBodies
            )
            var contacts = detectContacts(
                bodies: bodies,
                excludedPairs: excludedPairs
            )
            if iteration == 0, !continuousContacts.isEmpty {
                // A zero-thickness world triangle can be crossed between two
                // 0.015-second poses. Resolve the conservative convex-brush
                // sweep first, then retain ordinary SAT contacts for resting
                // and body/body behavior.
                contacts.insert(contentsOf: continuousContacts, at: 0)
            }
            if iteration == 0 { firstIterationContacts = contacts }
            guard !contacts.isEmpty else {
                if fixedConstraints.isEmpty, lengthConstraints.isEmpty { break }
                continue
            }
            for contact in contacts {
                try resolve(
                    contact,
                    bodies: &bodies,
                    supportedBodies: &supportedBodies
                )
            }
        }

        for constraintID in fixedConstraints.keys {
            fixedConstraints[constraintID]?.simulationTick = simulationTick
        }
        for constraintID in lengthConstraints.keys {
            lengthConstraints[constraintID]?.simulationTick = simulationTick
        }
        for constraintID in noCollideConstraints.keys {
            noCollideConstraints[constraintID]?.simulationTick = simulationTick
        }

        for bodyID in orderedIDs {
            guard var body = bodies[bodyID] else { continue }
            body.simulationTick = simulationTick
            updateSleep(
                body: &body,
                isSupported: supportedBodies.contains(bodyID)
            )
            bodies[bodyID] = body
        }

        return firstIterationContacts.map {
            ContactSnapshot(
                firstBodyID: $0.firstBodyID,
                secondBodyID: $0.secondBodyID,
                firstMaterialIndex: $0.firstMaterialIndex,
                secondMaterialIndex: $0.secondMaterialIndex,
                normal: $0.normal,
                position: $0.position,
                penetration: $0.penetration,
                simulationTick: simulationTick
            )
        }
    }

    /// Enforces VPhysics length limits in stable constraint-ID order. Flexible
    /// ropes only correct separation above `maximumLength`; rigid ropes also
    /// correct separation below the equal minimum. The implementation applies
    /// translation and normal relative-velocity correction by inverse mass.
    /// Positive break limits are rejected at creation rather than approximated.
    private func solveLengthConstraints(
        _ constraints: inout [
            SourcePhysicsConstraintID: LengthConstraintState
        ],
        bodies: inout [SourcePhysicsBodyID: BodyState],
        supportedBodies: inout Set<SourcePhysicsBodyID>
    ) throws {
        for constraintID in constraints.keys.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            guard let state = constraints[constraintID] else { continue }
            let creation = state.creation
            let referenceTransform = try constraintEndpointTransform(
                creation.reference,
                constraintID: constraintID,
                bodies: bodies
            )
            let attachedTransform = try constraintEndpointTransform(
                creation.attached,
                constraintID: constraintID,
                bodies: bodies
            )
            let referenceAnchor = referenceTransform.transformPointFromLocal(
                creation.reference.localAnchor
            )
            let attachedAnchor = attachedTransform.transformPointFromLocal(
                creation.attached.localAnchor
            )
            let delta = attachedAnchor - referenceAnchor
            let distanceSquared = delta.lengthSquared
            let distance = max(0, distanceSquared).squareRoot()
            let target: Float
            if distance > creation.maximumLength {
                target = creation.maximumLength
            } else if distance < creation.minimumLength {
                target = creation.minimumLength
            } else {
                continue
            }
            let normal = distance > 0
                ? delta / distance
                : state.initialReferenceToAttachedDirection
            let referenceInverseMass = constraintInverseMass(
                creation.reference,
                bodies: bodies
            )
            let attachedInverseMass = constraintInverseMass(
                creation.attached,
                bodies: bodies
            )
            let inverseMassSum = referenceInverseMass + attachedInverseMass
            guard inverseMassSum > 0 else { continue }
            let referenceShare = referenceInverseMass / inverseMassSum
            let attachedShare = attachedInverseMass / inverseMassSum
            let correction = normal * (distance - target)
            let relativeNormalVelocity = (
                constraintLinearVelocity(creation.attached, bodies: bodies) -
                    constraintLinearVelocity(creation.reference, bodies: bodies)
            ).dot(normal)

            if creation.reference.kind == .body,
               var reference = bodies[creation.reference.bodyID] {
                reference.transform.origin += correction * referenceShare
                reference.linearVelocity += normal *
                    (relativeNormalVelocity * referenceShare)
                guard reference.transform.origin.isSourcePhysicsFinite,
                      reference.linearVelocity.isSourcePhysicsFinite else {
                    throw Error.nonFiniteConstraintResult(constraintID)
                }
                if reference.isDynamic {
                    reference.settledTicks = 0
                    wake(&reference)
                }
                bodies[creation.reference.bodyID] = reference
            }
            if creation.attached.kind == .body,
               var attached = bodies[creation.attached.bodyID] {
                attached.transform.origin -= correction * attachedShare
                attached.linearVelocity -= normal *
                    (relativeNormalVelocity * attachedShare)
                guard attached.transform.origin.isSourcePhysicsFinite,
                      attached.linearVelocity.isSourcePhysicsFinite else {
                    throw Error.nonFiniteConstraintResult(constraintID)
                }
                if attached.isDynamic {
                    attached.settledTicks = 0
                    wake(&attached)
                }
                bodies[creation.attached.bodyID] = attached
            }
            if referenceInverseMass == 0, creation.attached.kind == .body {
                supportedBodies.insert(creation.attached.bodyID)
            }
            if attachedInverseMass == 0, creation.reference.kind == .body {
                supportedBodies.insert(creation.reference.bodyID)
            }
        }
    }

    private func constraintEndpointTransform(
        _ endpoint: SourcePhysicsLengthConstraintEndpoint,
        constraintID: SourcePhysicsConstraintID,
        bodies: [SourcePhysicsBodyID: BodyState]
    ) throws -> SourceEntityTransform {
        switch endpoint.kind {
        case .body:
            guard let body = bodies[endpoint.bodyID] else {
                throw Error.constraintBodyMissing(
                    constraintID: constraintID,
                    bodyID: endpoint.bodyID
                )
            }
            return body.transform
        case .staticWorld:
            guard let scene = staticCollisionScene,
                  scene.bodyID == endpoint.bodyID else {
                throw Error.staticWorldConstraintEndpointUnavailable(
                    constraintID: constraintID,
                    bodyID: endpoint.bodyID
                )
            }
            return scene.transform
        }
    }

    private func constraintInverseMass(
        _ endpoint: SourcePhysicsLengthConstraintEndpoint,
        bodies: [SourcePhysicsBodyID: BodyState]
    ) -> Float {
        guard endpoint.kind == .body, let body = bodies[endpoint.bodyID] else {
            return 0
        }
        return inverseMass(body)
    }

    private func constraintLinearVelocity(
        _ endpoint: SourcePhysicsLengthConstraintEndpoint,
        bodies: [SourcePhysicsBodyID: BodyState]
    ) -> SourceVector3 {
        guard endpoint.kind == .body, let body = bodies[endpoint.bodyID] else {
            return .zero
        }
        return body.linearVelocity
    }

    /// Solves the six fixed degrees of freedom in stable constraint-ID order.
    /// Dynamic endpoints share correction by inverse mass; static,
    /// kinematic, and motion-disabled endpoints have zero inverse mass and
    /// therefore act as the fixed reference for the other body. This is the
    /// deterministic backend's minimal fixed-joint solver, not a claim about
    /// undocumented VPhysics break thresholds or motor behavior.
    private func solveFixedConstraints(
        _ constraints: inout [
            SourcePhysicsConstraintID: FixedConstraintState
        ],
        bodies: inout [SourcePhysicsBodyID: BodyState],
        supportedBodies: inout Set<SourcePhysicsBodyID>
    ) throws {
        let orderedConstraintIDs = constraints.keys.sorted {
            $0.rawValue < $1.rawValue
        }
        for constraintID in orderedConstraintIDs {
            guard let constraint = constraints[constraintID] else { continue }
            let referenceID = constraint.creation.referenceBodyID
            let attachedID = constraint.creation.attachedBodyID
            guard var reference = bodies[referenceID] else {
                throw Error.constraintBodyMissing(
                    constraintID: constraintID,
                    bodyID: referenceID
                )
            }
            guard var attached = bodies[attachedID] else {
                throw Error.constraintBodyMissing(
                    constraintID: constraintID,
                    bodyID: attachedID
                )
            }

            let referenceInverseMass = inverseMass(reference)
            let attachedInverseMass = inverseMass(attached)
            let inverseMassSum = referenceInverseMass + attachedInverseMass
            guard inverseMassSum > 0 else { continue }
            let referenceShare = referenceInverseMass / inverseMassSum
            let attachedShare = attachedInverseMass / inverseMassSum

            let originalReference = reference
            let originalAttached = attached
            let desiredReference = constraint.relativePose
                .desiredReferenceTransform(attached: attached.transform)
            let desiredAttached = constraint.relativePose
                .desiredAttachedTransform(reference: reference.transform)

            let referenceRotation = SourcePhysicsConstraintQuaternion(
                reference.transform.angles
            ).interpolated(
                toward: SourcePhysicsConstraintQuaternion(
                    desiredReference.angles
                ),
                fraction: referenceShare
            )
            let attachedRotation = SourcePhysicsConstraintQuaternion(
                attached.transform.angles
            ).interpolated(
                toward: SourcePhysicsConstraintQuaternion(
                    desiredAttached.angles
                ),
                fraction: attachedShare
            )
            reference.transform.angles = referenceRotation.sourceAngles
            attached.transform.angles = attachedRotation.sourceAngles

            let desiredAttachedOrigin = reference.transform
                .transformPointFromLocal(
                    constraint.relativePose.attachedOriginInReference
                )
            let positionError = attached.transform.origin -
                desiredAttachedOrigin
            reference.transform.origin += positionError * referenceShare
            attached.transform.origin -= positionError * attachedShare

            let angularVelocityError = attached.angularVelocity -
                reference.angularVelocity
            reference.angularVelocity += angularVelocityError * referenceShare
            attached.angularVelocity -= angularVelocityError * attachedShare

            let offset = attached.transform.origin - reference.transform.origin
            let angularRadians = reference.angularVelocity *
                (Float.pi / 180)
            let linearVelocityError = attached.linearVelocity -
                reference.linearVelocity - angularRadians.cross(offset)
            reference.linearVelocity += linearVelocityError * referenceShare
            attached.linearVelocity -= linearVelocityError * attachedShare

            guard reference.transform.origin.isSourcePhysicsFinite,
                  reference.transform.angles.pitch.isFinite,
                  reference.transform.angles.yaw.isFinite,
                  reference.transform.angles.roll.isFinite,
                  reference.linearVelocity.isSourcePhysicsFinite,
                  reference.angularVelocity.isSourcePhysicsFinite,
                  attached.transform.origin.isSourcePhysicsFinite,
                  attached.transform.angles.pitch.isFinite,
                  attached.transform.angles.yaw.isFinite,
                  attached.transform.angles.roll.isFinite,
                  attached.linearVelocity.isSourcePhysicsFinite,
                  attached.angularVelocity.isSourcePhysicsFinite else {
                throw Error.nonFiniteConstraintResult(constraintID)
            }

            if reference != originalReference, reference.isDynamic {
                reference.settledTicks = 0
                wake(&reference)
            }
            if attached != originalAttached, attached.isDynamic {
                attached.settledTicks = 0
                wake(&attached)
            }
            if referenceInverseMass == 0, attached.isDynamic {
                supportedBodies.insert(attachedID)
            }
            if attachedInverseMass == 0, reference.isDynamic {
                supportedBodies.insert(referenceID)
            }
            bodies[referenceID] = reference
            bodies[attachedID] = attached
        }
    }

    private struct ContinuousStaticContact {
        let clampedOrigin: SourceVector3
        let contact: Contact
    }

    /// Performs conservative continuous collision against the immutable BSP
    /// brush scene. The moving body's exact validated convex geometry supplies
    /// the swept AABB; no fallback dimensions are introduced here.
    private func continuousStaticContact(
        body: BodyState,
        startTransform: SourceEntityTransform
    ) -> ContinuousStaticContact? {
        guard let scene = staticCollisionScene,
              let worldShape = staticCollisionWorldShape else { return nil }
        let start = startTransform.origin
        let end = body.transform.origin
        guard start != end else { return nil }

        let startShape = makeWorldShape(
            shape: body.creation.shape,
            transform: startTransform
        )
        let minimums = startShape.bounds.minimums - start
        let maximums = startShape.bounds.maximums - start
        let sweepBounds = motionBounds(
            start: start,
            end: end,
            minimums: minimums,
            maximums: maximums
        )
        prepareStaticCandidates(overlapping: sweepBounds)
        var best: ConvexSweepHit?
        for partIndex in staticCandidatePartIndices {
            let part = worldShape.parts[partIndex]
            guard part.bounds.intersects(sweepBounds) else { continue }
            let hit: ConvexSweepHit?
            switch part.staticMeshTopology {
            case .closedConvexVolume:
                hit = sweptHullConvexPartHit(
                    start: start,
                    end: end,
                    minimums: minimums,
                    maximums: maximums,
                    part: part
                )
            case .openTriangleMesh:
                hit = sweptHullOpenTrianglePartHit(
                    start: start,
                    end: end,
                    minimums: minimums,
                    maximums: maximums,
                    part: part
                )
            }
            guard let hit, !hit.startedSolid,
               best == nil || hit.fraction < best!.fraction else { continue }
            best = hit
        }
        guard let hit = best, hit.normal.lengthSquared > 0 else { return nil }

        let clampedOrigin = start + (end - start) * hit.fraction
        var clampedBody = body
        clampedBody.transform.origin = clampedOrigin
        let clampedShape = makeWorldShape(body: clampedBody)
        let contactPoint = support(
            clampedShape.parts.flatMap(\.vertices),
            direction: -hit.normal
        )
        return ContinuousStaticContact(
            clampedOrigin: clampedOrigin,
            contact: Contact(
                firstBodyID: scene.bodyID,
                secondBodyID: body.bodyID,
                firstMaterialIndex: hit.materialIndex,
                secondMaterialIndex: body.creation.materialIndex,
                normal: hit.normal,
                position: contactPoint,
                penetration: 0
            )
        )
    }

    private func detectContacts(
        bodies: [SourcePhysicsBodyID: BodyState],
        excludedPairs: Set<BodyPair> = []
    ) -> [Contact] {
        let orderedIDs = bodies.keys.sorted(by: Self.bodyIDPrecedes)
        var shapes: [SourcePhysicsBodyID: WorldShape] = [:]
        shapes.reserveCapacity(orderedIDs.count)
        var broadphaseEntries: [SourcePhysicsDynamicBroadphaseEntry] = []
        broadphaseEntries.reserveCapacity(orderedIDs.count)
        for (sourceOrder, bodyID) in orderedIDs.enumerated() {
            guard let body = bodies[bodyID], body.isCollisionEnabled else {
                continue
            }
            let shape = makeWorldShape(body: body)
            shapes[bodyID] = shape
            broadphaseEntries.append(SourcePhysicsDynamicBroadphaseEntry(
                sourceOrder: sourceOrder,
                minimums: shape.bounds.minimums,
                maximums: shape.bounds.maximums,
                isMovable: body.isMovable,
                isDynamic: body.isDynamic
            ))
        }

        let broadphase = SourcePhysicsDynamicSweepAndPrune.candidates(
            from: broadphaseEntries
        )
        let narrowphasePairs = broadphase.candidatePairs.filter { pair in
            let firstID = orderedIDs[pair.firstSourceOrder]
            let secondID = orderedIDs[pair.secondSourceOrder]
            return !excludedPairs.contains(BodyPair(firstID, secondID))
        }
        latestDynamicBroadphaseDiagnostics = DynamicBroadphaseDiagnostics(
            totalBodyCount: orderedIDs.count,
            collisionEnabledBodyCount: broadphaseEntries.count,
            fullPairCount: broadphase.fullPairCount,
            sweepCandidatePairCount: broadphase.sweepCandidatePairCount,
            narrowphaseCandidatePairCount: narrowphasePairs.count
        )

        var contacts: [Contact] = []
        contacts.reserveCapacity(narrowphasePairs.count)
        for pair in narrowphasePairs {
            let firstID = orderedIDs[pair.firstSourceOrder]
            let secondID = orderedIDs[pair.secondSourceOrder]
            guard let first = bodies[firstID],
                  first.isCollisionEnabled,
                  let firstShape = shapes[firstID],
                  let second = bodies[secondID],
                  second.isCollisionEnabled,
                  let secondShape = shapes[secondID],
                  first.isMovable || second.isMovable,
                  first.isDynamic || second.isDynamic,
                  firstShape.bounds.intersects(secondShape.bounds),
                  let contact = contact(
                      firstID: firstID,
                      firstMaterialIndex: first.creation.materialIndex,
                      firstShape: firstShape,
                      secondID: secondID,
                      secondMaterialIndex: second.creation.materialIndex,
                      secondShape: secondShape
                  ) else { continue }
            contacts.append(contact)
        }

        if let scene = staticCollisionScene,
           let sceneShape = staticCollisionWorldShape {
            for bodyID in orderedIDs {
                guard let body = bodies[bodyID],
                      body.isDynamic,
                      body.isCollisionEnabled,
                      let bodyShape = shapes[bodyID],
                      sceneShape.bounds.intersects(bodyShape.bounds),
                      let sceneContact = staticSceneContact(
                          sceneID: scene.bodyID,
                          sceneShape: sceneShape,
                          bodyID: bodyID,
                          bodyMaterialIndex: body.creation.materialIndex,
                          bodyShape: bodyShape
                      ) else { continue }
                contacts.append(sceneContact)
            }
        }
        return contacts
    }

    private func staticSceneContact(
        sceneID: SourcePhysicsBodyID,
        sceneShape: WorldShape,
        bodyID: SourcePhysicsBodyID,
        bodyMaterialIndex: Int,
        bodyShape: WorldShape
    ) -> Contact? {
        // Dynamic PHY bodies are independently attested convex parts. A
        // triangle-mesh dynamic body had no world contact in the pre-BVH path
        // and remains unsupported here rather than changing that contract.
        guard bodyShape.topology == .convexParts else { return nil }
        prepareStaticCandidates(overlapping: bodyShape.bounds)
        var best: Contact?
        for scenePartIndex in staticCandidatePartIndices {
            let scenePart = sceneShape.parts[scenePartIndex]
            for bodyPart in bodyShape.parts
            where scenePart.bounds.intersects(bodyPart.bounds) {
                for triangle in scenePart.triangles {
                    if let reversed = convexTriangleContact(
                        firstID: bodyID,
                        firstMaterialIndex: bodyMaterialIndex,
                        convex: bodyPart,
                        secondID: sceneID,
                        secondMaterialIndex: triangle.materialIndex,
                        triangle: triangle
                    ) {
                        chooseDeeper(Contact(
                            firstBodyID: sceneID,
                            secondBodyID: bodyID,
                            firstMaterialIndex: triangle.materialIndex,
                            secondMaterialIndex: bodyMaterialIndex,
                            normal: -reversed.normal,
                            position: reversed.position,
                            penetration: reversed.penetration
                        ), into: &best)
                    }
                }
            }
        }
        return best
    }

    private func contact(
        firstID: SourcePhysicsBodyID,
        firstMaterialIndex: Int,
        firstShape: WorldShape,
        secondID: SourcePhysicsBodyID,
        secondMaterialIndex: Int,
        secondShape: WorldShape
    ) -> Contact? {
        var best: Contact?

        switch (firstShape.topology, secondShape.topology) {
        case (.convexParts, .convexParts):
            for firstPart in firstShape.parts {
                for secondPart in secondShape.parts
                where firstPart.bounds.intersects(secondPart.bounds) {
                    chooseDeeper(
                        convexContact(
                            firstID: firstID,
                            firstMaterialIndex: firstMaterialIndex,
                            firstPart: firstPart,
                            secondID: secondID,
                            secondMaterialIndex: secondMaterialIndex,
                            secondPart: secondPart
                        ),
                        into: &best
                    )
                }
            }

        case (.convexParts, .triangleMesh):
            for firstPart in firstShape.parts {
                for secondPart in secondShape.parts
                where firstPart.bounds.intersects(secondPart.bounds) {
                    for triangle in secondPart.triangles {
                        chooseDeeper(
                            convexTriangleContact(
                                firstID: firstID,
                                firstMaterialIndex: firstMaterialIndex,
                                convex: firstPart,
                                secondID: secondID,
                                secondMaterialIndex: secondMaterialIndex,
                                triangle: triangle
                            ),
                            into: &best
                        )
                    }
                }
            }

        case (.triangleMesh, .convexParts):
            for firstPart in firstShape.parts {
                for secondPart in secondShape.parts
                where firstPart.bounds.intersects(secondPart.bounds) {
                    for triangle in firstPart.triangles {
                        if let reversed = convexTriangleContact(
                            firstID: secondID,
                            firstMaterialIndex: secondMaterialIndex,
                            convex: secondPart,
                            secondID: firstID,
                            secondMaterialIndex: firstMaterialIndex,
                            triangle: triangle
                        ) {
                            chooseDeeper(Contact(
                                firstBodyID: firstID,
                                secondBodyID: secondID,
                                firstMaterialIndex: firstMaterialIndex,
                                secondMaterialIndex: secondMaterialIndex,
                                normal: -reversed.normal,
                                position: reversed.position,
                                penetration: reversed.penetration
                            ), into: &best)
                        }
                    }
                }
            }

        case (.triangleMesh, .triangleMesh):
            // Triangle meshes are static-world geometry at this backend
            // boundary. Two such surfaces have no volume to resolve.
            break
        }
        return best
    }

    private func chooseDeeper(_ candidate: Contact?, into best: inout Contact?) {
        guard let candidate else { return }
        if let current = best, current.penetration >= candidate.penetration {
            return
        }
        best = candidate
    }

    private func convexContact(
        firstID: SourcePhysicsBodyID,
        firstMaterialIndex: Int,
        firstPart: WorldPart,
        secondID: SourcePhysicsBodyID,
        secondMaterialIndex: Int,
        secondPart: WorldPart
    ) -> Contact? {
        var axes = firstPart.faceNormals + secondPart.faceNormals
        axes.reserveCapacity(
            axes.count + firstPart.edges.count * secondPart.edges.count
        )
        for firstEdge in firstPart.edges {
            for secondEdge in secondPart.edges {
                axes.append(firstEdge.cross(secondEdge))
            }
        }
        return separatingAxisContact(
            firstID: firstID,
            firstMaterialIndex: firstMaterialIndex,
            firstVertices: firstPart.vertices,
            firstCenter: firstPart.center,
            secondID: secondID,
            secondMaterialIndex: secondMaterialIndex,
            secondVertices: secondPart.vertices,
            secondCenter: secondPart.center,
            axes: axes
        )
    }

    private func convexTriangleContact(
        firstID: SourcePhysicsBodyID,
        firstMaterialIndex: Int?,
        convex: WorldPart,
        secondID: SourcePhysicsBodyID,
        secondMaterialIndex: Int?,
        triangle: WorldTriangle
    ) -> Contact? {
        var axes = convex.faceNormals
        axes.append(triangle.normal)
        axes.reserveCapacity(
            axes.count + convex.edges.count * triangle.edges.count
        )
        for convexEdge in convex.edges {
            for triangleEdge in triangle.edges {
                axes.append(convexEdge.cross(triangleEdge))
            }
        }
        guard var contact = separatingAxisContact(
            firstID: firstID,
            firstMaterialIndex: firstMaterialIndex,
            firstVertices: convex.vertices,
            firstCenter: convex.center,
            secondID: secondID,
            secondMaterialIndex: secondMaterialIndex,
            secondVertices: triangle.vertices,
            secondCenter: triangle.center,
            axes: axes
        ) else { return nil }
        let convexSupport = support(
            convex.vertices,
            direction: contact.normal
        )
        // `triangle` is one immutable world facet (a brush face or an open
        // displacement cell). Its centroid can be far from a small prop and a
        // triangulation diagonal is not a physical contact lever arm. Use the
        // center of the prop's exact support feature; this is invariant to how
        // the same surface was triangulated and prevents artificial torque on
        // a flat landing.
        contact.position = convexSupport
        return contact
    }

    private func separatingAxisContact(
        firstID: SourcePhysicsBodyID,
        firstMaterialIndex: Int?,
        firstVertices: [SourceVector3],
        firstCenter: SourceVector3,
        secondID: SourcePhysicsBodyID,
        secondMaterialIndex: Int?,
        secondVertices: [SourceVector3],
        secondCenter: SourceVector3,
        axes: [SourceVector3]
    ) -> Contact? {
        var minimumPenetration = Float.greatestFiniteMagnitude
        var minimumAxis = SourceVector3.zero
        var foundAxis = false

        for rawAxis in axes {
            guard rawAxis.lengthSquared > 1e-12 else { continue }
            let axis = rawAxis.normalizedOrZero
            let firstProjection = project(firstVertices, onto: axis)
            let secondProjection = project(secondVertices, onto: axis)
            guard firstProjection.maximum >= secondProjection.minimum,
                  secondProjection.maximum >= firstProjection.minimum else {
                return nil
            }

            // Unlike the common interval-overlap expression, this preserves
            // penetration when one interval (a world triangle plane) has zero
            // thickness and is contained by the other interval.
            let penetration = min(
                firstProjection.maximum - secondProjection.minimum,
                secondProjection.maximum - firstProjection.minimum
            )
            if penetration < minimumPenetration {
                minimumPenetration = penetration
                minimumAxis = axis
                foundAxis = true
            }
        }
        guard foundAxis, minimumPenetration.isFinite else { return nil }
        if (secondCenter - firstCenter).dot(minimumAxis) < 0 {
            minimumAxis = -minimumAxis
        }
        let firstSupport = support(firstVertices, direction: minimumAxis)
        let secondSupport = support(secondVertices, direction: -minimumAxis)
        return Contact(
            firstBodyID: firstID,
            secondBodyID: secondID,
            firstMaterialIndex: firstMaterialIndex,
            secondMaterialIndex: secondMaterialIndex,
            normal: minimumAxis,
            position: (firstSupport + secondSupport) * 0.5,
            penetration: max(0, minimumPenetration)
        )
    }

    private func resolve(
        _ contact: Contact,
        bodies: inout [SourcePhysicsBodyID: BodyState],
        supportedBodies: inout Set<SourcePhysicsBodyID>
    ) throws {
        var first = bodies[contact.firstBodyID]
        var second = bodies[contact.secondBodyID]
        let sceneIsFirst = staticCollisionScene?.bodyID == contact.firstBodyID
        let sceneIsSecond = staticCollisionScene?.bodyID == contact.secondBodyID
        guard first != nil || sceneIsFirst,
              second != nil || sceneIsSecond else { return }

        let materialCoefficients = try contactMaterialCoefficients(
            for: contact
        )

        let firstInverseMass = first.map(inverseMass) ?? 0
        let secondInverseMass = second.map(inverseMass) ?? 0
        let inverseMassSum = firstInverseMass + secondInverseMass
        guard inverseMassSum > 0 else { return }

        let firstOrigin = first?.transform.origin ??
            staticCollisionScene!.transform.origin
        let secondOrigin = second?.transform.origin ??
            staticCollisionScene!.transform.origin
        let firstOffset = contact.position - firstOrigin
        let secondOffset = contact.position - secondOrigin
        let firstPointVelocity = first.map {
            pointVelocity($0, offset: firstOffset)
        } ?? .zero
        let secondPointVelocity = second.map {
            pointVelocity($0, offset: secondOffset)
        } ?? .zero
        let relativeNormalSpeed =
            (secondPointVelocity - firstPointVelocity).dot(contact.normal)

        if relativeNormalSpeed < -configuration.impactWakeSpeed {
            if var value = first {
                wake(&value)
                first = value
            }
            if var value = second {
                wake(&value)
                second = value
            }
        }

        let correctionDistance = max(
            0,
            contact.penetration - configuration.contactSlop
        )
        if correctionDistance > 0 {
            let correction = contact.normal *
                (correctionDistance / inverseMassSum)
            if firstInverseMass > 0, var value = first {
                value.transform.origin -= correction * firstInverseMass
                first = value
            }
            if secondInverseMass > 0, var value = second {
                value.transform.origin += correction * secondInverseMass
                second = value
            }
        }

        var appliedNormalImpulseMagnitude: Float = 0
        if relativeNormalSpeed < 0 {
            let firstAngularTerm = first.map {
                angularEffectiveMass(
                    body: $0,
                    offset: firstOffset,
                    normal: contact.normal
                )
            } ?? 0
            let secondAngularTerm = second.map {
                angularEffectiveMass(
                    body: $0,
                    offset: secondOffset,
                    normal: contact.normal
                )
            } ?? 0
            let denominator = inverseMassSum +
                firstAngularTerm + secondAngularTerm
            if denominator > 0, denominator.isFinite {
                let magnitude = -(1 + materialCoefficients.restitution) *
                    relativeNormalSpeed / denominator
                guard magnitude.isFinite else {
                    throw Error.nonFiniteContactImpulse(
                        firstBodyID: contact.firstBodyID,
                        secondBodyID: contact.secondBodyID
                    )
                }
                let impulse = contact.normal * magnitude
                if var value = first {
                    applyImpulse(-impulse, at: firstOffset, to: &value)
                    first = value
                }
                if var value = second {
                    applyImpulse(impulse, at: secondOffset, to: &value)
                    second = value
                }
                appliedNormalImpulseMagnitude = magnitude
            }
        }

        if appliedNormalImpulseMagnitude > 0 {
            let updatedFirstOrigin = first?.transform.origin ??
                staticCollisionScene!.transform.origin
            let updatedSecondOrigin = second?.transform.origin ??
                staticCollisionScene!.transform.origin
            let updatedFirstOffset = contact.position - updatedFirstOrigin
            let updatedSecondOffset = contact.position - updatedSecondOrigin
            let updatedFirstPointVelocity = first.map {
                pointVelocity($0, offset: updatedFirstOffset)
            } ?? .zero
            let updatedSecondPointVelocity = second.map {
                pointVelocity($0, offset: updatedSecondOffset)
            } ?? .zero
            let relativeVelocity = updatedSecondPointVelocity -
                updatedFirstPointVelocity
            let tangentVelocity = relativeVelocity - contact.normal *
                relativeVelocity.dot(contact.normal)
            let tangentSpeedSquared = tangentVelocity.lengthSquared
            if tangentSpeedSquared > 1e-12 {
                let tangent = tangentVelocity.normalizedOrZero
                let firstAngularTerm = first.map {
                    angularEffectiveMass(
                        body: $0,
                        offset: updatedFirstOffset,
                        normal: tangent
                    )
                } ?? 0
                let secondAngularTerm = second.map {
                    angularEffectiveMass(
                        body: $0,
                        offset: updatedSecondOffset,
                        normal: tangent
                    )
                } ?? 0
                let denominator = inverseMassSum +
                    firstAngularTerm + secondAngularTerm
                if denominator > 0, denominator.isFinite {
                    let cancellationMagnitude = -relativeVelocity.dot(
                        tangent
                    ) / denominator
                    let staticLimit = materialCoefficients.staticFriction *
                        appliedNormalImpulseMagnitude
                    let magnitude: Float
                    if abs(cancellationMagnitude) <= staticLimit {
                        magnitude = cancellationMagnitude
                    } else {
                        magnitude = -materialCoefficients.dynamicFriction *
                            appliedNormalImpulseMagnitude
                    }
                    guard magnitude.isFinite else {
                        throw Error.nonFiniteContactImpulse(
                            firstBodyID: contact.firstBodyID,
                            secondBodyID: contact.secondBodyID
                        )
                    }
                    let impulse = tangent * magnitude
                    if var value = first {
                        applyImpulse(
                            -impulse,
                            at: updatedFirstOffset,
                            to: &value
                        )
                        first = value
                    }
                    if var value = second {
                        applyImpulse(
                            impulse,
                            at: updatedSecondOffset,
                            to: &value
                        )
                        second = value
                    }
                }
            }
        }

        if contact.normal.z > 0.5, let second, second.isDynamic {
            supportedBodies.insert(second.bodyID)
        }
        if contact.normal.z < -0.5, let first, first.isDynamic {
            supportedBodies.insert(first.bodyID)
        }
        if let first { bodies[contact.firstBodyID] = first }
        if let second { bodies[contact.secondBodyID] = second }
    }

    private func contactMaterialCoefficients(
        for contact: Contact
    ) throws -> SourcePhysicsContactMaterialCoefficients {
        guard let firstMaterialIndex = contact.firstMaterialIndex else {
            throw SourcePhysicsMaterialTableError.missingContactMaterialIndex(
                bodyID: contact.firstBodyID
            )
        }
        guard let secondMaterialIndex = contact.secondMaterialIndex else {
            throw SourcePhysicsMaterialTableError.missingContactMaterialIndex(
                bodyID: contact.secondBodyID
            )
        }
        return try materialTable.coefficients(
            firstMaterialIndex: firstMaterialIndex,
            secondMaterialIndex: secondMaterialIndex
        )
    }

    private func inverseMass(_ body: BodyState) -> Float {
        guard body.isDynamic else { return 0 }
        return 1 / body.massProperties.massKilograms
    }

    private func pointVelocity(
        _ body: BodyState,
        offset: SourceVector3
    ) -> SourceVector3 {
        let radiansPerSecond = body.angularVelocity * (Float.pi / 180)
        return body.linearVelocity + radiansPerSecond.cross(offset)
    }

    private func angularEffectiveMass(
        body: BodyState,
        offset: SourceVector3,
        normal: SourceVector3
    ) -> Float {
        guard body.isDynamic else { return 0 }
        let torqueAxis = offset.cross(normal)
        let inverseAngular = inverseInertiaMultiply(
            body: body,
            worldVector: torqueAxis
        )
        return inverseAngular.cross(offset).dot(normal)
    }

    private func applyImpulse(
        _ impulse: SourceVector3,
        at offset: SourceVector3,
        to body: inout BodyState
    ) {
        guard body.isDynamic else { return }
        body.linearVelocity += impulse * inverseMass(body)
        let angularDeltaRadians = inverseInertiaMultiply(
            body: body,
            worldVector: offset.cross(impulse)
        )
        body.angularVelocity += angularDeltaRadians * (180 / Float.pi)
        if impulse.lengthSquared > 0 { wake(&body) }
    }

    private func inverseInertiaMultiply(
        body: BodyState,
        worldVector: SourceVector3
    ) -> SourceVector3 {
        let basis = body.transform.angles.sourceBasis
        let localX = basis.forward
        let localY = -basis.right
        let localZ = basis.up
        let local = SourceVector3(
            worldVector.dot(localX),
            worldVector.dot(localY),
            worldVector.dot(localZ)
        )
        let inertia = body.massProperties.principalInertia
        let scaled = SourceVector3(
            local.x / inertia.x,
            local.y / inertia.y,
            local.z / inertia.z
        )
        return localX * scaled.x + localY * scaled.y + localZ * scaled.z
    }

    private func wake(_ body: inout BodyState) {
        guard body.isDynamic, body.isSleeping else { return }
        body.isSleeping = false
        body.settledTicks = 0
    }

    private func updateSleep(body: inout BodyState, isSupported: Bool) {
        guard body.isDynamic, !body.isSleeping else { return }
        let linearLimitSquared = configuration.sleepLinearSpeed *
            configuration.sleepLinearSpeed
        let angularLimitSquared = configuration.sleepAngularSpeedDegrees *
            configuration.sleepAngularSpeedDegrees
        let maySettle = isSupported || !body.isGravityEnabled
        if maySettle,
           body.linearVelocity.lengthSquared <= linearLimitSquared,
           body.angularVelocity.lengthSquared <= angularLimitSquared {
            if body.settledTicks < UInt16.max {
                body.settledTicks += 1
            }
            if body.settledTicks >= configuration.sleepAfterSettledTicks {
                body.isSleeping = true
                body.linearVelocity = .zero
                body.angularVelocity = .zero
            }
        } else {
            body.settledTicks = 0
        }
    }

    private func executeQuery(
        _ query: SourcePhysicsQueryCommand,
        commandSequence: UInt64,
        simulationTick: UInt64,
        bodies: [SourcePhysicsBodyID: BodyState]
    ) throws -> SourcePhysicsQueryResultSnapshot {
        guard query.contentsMask != 0 else {
            return SourcePhysicsQueryResultSnapshot(
                queryID: query.queryID,
                commandSequence: commandSequence,
                simulationTick: simulationTick,
                hit: nil
            )
        }
        let ignored = Set(query.ignoredEntities)
        let eligible = bodies.values
            .filter {
                $0.isCollisionEnabled &&
                    !ignored.contains($0.bodyID.entityIdentity) &&
                    queryIncludes($0, scope: query.scope)
            }
            .sorted { Self.bodyIDPrecedes($0.bodyID, $1.bodyID) }

        var best: SourcePhysicsQueryHitSnapshot?
        for body in eligible {
            let hit: SourcePhysicsQueryHitSnapshot?
            switch query.geometry {
            case let .lineSegment(start, end):
                hit = try lineHit(start: start, end: end, body: body)
            case let .sweptHull(start, end, minimums, maximums):
                hit = try sweptHullHit(
                    start: start,
                    end: end,
                    minimums: minimums,
                    maximums: maximums,
                    body: body
                )
            }
            if let hit,
               best == nil || hit.fraction < best!.fraction {
                best = hit
            }
        }
        if let scene = staticCollisionScene,
           query.scope != .movingOnly,
           query.scope != .triggersOnly,
           !ignored.contains(scene.bodyID.entityIdentity),
           query.contentsMask & scene.contents.rawValue != 0 {
            let hit: SourcePhysicsQueryHitSnapshot?
            switch query.geometry {
            case let .lineSegment(start, end):
                hit = try lineHitStaticScene(
                    start: start,
                    end: end,
                    scene: scene
                )
            case let .sweptHull(start, end, minimums, maximums):
                hit = try sweptHullStaticSceneHit(
                    start: start,
                    end: end,
                    minimums: minimums,
                    maximums: maximums,
                    scene: scene
                )
            }
            if let hit, best == nil || hit.fraction < best!.fraction {
                best = hit
            }
        }
        return SourcePhysicsQueryResultSnapshot(
            queryID: query.queryID,
            commandSequence: commandSequence,
            simulationTick: simulationTick,
            hit: best
        )
    }

    private func queryIncludes(
        _ body: BodyState,
        scope: SourcePhysicsQueryScope
    ) -> Bool {
        switch scope {
        case .everything, .staticAndMoving:
            return true
        case .staticOnly:
            return body.motionType == .staticBody
        case .movingOnly:
            return body.motionType != .staticBody
        case .triggersOnly:
            // The backend-neutral body contract has no trigger-body flag.
            return false
        }
    }

    private func lineHit(
        start: SourceVector3,
        end: SourceVector3,
        body: BodyState
    ) throws -> SourcePhysicsQueryHitSnapshot? {
        try lineHit(
            start: start,
            end: end,
            bodyID: body.bodyID,
            shape: body.creation.shape,
            transform: body.transform
        )
    }

    private func lineHit(
        start: SourceVector3,
        end: SourceVector3,
        bodyID: SourcePhysicsBodyID,
        shape: SourcePhysicsShapeSnapshot,
        transform: SourceEntityTransform
    ) throws -> SourcePhysicsQueryHitSnapshot? {
        try lineHit(
            start: start,
            end: end,
            bodyID: bodyID,
            worldShape: makeWorldShape(shape: shape, transform: transform)
        )
    }

    private func lineHit(
        start: SourceVector3,
        end: SourceVector3,
        bodyID: SourcePhysicsBodyID,
        worldShape: WorldShape
    ) throws -> SourcePhysicsQueryHitSnapshot? {
        let startInside = worldShape.topology == .convexParts &&
            worldShape.parts.contains { pointInsideConvex(start, part: $0) }
        if startInside {
            let endInside = worldShape.parts.contains {
                pointInsideConvex(end, part: $0)
            }
            return try SourcePhysicsQueryHitSnapshot(
                bodyID: bodyID,
                fraction: 0,
                position: start,
                normal: .zero,
                materialIndex: nil,
                startedSolid: true,
                allSolid: endInside
            )
        }

        let direction = end - start
        var bestFraction: Float?
        var bestNormal = SourceVector3.zero
        var bestMaterial: Int?
        for part in worldShape.parts {
            for triangle in part.triangles {
                guard let fraction = segmentTriangleFraction(
                    start: start,
                    direction: direction,
                    triangle: triangle
                ), bestFraction == nil || fraction < bestFraction! else {
                    continue
                }
                var normal = triangle.normal
                if normal.dot(direction) > 0 { normal = -normal }
                bestFraction = fraction
                bestNormal = normal
                bestMaterial = triangle.materialIndex
            }
        }
        guard let fraction = bestFraction else { return nil }
        return try SourcePhysicsQueryHitSnapshot(
            bodyID: bodyID,
            fraction: fraction,
            position: start + direction * fraction,
            normal: bestNormal,
            materialIndex: bestMaterial,
            startedSolid: false,
            allSolid: false
        )
    }

    private func lineHitStaticScene(
        start: SourceVector3,
        end: SourceVector3,
        scene: SourceDeterministicPhysicsStaticScene
    ) throws -> SourcePhysicsQueryHitSnapshot? {
        guard let worldShape = staticCollisionWorldShape else { return nil }
        let queryBounds = motionBounds(
            start: start,
            end: end,
            minimums: .zero,
            maximums: .zero
        )
        prepareStaticCandidates(overlapping: queryBounds)

        let direction = end - start
        var bestFraction: Float?
        var bestNormal = SourceVector3.zero
        var bestMaterial: Int?
        for partIndex in staticCandidatePartIndices {
            let part = worldShape.parts[partIndex]
            guard part.bounds.intersects(queryBounds) else { continue }
            for triangle in part.triangles {
                guard let fraction = segmentTriangleFraction(
                    start: start,
                    direction: direction,
                    triangle: triangle
                ), bestFraction == nil || fraction < bestFraction! else {
                    continue
                }
                var normal = triangle.normal
                if normal.dot(direction) > 0 { normal = -normal }
                bestFraction = fraction
                bestNormal = normal
                bestMaterial = triangle.materialIndex
            }
        }
        guard let fraction = bestFraction else { return nil }
        return try SourcePhysicsQueryHitSnapshot(
            bodyID: scene.bodyID,
            fraction: fraction,
            position: start + direction * fraction,
            normal: bestNormal,
            materialIndex: bestMaterial,
            startedSolid: false,
            allSolid: false
        )
    }

    private func sweptHullHit(
        start: SourceVector3,
        end: SourceVector3,
        minimums: SourceVector3,
        maximums: SourceVector3,
        body: BodyState
    ) throws -> SourcePhysicsQueryHitSnapshot? {
        try sweptHullHit(
            start: start,
            end: end,
            minimums: minimums,
            maximums: maximums,
            bodyID: body.bodyID,
            shape: body.creation.shape,
            transform: body.transform,
            materialIndex: body.creation.materialIndex
        )
    }

    private func sweptHullStaticSceneHit(
        start: SourceVector3,
        end: SourceVector3,
        minimums: SourceVector3,
        maximums: SourceVector3,
        scene: SourceDeterministicPhysicsStaticScene
    ) throws -> SourcePhysicsQueryHitSnapshot? {
        guard let worldShape = staticCollisionWorldShape else { return nil }
        let queryBounds = motionBounds(
            start: start,
            end: end,
            minimums: minimums,
            maximums: maximums
        )
        prepareStaticCandidates(overlapping: queryBounds)
        var best: SourcePhysicsQueryHitSnapshot?
        for partIndex in staticCandidatePartIndices {
            let part = worldShape.parts[partIndex]
            guard part.bounds.intersects(queryBounds) else { continue }
            let hit: ConvexSweepHit?
            switch part.staticMeshTopology {
            case .closedConvexVolume:
                hit = sweptHullConvexPartHit(
                    start: start,
                    end: end,
                    minimums: minimums,
                    maximums: maximums,
                    part: part
                )
            case .openTriangleMesh:
                hit = sweptHullOpenTrianglePartHit(
                    start: start,
                    end: end,
                    minimums: minimums,
                    maximums: maximums,
                    part: part
                )
            }
            guard let hit else { continue }
            let snapshot = try SourcePhysicsQueryHitSnapshot(
                bodyID: scene.bodyID,
                fraction: hit.fraction,
                position: start + (end - start) * hit.fraction,
                normal: hit.normal,
                materialIndex: hit.startedSolid ? nil : hit.materialIndex,
                startedSolid: hit.startedSolid,
                allSolid: hit.allSolid
            )
            if best == nil || snapshot.fraction < best!.fraction {
                best = snapshot
            }
        }
        return best
    }

    private func sweptHullHit(
        start: SourceVector3,
        end: SourceVector3,
        minimums: SourceVector3,
        maximums: SourceVector3,
        bodyID: SourcePhysicsBodyID,
        shape: SourcePhysicsShapeSnapshot,
        transform: SourceEntityTransform,
        materialIndex: Int
    ) throws -> SourcePhysicsQueryHitSnapshot? {
        let target = makeWorldShape(shape: shape, transform: transform).bounds
        let expanded = Bounds(
            minimums: target.minimums - maximums,
            maximums: target.maximums - minimums
        )
        guard let hit = segmentBoundsHit(start: start, end: end, bounds: expanded)
        else { return nil }
        return try SourcePhysicsQueryHitSnapshot(
            bodyID: bodyID,
            fraction: hit.fraction,
            position: start + (end - start) * hit.fraction,
            normal: hit.normal,
            materialIndex: hit.startedSolid ? nil : materialIndex,
            startedSolid: hit.startedSolid,
            allSolid: hit.allSolid
        )
    }

    private func segmentBoundsHit(
        start: SourceVector3,
        end: SourceVector3,
        bounds: Bounds
    ) -> SegmentBoundsHit? {
        let startInside = bounds.contains(start)
        if startInside {
            return SegmentBoundsHit(
                fraction: 0,
                normal: .zero,
                startedSolid: true,
                allSolid: bounds.contains(end)
            )
        }

        let direction = end - start
        var entry: Float = 0
        var exit: Float = 1
        var entryNormal = SourceVector3.zero
        for axis in 0 ..< 3 {
            let origin = start[axis]
            let delta = direction[axis]
            let minimum = bounds.minimums[axis]
            let maximum = bounds.maximums[axis]
            if abs(delta) < 1e-12 {
                if origin < minimum || origin > maximum { return nil }
                continue
            }
            var near = (minimum - origin) / delta
            var far = (maximum - origin) / delta
            var normalSign: Float = -1
            if near > far {
                swap(&near, &far)
                normalSign = 1
            }
            if near > entry {
                entry = near
                entryNormal = .zero
                entryNormal[axis] = normalSign
            }
            exit = min(exit, far)
            if entry > exit { return nil }
        }
        guard entry >= 0, entry <= 1 else { return nil }
        return SegmentBoundsHit(
            fraction: entry,
            normal: entryNormal,
            startedSolid: false,
            allSolid: false
        )
    }

    private func sweptHullConvexPartHit(
        start: SourceVector3,
        end: SourceVector3,
        minimums: SourceVector3,
        maximums: SourceVector3,
        part: WorldPart
    ) -> ConvexSweepHit? {
        let centerOffset = (minimums + maximums) * 0.5
        let extents = (maximums - minimums) * 0.5
        let centeredStart = start + centerOffset
        let centeredEnd = end + centerOffset

        var startsInside = true
        var endsInside = true
        var enterFraction: Float = 0
        var leaveFraction: Float = 1
        var enterNormal = SourceVector3.zero
        var enterMaterial: Int?

        for triangle in part.triangles {
            var normal = triangle.normal
            if (part.center - triangle.first).dot(normal) > 0 {
                normal = -normal
            }
            let expandedDistance = normal.dot(triangle.first) +
                abs(normal.x) * extents.x +
                abs(normal.y) * extents.y +
                abs(normal.z) * extents.z
            let startDistance = normal.dot(centeredStart) - expandedDistance
            let endDistance = normal.dot(centeredEnd) - expandedDistance
            if startDistance > 0 { startsInside = false }
            if endDistance > 0 { endsInside = false }
            if startDistance > 0, endDistance > 0 { return nil }
            if startDistance <= 0, endDistance <= 0 { continue }

            let denominator = startDistance - endDistance
            guard denominator != 0 else { continue }
            let fraction = startDistance / denominator
            if startDistance > endDistance {
                if fraction > enterFraction {
                    enterFraction = fraction
                    enterNormal = normal
                    enterMaterial = triangle.materialIndex
                }
            } else {
                leaveFraction = min(leaveFraction, fraction)
            }
            if enterFraction > leaveFraction { return nil }
        }

        if startsInside {
            return ConvexSweepHit(
                fraction: 0,
                normal: .zero,
                materialIndex: nil,
                startedSolid: true,
                allSolid: endsInside
            )
        }
        guard enterFraction >= 0, enterFraction <= 1,
              enterNormal.lengthSquared > 0 else { return nil }
        return ConvexSweepHit(
            fraction: enterFraction,
            normal: enterNormal,
            materialIndex: enterMaterial,
            startedSolid: false,
            allSolid: false
        )
    }

    /// Sweeps an axis-aligned query box against every triangle of one open
    /// displacement mesh. Each triangle is tested as the exact Minkowski sum
    /// of the triangle and box using the complete triangle/AABB SAT basis:
    /// triangle normal, three box axes, and all nine edge-cross-box axes.
    ///
    /// Strict triangle order and strict fraction replacement preserve stable
    /// material/normal ties. No thickness, back face, or enclosing volume is
    /// synthesized for the open mesh.
    private func sweptHullOpenTrianglePartHit(
        start: SourceVector3,
        end: SourceVector3,
        minimums: SourceVector3,
        maximums: SourceVector3,
        part: WorldPart
    ) -> ConvexSweepHit? {
        var best: ConvexSweepHit?
        for triangle in part.triangles {
            guard let hit = sweptAABBTriangleHit(
                start: start,
                end: end,
                minimums: minimums,
                maximums: maximums,
                triangle: triangle
            ) else { continue }
            // StartSolid dominates every later fraction. The first triangle is
            // retained exactly as stored in the immutable BSP mesh.
            if hit.startedSolid { return hit }
            if best == nil || hit.fraction < best!.fraction {
                best = hit
            }
        }
        return best
    }

    private func sweptAABBTriangleHit(
        start: SourceVector3,
        end: SourceVector3,
        minimums: SourceVector3,
        maximums: SourceVector3,
        triangle: WorldTriangle
    ) -> ConvexSweepHit? {
        let centerOffset = (minimums + maximums) * 0.5
        let extents = (maximums - minimums) * 0.5
        let centeredStart = start + centerOffset
        let centeredEnd = end + centerOffset
        let motion = centeredEnd - centeredStart
        let overlapEpsilon: Float = 1e-6
        let parallelEpsilon: Float = 1e-12

        var enterFraction: Float = 0
        var leaveFraction: Float = 1
        var enterNormal = SourceVector3.zero
        var startsOverlapping = true
        var endsOverlapping = true
        var testedAxis = false

        func testAxis(_ rawAxis: SourceVector3) -> Bool {
            let lengthSquared = rawAxis.lengthSquared
            guard lengthSquared > parallelEpsilon else { return true }
            testedAxis = true
            let axis = rawAxis / lengthSquared.squareRoot()
            let firstProjection: Float = triangle.first.dot(axis)
            let secondProjection: Float = triangle.second.dot(axis)
            let thirdProjection: Float = triangle.third.dot(axis)
            let triangleMinimum: Float = min(
                firstProjection,
                min(secondProjection, thirdProjection)
            )
            let triangleMaximum: Float = max(
                firstProjection,
                max(secondProjection, thirdProjection)
            )
            let radius: Float = abs(axis.x) * extents.x +
                abs(axis.y) * extents.y +
                abs(axis.z) * extents.z
            // Time of impact uses the exact Minkowski interval. Expanding it
            // here makes a hull resting on a displacement surface appear to
            // begin inside that surface on its next ground probe.
            let intervalMinimum: Float = triangleMinimum - radius
            let intervalMaximum: Float = triangleMaximum + radius
            let startProjection: Float = centeredStart.dot(axis)
            let endProjection: Float = centeredEnd.dot(axis)
            let startInside = startProjection >= intervalMinimum &&
                startProjection <= intervalMaximum
            // StartSolid means positive-volume penetration, not boundary
            // contact. This keeps a standing Source hull grounded without
            // classifying its bottom face touching terrain as embedded.
            let startPenetrating =
                startProjection > intervalMinimum + overlapEpsilon &&
                startProjection < intervalMaximum - overlapEpsilon
            let endPenetrating =
                endProjection > intervalMinimum + overlapEpsilon &&
                endProjection < intervalMaximum - overlapEpsilon
            startsOverlapping = startsOverlapping && startPenetrating
            endsOverlapping = endsOverlapping && endPenetrating

            let projectedMotion: Float = motion.dot(axis)
            if abs(projectedMotion) <= parallelEpsilon {
                return startInside
            }

            let nearFraction: Float
            let farFraction: Float
            let nearNormal: SourceVector3
            if projectedMotion > 0 {
                nearFraction = (intervalMinimum - startProjection) /
                    projectedMotion
                farFraction = (intervalMaximum - startProjection) /
                    projectedMotion
                nearNormal = -axis
            } else {
                nearFraction = (intervalMaximum - startProjection) /
                    projectedMotion
                farFraction = (intervalMinimum - startProjection) /
                    projectedMotion
                nearNormal = axis
            }
            if nearFraction > enterFraction ||
                (nearFraction == enterFraction &&
                    enterNormal.lengthSquared == 0) {
                enterFraction = nearFraction
                enterNormal = nearNormal
            }
            leaveFraction = min(leaveFraction, farFraction)
            return enterFraction <= leaveFraction
        }

        let boxX = SourceVector3(1, 0, 0)
        let boxY = SourceVector3(0, 1, 0)
        let boxZ = SourceVector3(0, 0, 1)
        guard testAxis(triangle.normal),
              testAxis(boxX),
              testAxis(boxY),
              testAxis(boxZ) else { return nil }

        let firstEdge = triangle.second - triangle.first
        let secondEdge = triangle.third - triangle.second
        let thirdEdge = triangle.first - triangle.third
        guard testAxis(firstEdge.cross(boxX)),
              testAxis(firstEdge.cross(boxY)),
              testAxis(firstEdge.cross(boxZ)),
              testAxis(secondEdge.cross(boxX)),
              testAxis(secondEdge.cross(boxY)),
              testAxis(secondEdge.cross(boxZ)),
              testAxis(thirdEdge.cross(boxX)),
              testAxis(thirdEdge.cross(boxY)),
              testAxis(thirdEdge.cross(boxZ)),
              testedAxis else { return nil }

        if startsOverlapping {
            return ConvexSweepHit(
                fraction: 0,
                normal: .zero,
                materialIndex: nil,
                startedSolid: true,
                allSolid: endsOverlapping
            )
        }
        guard enterFraction >= 0, enterFraction <= 1,
              enterNormal.lengthSquared > 0 else { return nil }
        return ConvexSweepHit(
            fraction: enterFraction,
            normal: enterNormal,
            materialIndex: triangle.materialIndex,
            startedSolid: false,
            allSolid: false
        )
    }

    private func segmentTriangleFraction(
        start: SourceVector3,
        direction: SourceVector3,
        triangle: WorldTriangle
    ) -> Float? {
        let firstEdge = triangle.second - triangle.first
        let secondEdge = triangle.third - triangle.first
        let cross = direction.cross(secondEdge)
        let determinant = firstEdge.dot(cross)
        guard abs(determinant) > 1e-8 else { return nil }
        let inverse = 1 / determinant
        let offset = start - triangle.first
        let u = offset.dot(cross) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let q = offset.cross(firstEdge)
        let v = direction.dot(q) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let fraction = secondEdge.dot(q) * inverse
        guard fraction >= 0, fraction <= 1 else { return nil }
        return fraction
    }

    private func pointInsideConvex(
        _ point: SourceVector3,
        part: WorldPart
    ) -> Bool {
        for triangle in part.triangles {
            var normal = triangle.normal
            if (part.center - triangle.first).dot(normal) > 0 {
                normal = -normal
            }
            if (point - triangle.first).dot(normal) > 1e-5 {
                return false
            }
        }
        return true
    }

    private func makeWorldShape(body: BodyState) -> WorldShape {
        makeWorldShape(
            shape: body.creation.shape,
            transform: body.transform
        )
    }

    private func makeWorldShape(
        shape: SourcePhysicsShapeSnapshot,
        transform worldTransform: SourceEntityTransform
    ) -> WorldShape {
        let parts = shape.parts.map { part -> WorldPart in
            let vertices = part.vertices.map {
                transform($0, by: worldTransform)
            }
            let triangles = part.triangles.map { triangle in
                WorldTriangle(
                    first: vertices[triangle.first],
                    second: vertices[triangle.second],
                    third: vertices[triangle.third],
                    materialIndex: triangle.materialIndex
                )
            }
            let center = vertices.reduce(.zero, +) / Float(vertices.count)
            return WorldPart(
                vertices: vertices,
                triangles: triangles,
                bounds: bounds(of: vertices),
                center: center,
                faceNormals: triangles.map(\.normal),
                edges: triangles.flatMap(\.edges),
                staticMeshTopology: shape.topology == .convexParts
                    ? .closedConvexVolume
                    : .openTriangleMesh
            )
        }
        return WorldShape(
            topology: shape.topology,
            parts: parts,
            bounds: union(parts.map(\.bounds))
        )
    }

    private func makeWorldShape(
        geometry: SourceDeterministicPhysicsStaticGeometry,
        transform worldTransform: SourceEntityTransform
    ) -> WorldShape {
        let parts = geometry.parts.map { part -> WorldPart in
            let vertices = part.vertices.map {
                transform($0, by: worldTransform)
            }
            let triangles = part.triangles.map { triangle in
                WorldTriangle(
                    first: vertices[triangle.first],
                    second: vertices[triangle.second],
                    third: vertices[triangle.third],
                    materialIndex: triangle.materialIndex
                )
            }
            let center = vertices.reduce(.zero, +) / Float(vertices.count)
            return WorldPart(
                vertices: vertices,
                triangles: triangles,
                bounds: bounds(of: vertices),
                center: center,
                faceNormals: triangles.map(\.normal),
                edges: triangles.flatMap(\.edges),
                staticMeshTopology: part.topology
            )
        }
        return WorldShape(
            topology: .triangleMesh,
            parts: parts,
            bounds: union(parts.map(\.bounds))
        )
    }

    private func transform(
        _ vertex: SourceVector3,
        by transform: SourceEntityTransform
    ) -> SourceVector3 {
        let basis = transform.angles.sourceBasis
        return transform.origin +
            basis.forward * vertex.x +
            (-basis.right) * vertex.y +
            basis.up * vertex.z
    }

    private func bounds(of vertices: [SourceVector3]) -> Bounds {
        var minimums = vertices[0]
        var maximums = vertices[0]
        for vertex in vertices.dropFirst() {
            minimums.x = min(minimums.x, vertex.x)
            minimums.y = min(minimums.y, vertex.y)
            minimums.z = min(minimums.z, vertex.z)
            maximums.x = max(maximums.x, vertex.x)
            maximums.y = max(maximums.y, vertex.y)
            maximums.z = max(maximums.z, vertex.z)
        }
        return Bounds(minimums: minimums, maximums: maximums)
    }

    private func union(_ bounds: [Bounds]) -> Bounds {
        var result = bounds[0]
        for value in bounds.dropFirst() {
            result.minimums.x = min(result.minimums.x, value.minimums.x)
            result.minimums.y = min(result.minimums.y, value.minimums.y)
            result.minimums.z = min(result.minimums.z, value.minimums.z)
            result.maximums.x = max(result.maximums.x, value.maximums.x)
            result.maximums.y = max(result.maximums.y, value.maximums.y)
            result.maximums.z = max(result.maximums.z, value.maximums.z)
        }
        return result
    }

    private func project(
        _ vertices: [SourceVector3],
        onto axis: SourceVector3
    ) -> Projection {
        var minimum = vertices[0].dot(axis)
        var maximum = minimum
        for vertex in vertices.dropFirst() {
            let value = vertex.dot(axis)
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        return Projection(minimum: minimum, maximum: maximum)
    }

    private func support(
        _ vertices: [SourceVector3],
        direction: SourceVector3
    ) -> SourceVector3 {
        var maximum = vertices[0].dot(direction)
        for vertex in vertices.dropFirst() {
            let value = vertex.dot(direction)
            maximum = max(maximum, value)
        }
        var total = SourceVector3.zero
        var count: Float = 0
        for vertex in vertices where maximum - vertex.dot(direction) <= 1e-5 {
            total += vertex
            count += 1
        }
        return total / count
    }

    private func closestPoint(
        to point: SourceVector3,
        on triangle: WorldTriangle
    ) -> SourceVector3 {
        // Ericson's region tests, kept in a fixed expression order for replay.
        let ab = triangle.second - triangle.first
        let ac = triangle.third - triangle.first
        let ap = point - triangle.first
        let d1 = ab.dot(ap)
        let d2 = ac.dot(ap)
        if d1 <= 0, d2 <= 0 { return triangle.first }

        let bp = point - triangle.second
        let d3 = ab.dot(bp)
        let d4 = ac.dot(bp)
        if d3 >= 0, d4 <= d3 { return triangle.second }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            return triangle.first + ab * (d1 / (d1 - d3))
        }

        let cp = point - triangle.third
        let d5 = ab.dot(cp)
        let d6 = ac.dot(cp)
        if d6 >= 0, d5 <= d6 { return triangle.third }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            return triangle.first + ac * (d2 / (d2 - d6))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let edge = triangle.third - triangle.second
            let weight = (d4 - d3) /
                ((d4 - d3) + (d5 - d6))
            return triangle.second + edge * weight
        }

        let denominator = 1 / (va + vb + vc)
        return triangle.first + ab * (vb * denominator) +
            ac * (vc * denominator)
    }

    private func integrating(
        _ angles: SourceQAngle,
        angularVelocity: SourceVector3,
        delta: Float
    ) -> SourceQAngle {
        SourceQAngle(
            pitch: angles.pitch + angularVelocity.x * delta,
            yaw: angles.yaw + angularVelocity.y * delta,
            roll: angles.roll + angularVelocity.z * delta
        )
    }

    private func makeSnapshot(
        bodies: [SourcePhysicsBodyID: BodyState],
        fixedConstraints: [
            SourcePhysicsConstraintID: FixedConstraintState
        ],
        lengthConstraints: [
            SourcePhysicsConstraintID: LengthConstraintState
        ],
        noCollideConstraints: [
            SourcePhysicsConstraintID: NoCollideConstraintState
        ],
        simulationTick: UInt64,
        lastProcessedCommandSequence: UInt64?,
        queryResults: [SourcePhysicsQueryResultSnapshot]
    ) throws -> SourcePhysicsEnvironmentSnapshot {
        let snapshots = try bodies.values
            .sorted { Self.bodyIDPrecedes($0.bodyID, $1.bodyID) }
            .map { body in
                try SourcePhysicsBodySnapshot(
                    bodyID: body.bodyID,
                    shape: body.creation.shape,
                    massProperties: body.massProperties,
                    transform: body.transform,
                    linearVelocity: body.linearVelocity,
                    angularVelocity: body.angularVelocity,
                    damping: body.damping,
                    motionType: body.motionType,
                    materialIndex: body.creation.materialIndex,
                    isMotionEnabled: body.isMotionEnabled,
                    isGravityEnabled: body.isGravityEnabled,
                    isCollisionEnabled: body.isCollisionEnabled,
                    isSleeping: body.isSleeping,
                    simulationTick: body.simulationTick
                )
            }
        let constraintSnapshots = try fixedConstraints.values
            .sorted { $0.constraintID.rawValue < $1.constraintID.rawValue }
            .map { constraint in
                try SourcePhysicsFixedConstraintSnapshot(
                    constraintID: constraint.constraintID,
                    referenceBodyID: constraint.creation.referenceBodyID,
                    attachedBodyID: constraint.creation.attachedBodyID,
                    attachedPoseInReference: constraint.relativePose
                        .snapshotTransform,
                    simulationTick: constraint.simulationTick
                )
            }
        let lengthConstraintSnapshots = lengthConstraints.values
            .sorted { $0.constraintID.rawValue < $1.constraintID.rawValue }
            .map { constraint in
                SourcePhysicsLengthConstraintSnapshot(
                    creation: constraint.creation,
                    simulationTick: constraint.simulationTick
                )
            }
        let noCollideConstraintSnapshots = noCollideConstraints.values
            .sorted { $0.constraintID.rawValue < $1.constraintID.rawValue }
            .map { constraint in
                SourcePhysicsNoCollideConstraintSnapshot(
                    creation: constraint.creation,
                    simulationTick: constraint.simulationTick
                )
            }
        return try SourcePhysicsEnvironmentSnapshot(
            simulationTick: simulationTick,
            lastProcessedCommandSequence: lastProcessedCommandSequence,
            bodies: snapshots,
            queryResults: queryResults,
            fixedConstraints: constraintSnapshots,
            lengthConstraints: lengthConstraintSnapshots,
            noCollideConstraints: noCollideConstraintSnapshots
        )
    }

    private static func bodyIDPrecedes(
        _ lhs: SourcePhysicsBodyID,
        _ rhs: SourcePhysicsBodyID
    ) -> Bool {
        let lhsHandle = lhs.entityIdentity.handle.rawValue
        let rhsHandle = rhs.entityIdentity.handle.rawValue
        if lhsHandle != rhsHandle { return lhsHandle < rhsHandle }
        return lhs.solidIndex < rhs.solidIndex
    }
}

private extension SourceVector3 {
    var isSourcePhysicsFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }

    func cross(_ other: SourceVector3) -> SourceVector3 {
        SourceVector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    var normalizedOrZero: SourceVector3 {
        let magnitudeSquared = lengthSquared
        guard magnitudeSquared.isFinite, magnitudeSquared > 1e-20 else {
            return .zero
        }
        return self / magnitudeSquared.squareRoot()
    }
}
