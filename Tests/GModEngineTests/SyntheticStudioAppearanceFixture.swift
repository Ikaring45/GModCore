import GModEngine

/// Explicit test-owned metadata, not an assertion about any shipped MDL.
/// Route fixtures that inject a model must supply its appearance as well as
/// selection counts now that stock Lua queries GetBodyGroups/GetSkin.
func makeSyntheticStudioBodyGroupLayout(
    model: SourceEntityModelReference,
    bodyParts: [SourceStudioBodyGroupSelectionDescriptor],
    checksum: Int32 = 0,
    skinFamilyCount: Int = 1
) throws -> SourceStudioBodyGroupLayout {
    let appearance = try SourceStudioModelAppearanceLayout(
        checksum: checksum, modelName: model.path, skinFamilyCount: skinFamilyCount,
        bodyGroups: bodyParts.enumerated().map { index, part in
            SourceStudioBodyGroupAppearance(id: index, name: "fixture_group_\(index)",
                modelSelectionBase: part.modelSelectionBase,
                submodelNames: (0..<part.modelCount).map { "fixture_submodel_\($0)" })
        })
    return try SourceStudioBodyGroupLayout(bodyParts: bodyParts, appearance: appearance)
}
