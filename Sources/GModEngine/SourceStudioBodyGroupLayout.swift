/// Exact ordered `mstudiobodyparts_t` fields needed by Source body-group
/// queries and mutations. A layout is useful only after the host has proved
/// it came from the Entity's current Studio model; model names alone are not
/// sufficient evidence.
public enum SourceStudioBodyGroupLayoutError: Error, Equatable, Sendable {
    case invalidModelCount(bodyGroupID: Int, value: Int)
    case invalidModelSelectionBase(bodyGroupID: Int, value: Int32)
    case negativeBodyValue(Int)
    case negativeSelection(Int)
    case bodyValueOverflow
}

public struct SourceStudioBodyGroupLayout: Equatable, Sendable {
    public let bodyParts: [SourceStudioBodyGroupSelectionDescriptor]

    public init(
        bodyParts: [SourceStudioBodyGroupSelectionDescriptor]
    ) throws {
        for (bodyGroupID, bodyPart) in bodyParts.enumerated() {
            guard bodyPart.modelCount > 0 else {
                throw SourceStudioBodyGroupLayoutError.invalidModelCount(
                    bodyGroupID: bodyGroupID,
                    value: bodyPart.modelCount
                )
            }
            guard bodyPart.modelSelectionBase > 0 else {
                throw SourceStudioBodyGroupLayoutError
                    .invalidModelSelectionBase(
                        bodyGroupID: bodyGroupID,
                        value: bodyPart.modelSelectionBase
                    )
            }
        }
        self.bodyParts = bodyParts
    }

    public var bodyGroupCount: Int { bodyParts.count }

    /// Fixed Source SDK `GetBodygroup`: an invalid group or a group with only
    /// one submodel reads as zero; valid groups decode packed `m_nBody` using
    /// the Studio-authored base and model count.
    public func selection(
        forBodyGroupID bodyGroupID: Int,
        bodyValue: Int
    ) throws -> Int {
        guard bodyValue >= 0 else {
            throw SourceStudioBodyGroupLayoutError.negativeBodyValue(bodyValue)
        }
        guard bodyParts.indices.contains(bodyGroupID) else { return 0 }
        let bodyPart = bodyParts[bodyGroupID]
        guard bodyPart.modelCount > 1 else { return 0 }
        return (bodyValue / Int(bodyPart.modelSelectionBase)) %
            bodyPart.modelCount
    }

    /// Fixed Source SDK `SetBodygroup`: invalid group IDs and selections at or
    /// above the model count have no effect. Negative submodel IDs are outside
    /// the documented GLua contract and cannot enter canonical nonnegative
    /// `m_nBody`, so they fail transactionally instead of wrapping.
    public func bodyValue(
        settingBodyGroupID bodyGroupID: Int,
        to selection: Int,
        currentBodyValue: Int
    ) throws -> Int {
        guard currentBodyValue >= 0 else {
            throw SourceStudioBodyGroupLayoutError
                .negativeBodyValue(currentBodyValue)
        }
        guard selection >= 0 else {
            throw SourceStudioBodyGroupLayoutError.negativeSelection(selection)
        }
        guard bodyParts.indices.contains(bodyGroupID) else {
            return currentBodyValue
        }
        let bodyPart = bodyParts[bodyGroupID]
        guard selection < bodyPart.modelCount else {
            return currentBodyValue
        }

        let base = Int(bodyPart.modelSelectionBase)
        let currentSelection = (currentBodyValue / base) % bodyPart.modelCount
        let delta = selection - currentSelection
        let (scaledDelta, multiplyOverflow) = delta
            .multipliedReportingOverflow(by: base)
        guard !multiplyOverflow else {
            throw SourceStudioBodyGroupLayoutError.bodyValueOverflow
        }
        let (updated, addOverflow) = currentBodyValue
            .addingReportingOverflow(scaledDelta)
        guard !addOverflow, updated >= 0, updated <= Int(Int32.max) else {
            throw SourceStudioBodyGroupLayoutError.bodyValueOverflow
        }
        return updated
    }
}

/// Resolves one current model to verified Studio bodypart metadata. `nil`
/// means the exact bytes/attestation are unavailable; callers must preserve
/// that unsupported boundary rather than treating it as a zero-group model.
public typealias SourceCanonicalBodyGroupLayoutResolver = (
    _ model: SourceEntityModelReference
) throws -> SourceStudioBodyGroupLayout?
