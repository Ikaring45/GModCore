import Foundation

/// Backend-neutral identity for one physics constraint.
///
/// Identifiers are host-assigned and never inferred from a backend pointer.
/// The deterministic environment retires a deleted identifier permanently so
/// a delayed delete cannot target a newer constraint which reused the value.
public struct SourcePhysicsConstraintID: Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) throws {
        guard rawValue != 0 else {
            throw SourcePhysicsContractError.invalidConstraintID(rawValue)
        }
        self.rawValue = rawValue
    }
}

public enum SourcePhysicsConstraintKind: Equatable, Hashable, Sendable {
    case fixed
    case length
}

/// A length-constraint endpoint is either a mutable physics body or the one
/// immutable worldspawn collision body supplied by the environment. Keeping
/// this authored distinction avoids manufacturing a dynamic body for Entity(0).
public enum SourcePhysicsLengthConstraintEndpointKind:
    Equatable, Hashable, Sendable
{
    case body
    case staticWorld
}

public struct SourcePhysicsLengthConstraintEndpoint: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID
    public let kind: SourcePhysicsLengthConstraintEndpointKind
    public let localAnchor: SourceVector3

    public init(
        bodyID: SourcePhysicsBodyID,
        kind: SourcePhysicsLengthConstraintEndpointKind,
        localAnchor: SourceVector3
    ) throws {
        guard localAnchor.sourceConstraintIsFinite else {
            throw SourcePhysicsContractError.nonFinite(
                field: "lengthConstraint.localAnchor"
            )
        }
        self.bodyID = bodyID
        self.kind = kind
        self.localAnchor = localAnchor
    }
}

/// Backend-neutral form of VPhysics `constraint_lengthparams_t`.
///
/// Source's flexible rope uses `minimumLength == 0`; spawnflag 2 makes the
/// constraint rigid by setting minimum and maximum to the same authored
/// length. A positive break force is preserved in the contract, although the
/// deterministic backend rejects it until its break event is source-attested.
public struct SourcePhysicsLengthConstraintCreationCommand:
    Equatable, Sendable
{
    public let constraintID: SourcePhysicsConstraintID
    public let reference: SourcePhysicsLengthConstraintEndpoint
    public let attached: SourcePhysicsLengthConstraintEndpoint
    public let minimumLength: Float
    public let maximumLength: Float
    public let forceLimitKilogramInchesPerSecond: Float

    public init(
        constraintID: SourcePhysicsConstraintID,
        reference: SourcePhysicsLengthConstraintEndpoint,
        attached: SourcePhysicsLengthConstraintEndpoint,
        minimumLength: Float,
        maximumLength: Float,
        forceLimitKilogramInchesPerSecond: Float = 0
    ) throws {
        guard reference.bodyID != attached.bodyID else {
            throw SourcePhysicsContractError.constraintReferencesSameBody(
                reference.bodyID
            )
        }
        guard minimumLength.isFinite, maximumLength.isFinite,
              forceLimitKilogramInchesPerSecond.isFinite else {
            throw SourcePhysicsContractError.nonFinite(
                field: "lengthConstraint"
            )
        }
        guard minimumLength >= 0 else {
            throw SourcePhysicsContractError.negative(
                field: "lengthConstraint.minimumLength"
            )
        }
        guard maximumLength >= minimumLength else {
            throw SourcePhysicsContractError.invalidConstraintLengthRange(
                minimum: minimumLength,
                maximum: maximumLength
            )
        }
        guard forceLimitKilogramInchesPerSecond >= 0 else {
            throw SourcePhysicsContractError.negative(
                field: "lengthConstraint.forceLimit"
            )
        }
        self.constraintID = constraintID
        self.reference = reference
        self.attached = attached
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.forceLimitKilogramInchesPerSecond =
            forceLimitKilogramInchesPerSecond
    }
}

public struct SourcePhysicsLengthConstraintSnapshot: Equatable, Sendable {
    public let creation: SourcePhysicsLengthConstraintCreationCommand
    public let simulationTick: UInt64

    public init(
        creation: SourcePhysicsLengthConstraintCreationCommand,
        simulationTick: UInt64
    ) {
        self.creation = creation
        self.simulationTick = simulationTick
    }

    public var constraintID: SourcePhysicsConstraintID {
        creation.constraintID
    }
}

/// Creates a two-body fixed constraint at the bodies' current relative pose.
///
/// Both endpoints retain the complete Source body identity, including the
/// entity EHANDLE generation and the model solid index. Anchor/break-force and
/// collision-disable policy are intentionally absent until authenticated data
/// crosses the public contract.
public struct SourcePhysicsFixedConstraintCreationCommand:
    Equatable, Sendable
{
    public let constraintID: SourcePhysicsConstraintID
    public let referenceBodyID: SourcePhysicsBodyID
    public let attachedBodyID: SourcePhysicsBodyID

    public init(
        constraintID: SourcePhysicsConstraintID,
        referenceBodyID: SourcePhysicsBodyID,
        attachedBodyID: SourcePhysicsBodyID
    ) throws {
        guard referenceBodyID != attachedBodyID else {
            throw SourcePhysicsContractError.constraintReferencesSameBody(
                referenceBodyID
            )
        }
        self.constraintID = constraintID
        self.referenceBodyID = referenceBodyID
        self.attachedBodyID = attachedBodyID
    }
}

public struct SourcePhysicsConstraintDeletionCommand: Equatable, Sendable {
    public let constraintID: SourcePhysicsConstraintID

    public init(constraintID: SourcePhysicsConstraintID) {
        self.constraintID = constraintID
    }
}

/// Immutable fixed-constraint state published by a physics environment.
public struct SourcePhysicsFixedConstraintSnapshot: Equatable, Sendable {
    public let constraintID: SourcePhysicsConstraintID
    public let referenceBodyID: SourcePhysicsBodyID
    public let attachedBodyID: SourcePhysicsBodyID
    /// Attached-body pose expressed in the reference body's local frame at
    /// the exact FIFO position where the constraint was created.
    public let attachedPoseInReference: SourceEntityTransform
    public let simulationTick: UInt64

    public init(
        constraintID: SourcePhysicsConstraintID,
        referenceBodyID: SourcePhysicsBodyID,
        attachedBodyID: SourcePhysicsBodyID,
        attachedPoseInReference: SourceEntityTransform,
        simulationTick: UInt64
    ) throws {
        guard referenceBodyID != attachedBodyID else {
            throw SourcePhysicsContractError.constraintReferencesSameBody(
                referenceBodyID
            )
        }
        guard attachedPoseInReference.origin.sourceConstraintIsFinite,
              attachedPoseInReference.angles.sourceConstraintIsFinite else {
            throw SourcePhysicsContractError.nonFinite(
                field: "constraint.attachedPoseInReference"
            )
        }
        self.constraintID = constraintID
        self.referenceBodyID = referenceBodyID
        self.attachedBodyID = attachedBodyID
        self.attachedPoseInReference = attachedPoseInReference
        self.simulationTick = simulationTick
    }
}

/// Solver-private relative orientation. Quaternion storage avoids treating
/// component-wise Euler subtraction as a physical relative rotation.
struct SourcePhysicsFixedConstraintPose: Equatable {
    let attachedOriginInReference: SourceVector3
    let attachedRotationInReference: SourcePhysicsConstraintQuaternion

    init(
        reference: SourceEntityTransform,
        attached: SourceEntityTransform
    ) {
        attachedOriginInReference = reference.inverseTransformPointToLocal(
            attached.origin
        )
        attachedRotationInReference =
            SourcePhysicsConstraintQuaternion(reference.angles).inverse *
            SourcePhysicsConstraintQuaternion(attached.angles)
    }

    var snapshotTransform: SourceEntityTransform {
        SourceEntityTransform(
            origin: attachedOriginInReference,
            angles: attachedRotationInReference.sourceAngles
        )
    }

    func desiredAttachedTransform(
        reference: SourceEntityTransform
    ) -> SourceEntityTransform {
        let referenceRotation = SourcePhysicsConstraintQuaternion(
            reference.angles
        )
        return SourceEntityTransform(
            origin: reference.transformPointFromLocal(
                attachedOriginInReference
            ),
            angles: (referenceRotation * attachedRotationInReference)
                .sourceAngles
        )
    }

    func desiredReferenceTransform(
        attached: SourceEntityTransform
    ) -> SourceEntityTransform {
        let attachedRotation = SourcePhysicsConstraintQuaternion(
            attached.angles
        )
        let referenceRotation = attachedRotation *
            attachedRotationInReference.inverse
        return SourceEntityTransform(
            origin: attached.origin - referenceRotation.rotate(
                attachedOriginInReference
            ),
            angles: referenceRotation.sourceAngles
        )
    }
}

struct SourcePhysicsConstraintQuaternion: Equatable {
    let x: Float
    let y: Float
    let z: Float
    let w: Float

    static let identity = SourcePhysicsConstraintQuaternion(
        x: 0,
        y: 0,
        z: 0,
        w: 1,
        normalize: false
    )

    init(_ angles: SourceQAngle) {
        let basis = angles.sourceBasis
        self.init(
            localX: basis.forward,
            localY: -basis.right,
            localZ: basis.up
        )
    }

    private init(
        localX: SourceVector3,
        localY: SourceVector3,
        localZ: SourceVector3
    ) {
        let m00 = localX.x, m01 = localY.x, m02 = localZ.x
        let m10 = localX.y, m11 = localY.y, m12 = localZ.y
        let m20 = localX.z, m21 = localY.z, m22 = localZ.z
        let trace = m00 + m11 + m22
        let unnormalized: (Float, Float, Float, Float)
        if trace > 0 {
            let scale = (trace + 1).squareRoot() * 2
            unnormalized = (
                (m21 - m12) / scale,
                (m02 - m20) / scale,
                (m10 - m01) / scale,
                scale * 0.25
            )
        } else if m00 > m11, m00 > m22 {
            let scale = (1 + m00 - m11 - m22).squareRoot() * 2
            unnormalized = (
                scale * 0.25,
                (m01 + m10) / scale,
                (m02 + m20) / scale,
                (m21 - m12) / scale
            )
        } else if m11 > m22 {
            let scale = (1 + m11 - m00 - m22).squareRoot() * 2
            unnormalized = (
                (m01 + m10) / scale,
                scale * 0.25,
                (m12 + m21) / scale,
                (m02 - m20) / scale
            )
        } else {
            let scale = (1 + m22 - m00 - m11).squareRoot() * 2
            unnormalized = (
                (m02 + m20) / scale,
                (m12 + m21) / scale,
                scale * 0.25,
                (m10 - m01) / scale
            )
        }
        self.init(
            x: unnormalized.0,
            y: unnormalized.1,
            z: unnormalized.2,
            w: unnormalized.3,
            normalize: true
        )
    }

    private init(
        x: Float,
        y: Float,
        z: Float,
        w: Float,
        normalize: Bool
    ) {
        if normalize {
            let lengthSquared = x * x + y * y + z * z + w * w
            if lengthSquared > 1e-20, lengthSquared.isFinite {
                let inverseLength = 1 / lengthSquared.squareRoot()
                self.x = x * inverseLength
                self.y = y * inverseLength
                self.z = z * inverseLength
                self.w = w * inverseLength
                return
            }
        }
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    var inverse: SourcePhysicsConstraintQuaternion {
        SourcePhysicsConstraintQuaternion(
            x: -x,
            y: -y,
            z: -z,
            w: w,
            normalize: true
        )
    }

    static func * (
        lhs: SourcePhysicsConstraintQuaternion,
        rhs: SourcePhysicsConstraintQuaternion
    ) -> SourcePhysicsConstraintQuaternion {
        SourcePhysicsConstraintQuaternion(
            x: lhs.w * rhs.x + lhs.x * rhs.w +
                lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z +
                lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y -
                lhs.y * rhs.x + lhs.z * rhs.w,
            w: lhs.w * rhs.w - lhs.x * rhs.x -
                lhs.y * rhs.y - lhs.z * rhs.z,
            normalize: true
        )
    }

    func rotate(_ vector: SourceVector3) -> SourceVector3 {
        let quaternionVector = SourceVector3(x, y, z)
        let twiceCross = quaternionVector.crossForConstraint(vector) * 2
        return vector + twiceCross * w +
            quaternionVector.crossForConstraint(twiceCross)
    }

    func interpolated(
        toward target: SourcePhysicsConstraintQuaternion,
        fraction: Float
    ) -> SourcePhysicsConstraintQuaternion {
        guard fraction > 0 else { return self }
        guard fraction < 1 else { return target }
        var destination = target
        var cosine = x * target.x + y * target.y +
            z * target.z + w * target.w
        if cosine < 0 {
            cosine = -cosine
            destination = SourcePhysicsConstraintQuaternion(
                x: -target.x,
                y: -target.y,
                z: -target.z,
                w: -target.w,
                normalize: false
            )
        }
        if cosine > 0.9995 {
            return SourcePhysicsConstraintQuaternion(
                x: x + (destination.x - x) * fraction,
                y: y + (destination.y - y) * fraction,
                z: z + (destination.z - z) * fraction,
                w: w + (destination.w - w) * fraction,
                normalize: true
            )
        }
        let clampedCosine = min(max(cosine, -1), 1)
        let angle = acos(clampedCosine)
        let sine = sin(angle)
        guard sine != 0 else { return self }
        let sourceScale = sin((1 - fraction) * angle) / sine
        let targetScale = sin(fraction * angle) / sine
        return SourcePhysicsConstraintQuaternion(
            x: x * sourceScale + destination.x * targetScale,
            y: y * sourceScale + destination.y * targetScale,
            z: z * sourceScale + destination.z * targetScale,
            w: w * sourceScale + destination.w * targetScale,
            normalize: true
        )
    }

    var sourceAngles: SourceQAngle {
        let localX = rotate(SourceVector3(1, 0, 0))
        let localZ = rotate(SourceVector3(0, 0, 1))
        let horizontal = (localX.x * localX.x +
            localX.y * localX.y).squareRoot()
        let pitch = atan2(-localX.z, horizontal)
        let yaw = atan2(localX.y, localX.x)
        let sinePitch = sin(pitch), cosinePitch = cos(pitch)
        let sineYaw = sin(yaw), cosineYaw = cos(yaw)
        let rightAtZeroRoll = SourceVector3(sineYaw, -cosineYaw, 0)
        let upAtZeroRoll = SourceVector3(
            sinePitch * cosineYaw,
            sinePitch * sineYaw,
            cosinePitch
        )
        let roll = atan2(
            localZ.dotForConstraint(rightAtZeroRoll),
            localZ.dotForConstraint(upAtZeroRoll)
        )
        let radiansToDegrees = Float(180) / Float.pi
        return SourceQAngle(
            pitch: pitch * radiansToDegrees,
            yaw: yaw * radiansToDegrees,
            roll: roll * radiansToDegrees
        )
    }
}

private extension SourceVector3 {
    var sourceConstraintIsFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }

    func dotForConstraint(_ other: SourceVector3) -> Float {
        x * other.x + y * other.y + z * other.z
    }

    func crossForConstraint(_ other: SourceVector3) -> SourceVector3 {
        SourceVector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }
}

private extension SourceQAngle {
    var sourceConstraintIsFinite: Bool {
        pitch.isFinite && yaw.isFinite && roll.isFinite
    }
}
