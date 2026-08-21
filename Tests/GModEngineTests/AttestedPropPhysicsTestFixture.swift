import GModEngine

func makeAttestedPropPhysicsTestAsset(
    modelPath: String,
    massKilograms: Float = 12,
    solidIndex: Int = 0,
    mdlSHA256: String = String(repeating: "a", count: 64),
    phySHA256: String = String(repeating: "b", count: 64),
    studioChecksum: Int32 = 1_234
) throws -> SourceAttestedPropPhysicsAsset {
    let materialIndex = 7
    let vertices = [
        SourceVector3(-4, -6, -8),
        SourceVector3(12, -6, -8),
        SourceVector3(-4, 10, -8),
        SourceVector3(-4, -6, 14),
    ]
    let triangles = try [
        SourcePhysicsIndexedTriangle(
            first: 0, second: 2, third: 1, materialIndex: materialIndex
        ),
        SourcePhysicsIndexedTriangle(
            first: 0, second: 1, third: 3, materialIndex: materialIndex
        ),
        SourcePhysicsIndexedTriangle(
            first: 1, second: 2, third: 3, materialIndex: materialIndex
        ),
        SourcePhysicsIndexedTriangle(
            first: 2, second: 0, third: 3, materialIndex: materialIndex
        ),
    ]
    let shape = try SourcePhysicsShapeSnapshot(
        topology: .convexParts,
        parts: [SourcePhysicsMeshPartSnapshot(
            vertices: vertices,
            triangles: triangles
        )]
    )
    return try SourceAttestedPropPhysicsAsset(
        normalizedModelPath: modelPath,
        mdlSHA256: mdlSHA256,
        phySHA256: phySHA256,
        studioChecksum: studioChecksum,
        collisionProperty: SourceCollisionProperty(
            mins: SourceVector3(-4, -6, -8),
            maxs: SourceVector3(12, 10, 14)
        ),
        shapeEvidence: .independentlyAttested(shape),
        massProperties: SourcePhysicsMassProperties(
            massKilograms: massKilograms,
            principalInertia: SourceVector3(2, 3, 4)
        ),
        solidIndex: solidIndex,
        materialIndex: materialIndex,
        bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
            motionType: .dynamicBody,
            isGravityEnabled: true,
            isCollisionEnabled: true,
            startsAwake: true
        )
    )
}

func makeAttestedPropPhysicsTestResolver(
    asset: SourceAttestedPropPhysicsAsset
) -> SourceCanonicalPropPhysicsAssetResolver {
    { model in
        let normalized = try? SourceLogicalPath
            .normalize(model.path, allowEmpty: false)
            .lowercased()
        return normalized == asset.normalizedModelPath ? .valid(asset) : .invalid
    }
}
