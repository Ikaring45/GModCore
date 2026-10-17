import Foundation

/// Independent implementation of the inline ANIMROT contract described by
/// Source SDK 2013 CalcBoneQuaternion / AngleQuaternion(RadianEuler).
/// Does not implement IK, pose blending or external animation blocks.
enum SourceStudioAnimationRotation {
    static func evaluate(channel: SourceStudioAnimationBoneChannel,
                         bone: SourceStudioAnimationBoneDescriptor,
                         frame: Int, fraction: SourceStudioAnimationFrameFraction) throws -> SourceStudioQuaternion {
        let delta = channel.flags.contains(.delta)
        let base = delta ? SourceStudioRadianEuler() : bone.eulerRadians
        let scales = [bone.rotationScale.x, bone.rotationScale.y, bone.rotationScale.z]
        let bases = [base.x, base.y, base.z]
        var first = [Float](repeating: 0, count: 3)
        var next = first
        for axis in 0..<3 {
            if fraction.value > 0.001 {
                let pair = try channel.rotationStreams[axis]?.scaledPair(frame: frame, scale: scales[axis]) ?? (0, 0)
                first[axis] = pair.0 + bases[axis]
                next[axis] = pair.1 + bases[axis]
            } else {
                first[axis] = try (channel.rotationStreams[axis]?.scaledValue(frame: frame, scale: scales[axis]) ?? 0) + bases[axis]
                next[axis] = first[axis]
            }
        }
        guard (first + next).allSatisfy(\.isFinite) else { throw invalid(bone.index) }
        var result = quaternion(first)
        if first != next {
            let second = aligned(quaternion(next), to: result)
            let s = fraction.value
            let p = 1 - s
            result = SourceStudioQuaternion(x: p * result.x + s * second.x,
                y: p * result.y + s * second.y, z: p * result.z + s * second.z,
                w: p * result.w + s * second.w)
            let lengthSquared = result.x * result.x + result.y * result.y + result.z * result.z + result.w * result.w
            guard lengthSquared.isFinite, lengthSquared > 0 else { throw invalid(bone.index) }
            let scale = 1 / sqrt(lengthSquared)
            result = SourceStudioQuaternion(x: result.x * scale, y: result.y * scale,
                                            z: result.z * scale, w: result.w * scale)
        }
        if !delta, bone.flags & 0x00100000 != 0 { result = aligned(result, to: bone.alignment) }
        guard [result.x, result.y, result.z, result.w].allSatisfy(\.isFinite) else { throw invalid(bone.index) }
        return result
    }

    private static func invalid(_ bone: Int) -> SourceStudioAnimationError {
        .nonFiniteFloat(field: "sampled animation rotation", offset: bone)
    }

    private static func quaternion(_ angles: [Float]) -> SourceStudioQuaternion {
        let sr = sin(angles[0] * 0.5), cr = cos(angles[0] * 0.5)
        let sp = sin(angles[1] * 0.5), cp = cos(angles[1] * 0.5)
        let sy = sin(angles[2] * 0.5), cy = cos(angles[2] * 0.5)
        return SourceStudioQuaternion(x: (sr * cp) * cy - (cr * sp) * sy,
            y: (cr * sp) * cy + (sr * cp) * sy,
            z: (cr * cp) * sy - (sr * sp) * cy,
            w: (cr * cp) * cy + (sr * sp) * sy)
    }

    private static func aligned(_ value: SourceStudioQuaternion,
                                to reference: SourceStudioQuaternion) -> SourceStudioQuaternion {
        let p = [reference.x, reference.y, reference.z, reference.w]
        let q = [value.x, value.y, value.z, value.w]
        var difference: Float = 0
        var sum: Float = 0
        for index in 0..<4 {
            difference += (p[index] - q[index]) * (p[index] - q[index])
            sum += (p[index] + q[index]) * (p[index] + q[index])
        }
        return difference > sum
            ? SourceStudioQuaternion(x: -value.x, y: -value.y, z: -value.z, w: -value.w) : value
    }
}
