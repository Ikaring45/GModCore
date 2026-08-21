import Foundation

public enum GModMapAllocationResource: String, Sendable, Equatable,
    CaseIterable
{
    case bspEncodedBytes = "BSP encoded bytes"
    case worldVertexWorkingBytes = "world vertex working bytes"
    case worldIndexWorkingBytes = "world index working bytes"
    case displacementVertexWorkingBytes = "displacement vertex working bytes"
    case displacementIndexWorkingBytes = "displacement index working bytes"
    case lightmapAtlasBytes = "lightmap atlas bytes"
}

public struct GModMapAllocationPolicyError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    public let resource: GModMapAllocationResource
    public let requestedByteCount: UInt64
    public let maximumByteCount: UInt64

    public init(
        resource: GModMapAllocationResource,
        requestedByteCount: UInt64,
        maximumByteCount: UInt64
    ) {
        self.resource = resource
        self.requestedByteCount = requestedByteCount
        self.maximumByteCount = maximumByteCount
    }

    public var description: String {
        "map allocation \(resource.rawValue) requested " +
            "\(requestedByteCount) bytes; cap \(maximumByteCount) bytes"
    }
}

/// One allocation policy shared by content-pack candidate validation, bundled
/// resource loading, and renderer-neutral world-mesh construction.
///
/// The checked-in reference maps measure 36,735,656 bytes (`gm_construct`) and
/// 47,430,424 bytes (`gm_flatgrass`). The 96 MiB BSP cap therefore leaves more
/// than 2x headroom over the current maximum. Derived working-set caps retain
/// several times the measured maxima (7,708,480 world-vertex bytes, 1,116,384
/// world-index bytes, 1,213,248 displacement-vertex bytes, and 503,808
/// displacement-index bytes). The 64 MiB lightmap cap is also above the
/// 23,101,440-byte largest reference atlas. Raising these limits for arbitrary
/// external maps is a future, device-tuned decision.
public struct GModMapAllocationPolicy: Sendable, Equatable {
    public static let iPadValidated = GModMapAllocationPolicy(
        maximumBSPEncodedByteCount: 96 * 1_024 * 1_024,
        maximumWorldVertexWorkingByteCount: 48 * 1_024 * 1_024,
        maximumWorldIndexWorkingByteCount: 32 * 1_024 * 1_024,
        maximumDisplacementVertexWorkingByteCount: 24 * 1_024 * 1_024,
        maximumDisplacementIndexWorkingByteCount: 16 * 1_024 * 1_024,
        maximumLightmapAtlasByteCount: 64 * 1_024 * 1_024
    )

    public let maximumBSPEncodedByteCount: UInt64
    public let maximumWorldVertexWorkingByteCount: UInt64
    public let maximumWorldIndexWorkingByteCount: UInt64
    public let maximumDisplacementVertexWorkingByteCount: UInt64
    public let maximumDisplacementIndexWorkingByteCount: UInt64
    public let maximumLightmapAtlasByteCount: UInt64

    public init(
        maximumBSPEncodedByteCount: UInt64,
        maximumWorldVertexWorkingByteCount: UInt64,
        maximumWorldIndexWorkingByteCount: UInt64,
        maximumDisplacementVertexWorkingByteCount: UInt64,
        maximumDisplacementIndexWorkingByteCount: UInt64,
        maximumLightmapAtlasByteCount: UInt64
    ) {
        self.maximumBSPEncodedByteCount = maximumBSPEncodedByteCount
        self.maximumWorldVertexWorkingByteCount =
            maximumWorldVertexWorkingByteCount
        self.maximumWorldIndexWorkingByteCount =
            maximumWorldIndexWorkingByteCount
        self.maximumDisplacementVertexWorkingByteCount =
            maximumDisplacementVertexWorkingByteCount
        self.maximumDisplacementIndexWorkingByteCount =
            maximumDisplacementIndexWorkingByteCount
        self.maximumLightmapAtlasByteCount = maximumLightmapAtlasByteCount
    }

    public func maximumByteCount(
        for resource: GModMapAllocationResource
    ) -> UInt64 {
        switch resource {
        case .bspEncodedBytes:
            return maximumBSPEncodedByteCount
        case .worldVertexWorkingBytes:
            return maximumWorldVertexWorkingByteCount
        case .worldIndexWorkingBytes:
            return maximumWorldIndexWorkingByteCount
        case .displacementVertexWorkingBytes:
            return maximumDisplacementVertexWorkingByteCount
        case .displacementIndexWorkingBytes:
            return maximumDisplacementIndexWorkingByteCount
        case .lightmapAtlasBytes:
            return maximumLightmapAtlasByteCount
        }
    }

    public func validate(
        _ resource: GModMapAllocationResource,
        requestedByteCount: UInt64
    ) throws {
        let maximum = maximumByteCount(for: resource)
        guard requestedByteCount <= maximum else {
            throw GModMapAllocationPolicyError(
                resource: resource,
                requestedByteCount: requestedByteCount,
                maximumByteCount: maximum
            )
        }
    }
}
