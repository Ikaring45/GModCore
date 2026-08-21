/// Fail-closed conversion of GLua `Entity:SetBodyGroups` strings into Source's
/// packed `m_nBody` value. Selection bases and model counts come from the
/// decoded `mstudiobodyparts_t` records; no decimal-place approximation is
/// used.
public enum SourceStudioBodyGroupSelectionError: Error, Equatable, Sendable {
    case negativeCurrentBodyValue(Int)
    case invalidCharacter(Character, bodyGroupID: Int)
    case invalidSelection(bodyGroupID: Int, selection: Int, modelCount: Int)
    case invalidModelSelectionBase(bodyGroupID: Int, base: Int32)
    case bodyValueOverflow
}

/// The two Source `mstudiobodyparts_t` fields needed to convert a body-group
/// selection into packed `m_nBody`. Keeping this value independent of decoded
/// render geometry lets an exact, separately attested MDL header supply the
/// same semantics when its large render companions are not mounted.
public struct SourceStudioBodyGroupSelectionDescriptor: Equatable, Hashable,
    Sendable
{
    public let modelSelectionBase: Int32
    public let modelCount: Int

    public init(modelSelectionBase: Int32, modelCount: Int) {
        self.modelSelectionBase = modelSelectionBase
        self.modelCount = modelCount
    }
}

public enum SourceStudioBodyGroupSelection {
    /// Applies Source body-group characters against an exact ordered body-part
    /// layout. Callers remain responsible for proving where that layout came
    /// from; this function only implements the packed-value conversion.
    public static func bodyValue(
        applyingBodyGroups subModelIDs: String,
        to currentBodyValue: Int,
        bodyParts: [SourceStudioBodyGroupSelectionDescriptor]
    ) throws -> Int {
        guard currentBodyValue >= 0 else {
            throw SourceStudioBodyGroupSelectionError
                .negativeCurrentBodyValue(currentBodyValue)
        }

        var candidate = currentBodyValue
        for (bodyGroupID, character) in subModelIDs.enumerated() {
            let selection = try decodeBodyGroupCharacter(
                character,
                bodyGroupID: bodyGroupID
            )
            guard bodyParts.indices.contains(bodyGroupID) else { continue }

            let bodyPart = bodyParts[bodyGroupID]
            let modelCount = bodyPart.modelCount
            guard modelCount > 1 else { continue }
            guard selection < modelCount else {
                throw SourceStudioBodyGroupSelectionError.invalidSelection(
                    bodyGroupID: bodyGroupID,
                    selection: selection,
                    modelCount: modelCount
                )
            }

            let base = Int(bodyPart.modelSelectionBase)
            guard base > 0 else {
                throw SourceStudioBodyGroupSelectionError
                    .invalidModelSelectionBase(
                        bodyGroupID: bodyGroupID,
                        base: bodyPart.modelSelectionBase
                    )
            }
            let currentSelection = (candidate / base) % modelCount
            let delta = selection - currentSelection
            let (scaledDelta, multiplyOverflow) = delta
                .multipliedReportingOverflow(by: base)
            guard !multiplyOverflow else {
                throw SourceStudioBodyGroupSelectionError.bodyValueOverflow
            }
            let (updated, addOverflow) = candidate
                .addingReportingOverflow(scaledDelta)
            guard !addOverflow, updated >= 0, updated <= Int(Int32.max) else {
                throw SourceStudioBodyGroupSelectionError.bodyValueOverflow
            }
            candidate = updated
        }
        return candidate
    }

    private static func decodeBodyGroupCharacter(
        _ character: Character,
        bodyGroupID: Int
    ) throws -> Int {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            throw SourceStudioBodyGroupSelectionError.invalidCharacter(
                character,
                bodyGroupID: bodyGroupID
            )
        }
        switch scalar.value {
        case 48...57:
            return Int(scalar.value - 48)
        case 97...122:
            return Int(scalar.value - 97) + 10
        default:
            throw SourceStudioBodyGroupSelectionError.invalidCharacter(
                character,
                bodyGroupID: bodyGroupID
            )
        }
    }
}

public extension SourceStudioModelMeshSnapshot {
    /// Applies the supplied sub-model IDs in body-group order while retaining
    /// groups omitted from the string. Characters for IDs beyond the model's
    /// body-part table are decoded but otherwise have no effect, matching an
    /// invalid `SetBodygroup` ID. Body groups with one or fewer sub-models also
    /// have no effect.
    func bodyValue(
        applyingBodyGroups subModelIDs: String,
        to currentBodyValue: Int
    ) throws -> Int {
        try SourceStudioBodyGroupSelection.bodyValue(
            applyingBodyGroups: subModelIDs,
            to: currentBodyValue,
            bodyParts: bodyParts.map {
                SourceStudioBodyGroupSelectionDescriptor(
                    modelSelectionBase: $0.modelSelectionBase,
                    modelCount: $0.models.count
                )
            }
        )
    }
}
