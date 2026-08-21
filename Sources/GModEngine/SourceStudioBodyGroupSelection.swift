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
        guard currentBodyValue >= 0 else {
            throw SourceStudioBodyGroupSelectionError
                .negativeCurrentBodyValue(currentBodyValue)
        }

        var candidate = currentBodyValue
        for (bodyGroupID, character) in subModelIDs.enumerated() {
            let selection = try Self.decodeBodyGroupCharacter(
                character,
                bodyGroupID: bodyGroupID
            )
            guard bodyParts.indices.contains(bodyGroupID) else { continue }

            let bodyPart = bodyParts[bodyGroupID]
            let modelCount = bodyPart.models.count
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
            let (scaledDelta, multiplyOverflow) = delta.multipliedReportingOverflow(by: base)
            guard !multiplyOverflow else {
                throw SourceStudioBodyGroupSelectionError.bodyValueOverflow
            }
            let (updated, addOverflow) = candidate.addingReportingOverflow(scaledDelta)
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
