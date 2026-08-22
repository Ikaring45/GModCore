/// Contact coefficients resolved from exact Source physics-material indices.
///
/// Source SDK 2013's fixed `vphysics_interface.h` publishes one per-material
/// `friction` value and one `elasticity` value, but the public interface does
/// not publish VPhysics' material-pair combination rule or a static/dynamic
/// friction split. Consequently this value accepts only already-resolved,
/// independently attested contact coefficients. It deliberately has no
/// initializer that guesses a pair from two `surfacephysicsparams_t` records.
public struct SourcePhysicsContactMaterialCoefficients:
    Equatable, Hashable, Sendable
{
    public let staticFriction: Float
    public let dynamicFriction: Float
    public let restitution: Float

    public init(
        staticFriction: Float,
        dynamicFriction: Float,
        restitution: Float
    ) throws {
        guard staticFriction.isFinite, staticFriction >= 0 else {
            throw SourcePhysicsMaterialTableError.invalidCoefficient(
                field: "staticFriction",
                value: staticFriction
            )
        }
        guard dynamicFriction.isFinite, dynamicFriction >= 0 else {
            throw SourcePhysicsMaterialTableError.invalidCoefficient(
                field: "dynamicFriction",
                value: dynamicFriction
            )
        }
        guard restitution.isFinite, restitution >= 0 else {
            throw SourcePhysicsMaterialTableError.invalidCoefficient(
                field: "restitution",
                value: restitution
            )
        }
        self.staticFriction = staticFriction
        self.dynamicFriction = dynamicFriction
        self.restitution = restitution
    }
}

/// One explicitly attested, order-independent material interaction.
///
/// `IPhysicsObject::GetMaterialIndex` and a collision triangle's seven-bit
/// material index are both Source-owned identifiers. This record keeps those
/// identifiers intact and attaches no name, default material, or backend type.
public struct SourcePhysicsMaterialInteraction: Equatable, Hashable, Sendable {
    public let firstMaterialIndex: Int
    public let secondMaterialIndex: Int
    public let coefficients: SourcePhysicsContactMaterialCoefficients

    public init(
        firstMaterialIndex: Int,
        secondMaterialIndex: Int,
        coefficients: SourcePhysicsContactMaterialCoefficients
    ) throws {
        guard firstMaterialIndex >= 0 else {
            throw SourcePhysicsMaterialTableError.negativeMaterialIndex(
                firstMaterialIndex
            )
        }
        guard secondMaterialIndex >= 0 else {
            throw SourcePhysicsMaterialTableError.negativeMaterialIndex(
                secondMaterialIndex
            )
        }
        self.firstMaterialIndex = Swift.min(
            firstMaterialIndex,
            secondMaterialIndex
        )
        self.secondMaterialIndex = Swift.max(
            firstMaterialIndex,
            secondMaterialIndex
        )
        self.coefficients = coefficients
    }
}

public enum SourcePhysicsMaterialTableError: Error, Equatable, Sendable {
    case negativeMaterialIndex(Int)
    case invalidCoefficient(field: String, value: Float)
    case duplicateInteraction(firstMaterialIndex: Int, secondMaterialIndex: Int)
    case unregisteredInteraction(firstMaterialIndex: Int, secondMaterialIndex: Int)
    case missingContactMaterialIndex(bodyID: SourcePhysicsBodyID)
}

/// Immutable backend-neutral lookup for exact material-pair behavior.
///
/// Missing pairs fail closed. In particular, this table never substitutes
/// zero friction or zero restitution for an unregistered material. Callers
/// that do not yet possess independently attested pair behavior must leave the
/// deterministic environment's material table unconfigured; that legacy mode
/// remains explicitly distinguishable from a successfully resolved material.
public struct SourcePhysicsMaterialTable: Equatable, Sendable {
    private struct Pair: Equatable, Hashable, Sendable {
        let first: Int
        let second: Int

        init(_ first: Int, _ second: Int) {
            self.first = Swift.min(first, second)
            self.second = Swift.max(first, second)
        }
    }

    private let interactions: [Pair: SourcePhysicsContactMaterialCoefficients]

    /// An unconfigured table is fail-closed: every lookup throws instead of
    /// supplying invented zero-friction or zero-restitution behavior.
    public static let unconfigured = try! SourcePhysicsMaterialTable(
        interactions: []
    )

    public init(interactions: [SourcePhysicsMaterialInteraction]) throws {
        var resolved: [Pair: SourcePhysicsContactMaterialCoefficients] = [:]
        resolved.reserveCapacity(interactions.count)
        for interaction in interactions {
            let pair = Pair(
                interaction.firstMaterialIndex,
                interaction.secondMaterialIndex
            )
            guard resolved[pair] == nil else {
                throw SourcePhysicsMaterialTableError.duplicateInteraction(
                    firstMaterialIndex: pair.first,
                    secondMaterialIndex: pair.second
                )
            }
            resolved[pair] = interaction.coefficients
        }
        self.interactions = resolved
    }

    public var interactionCount: Int { interactions.count }

    public func coefficients(
        firstMaterialIndex: Int,
        secondMaterialIndex: Int
    ) throws -> SourcePhysicsContactMaterialCoefficients {
        guard firstMaterialIndex >= 0 else {
            throw SourcePhysicsMaterialTableError.negativeMaterialIndex(
                firstMaterialIndex
            )
        }
        guard secondMaterialIndex >= 0 else {
            throw SourcePhysicsMaterialTableError.negativeMaterialIndex(
                secondMaterialIndex
            )
        }
        let pair = Pair(firstMaterialIndex, secondMaterialIndex)
        guard let coefficients = interactions[pair] else {
            throw SourcePhysicsMaterialTableError.unregisteredInteraction(
                firstMaterialIndex: pair.first,
                secondMaterialIndex: pair.second
            )
        }
        return coefficients
    }
}
