import Foundation
import GModLua

private final class GMLuaVectorValue: @unchecked Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
}

private final class GMLuaAngleValue: @unchecked Sendable {
    var pitch: Double
    var yaw: Double
    var roll: Double

    init(_ pitch: Double = 0, _ yaw: Double = 0, _ roll: Double = 0) {
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
    }
}

/// Native GLua Vector/Angle values installed on top of `GMLuaTypeSystem`.
///
/// Components live in mutable Swift payloads, so the public values remain real
/// userdata with the canonical `MetaName`/`MetaID` ABI rather than Lua tables
/// that merely resemble engine values.
public enum GMLuaVectorAngle {
    public static func install(into state: LuaState, typeSystem: GMLuaTypeSystem) throws {
        guard let vectorMetatable = typeSystem.metatable(named: "Vector"),
              let angleMetatable = typeSystem.metatable(named: "Angle") else {
            throw LuaError.runtime("GLua Vector/Angle metatables were not installed")
        }

        func set(
            _ value: LuaValue,
            named name: String,
            in metatable: LuaTable
        ) throws {
            try state.setRawTableValue(
                value,
                for: .string(LuaString(name)),
                in: metatable
            )
        }

        func method(
            _ name: String,
            in metatable: LuaTable,
            body: @escaping LuaNativeFunction
        ) throws {
            try set(
                .nativeFunction(LuaNativeFunctionBox(body, debugName: name)),
                named: name,
                in: metatable
            )
        }

        let vectorIndex = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [unowned state] arguments in
                    let value = try vectorPayload(arguments.first, function: "Vector.__index")
                    let key = arguments.indices.contains(1) ? arguments[1] : .nilValue
                    if let component = vectorComponent(key) {
                        return [.number(vectorValue(value, component: component))]
                    }
                    return [try state.rawTableValue(for: key, in: vectorMetatable)]
                },
                debugName: "Vector.__index"
            )
        )
        let vectorNewIndex = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    let value = try vectorPayload(arguments.first, function: "Vector.__newindex")
                    let key = arguments.indices.contains(1) ? arguments[1] : .nilValue
                    guard let component = vectorComponent(key) else {
                        throw LuaError.runtime("invalid Vector component '\(key.printable)'")
                    }
                    let number = try requiredNumber(arguments, index: 2, function: "Vector.__newindex")
                    setVectorValue(value, component: component, number: number)
                    return []
                },
                debugName: "Vector.__newindex"
            )
        )
        try set(vectorIndex, named: "__index", in: vectorMetatable)
        try set(vectorNewIndex, named: "__newindex", in: vectorMetatable)

        let angleIndex = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [unowned state] arguments in
                    let value = try anglePayload(arguments.first, function: "Angle.__index")
                    let key = arguments.indices.contains(1) ? arguments[1] : .nilValue
                    if let component = angleComponent(key) {
                        return [.number(angleValue(value, component: component))]
                    }
                    return [try state.rawTableValue(for: key, in: angleMetatable)]
                },
                debugName: "Angle.__index"
            )
        )
        let angleNewIndex = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    let value = try anglePayload(arguments.first, function: "Angle.__newindex")
                    let key = arguments.indices.contains(1) ? arguments[1] : .nilValue
                    guard let component = angleComponent(key) else {
                        throw LuaError.runtime("invalid Angle component '\(key.printable)'")
                    }
                    let number = try requiredNumber(arguments, index: 2, function: "Angle.__newindex")
                    setAngleValue(value, component: component, number: number)
                    return []
                },
                debugName: "Angle.__newindex"
            )
        )
        try set(angleIndex, named: "__index", in: angleMetatable)
        try set(angleNewIndex, named: "__newindex", in: angleMetatable)

        let vectorConstructor = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [unowned state, unowned typeSystem] arguments in
                    let components = try vectorConstructorComponents(arguments, state: state)
                    return [try makeVector(components.0, components.1, components.2, typeSystem: typeSystem)]
                },
                debugName: "Vector"
            )
        )
        let angleConstructor = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [unowned state, unowned typeSystem] arguments in
                    let components = try angleConstructorComponents(arguments, state: state)
                    return [try makeAngle(components.0, components.1, components.2, typeSystem: typeSystem)]
                },
                debugName: "Angle"
            )
        )
        state.setGlobal("Vector", value: vectorConstructor)
        state.setGlobal("Angle", value: angleConstructor)

        let vectorToString = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    let value = try vectorPayload(arguments.first, function: "Vector.__tostring")
                    return [.string(LuaString(format(value.x, value.y, value.z, decimals: 6)))]
                },
                debugName: "Vector.__tostring"
            )
        )
        let angleToString = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    let value = try anglePayload(arguments.first, function: "Angle.__tostring")
                    return [.string(LuaString(format(value.pitch, value.yaw, value.roll, decimals: 2)))]
                },
                debugName: "Angle.__tostring"
            )
        )
        try set(vectorToString, named: "__tostring", in: vectorMetatable)
        try set(angleToString, named: "__tostring", in: angleMetatable)

        let vectorEqual = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    guard arguments.count >= 2,
                          let lhs = try? vectorPayload(arguments[0], function: "Vector.__eq"),
                          let rhs = try? vectorPayload(arguments[1], function: "Vector.__eq") else {
                        return [.boolean(false)]
                    }
                    return [.boolean(lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z)]
                },
                debugName: "Vector.__eq"
            )
        )
        let angleEqual = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    guard arguments.count >= 2,
                          let lhs = try? anglePayload(arguments[0], function: "Angle.__eq"),
                          let rhs = try? anglePayload(arguments[1], function: "Angle.__eq") else {
                        return [.boolean(false)]
                    }
                    return [.boolean(
                        lhs.pitch == rhs.pitch && lhs.yaw == rhs.yaw && lhs.roll == rhs.roll
                    )]
                },
                debugName: "Angle.__eq"
            )
        )
        try set(vectorEqual, named: "__eq", in: vectorMetatable)
        try set(angleEqual, named: "__eq", in: angleMetatable)

        try installVectorOperators(
            state: state,
            typeSystem: typeSystem,
            metatable: vectorMetatable,
            set: set
        )
        try installAngleOperators(
            state: state,
            typeSystem: typeSystem,
            metatable: angleMetatable,
            set: set
        )
        try installVectorMethods(
            state: state,
            typeSystem: typeSystem,
            metatable: vectorMetatable,
            method: method
        )
        try installAngleMethods(
            state: state,
            typeSystem: typeSystem,
            metatable: angleMetatable,
            method: method
        )
        try installInterpolationGlobals(state: state, typeSystem: typeSystem)
    }

    private static func installVectorOperators(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        metatable: LuaTable,
        set: (LuaValue, String, LuaTable) throws -> Void
    ) throws {
        func install(_ name: String, _ body: @escaping LuaNativeFunction) throws {
            try set(.nativeFunction(LuaNativeFunctionBox(body, debugName: "Vector.\(name)")), name, metatable)
        }

        try install("__add") { [unowned typeSystem] arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector.__add")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector.__add")
            return [try makeVector(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z, typeSystem: typeSystem)]
        }
        try install("__sub") { [unowned typeSystem] arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector.__sub")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector.__sub")
            return [try makeVector(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z, typeSystem: typeSystem)]
        }
        try install("__unm") { [unowned typeSystem] arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector.__unm")
            return [try makeVector(-value.x, -value.y, -value.z, typeSystem: typeSystem)]
        }
        try install("__mul") { [unowned typeSystem] arguments in
            guard arguments.count >= 2 else {
                throw LuaError.runtime("bad arguments to Vector multiplication")
            }
            if let lhs = try? vectorPayload(arguments[0], function: "Vector.__mul") {
                if let rhs = try? vectorPayload(arguments[1], function: "Vector.__mul") {
                    return [try makeVector(lhs.x * rhs.x, lhs.y * rhs.y, lhs.z * rhs.z, typeSystem: typeSystem)]
                }
                let scalar = try number(from: arguments[1], function: "Vector.__mul", index: 1)
                return [try makeVector(lhs.x * scalar, lhs.y * scalar, lhs.z * scalar, typeSystem: typeSystem)]
            }
            let scalar = try number(from: arguments[0], function: "Vector.__mul", index: 0)
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector.__mul")
            return [try makeVector(rhs.x * scalar, rhs.y * scalar, rhs.z * scalar, typeSystem: typeSystem)]
        }
        try install("__div") { [unowned typeSystem] arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector.__div")
            guard arguments.count >= 2 else {
                throw LuaError.runtime("bad argument #2 to 'Vector.__div' (number or Vector expected)")
            }
            if let rhs = try? vectorPayload(arguments[1], function: "Vector.__div") {
                return [try makeVector(lhs.x / rhs.x, lhs.y / rhs.y, lhs.z / rhs.z, typeSystem: typeSystem)]
            }
            let scalar = try number(from: arguments[1], function: "Vector.__div", index: 1)
            return [try makeVector(lhs.x / scalar, lhs.y / scalar, lhs.z / scalar, typeSystem: typeSystem)]
        }
    }

    private static func installAngleOperators(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        metatable: LuaTable,
        set: (LuaValue, String, LuaTable) throws -> Void
    ) throws {
        func install(_ name: String, _ body: @escaping LuaNativeFunction) throws {
            try set(.nativeFunction(LuaNativeFunctionBox(body, debugName: "Angle.\(name)")), name, metatable)
        }

        try install("__add") { [unowned typeSystem] arguments in
            let lhs = try angleArgument(arguments, index: 0, function: "Angle.__add")
            let rhs = try angleArgument(arguments, index: 1, function: "Angle.__add")
            return [try makeAngle(
                lhs.pitch + rhs.pitch,
                lhs.yaw + rhs.yaw,
                lhs.roll + rhs.roll,
                typeSystem: typeSystem
            )]
        }
        try install("__sub") { [unowned typeSystem] arguments in
            let lhs = try angleArgument(arguments, index: 0, function: "Angle.__sub")
            let rhs = try angleArgument(arguments, index: 1, function: "Angle.__sub")
            return [try makeAngle(
                lhs.pitch - rhs.pitch,
                lhs.yaw - rhs.yaw,
                lhs.roll - rhs.roll,
                typeSystem: typeSystem
            )]
        }
        try install("__unm") { [unowned typeSystem] arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle.__unm")
            return [try makeAngle(-value.pitch, -value.yaw, -value.roll, typeSystem: typeSystem)]
        }
        try install("__mul") { [unowned typeSystem] arguments in
            guard arguments.count >= 2 else {
                throw LuaError.runtime("bad arguments to Angle multiplication")
            }
            if let lhs = try? anglePayload(arguments[0], function: "Angle.__mul") {
                let scalar = try number(from: arguments[1], function: "Angle.__mul", index: 1)
                return [try makeAngle(
                    lhs.pitch * scalar,
                    lhs.yaw * scalar,
                    lhs.roll * scalar,
                    typeSystem: typeSystem
                )]
            }
            let scalar = try number(from: arguments[0], function: "Angle.__mul", index: 0)
            let rhs = try angleArgument(arguments, index: 1, function: "Angle.__mul")
            return [try makeAngle(
                rhs.pitch * scalar,
                rhs.yaw * scalar,
                rhs.roll * scalar,
                typeSystem: typeSystem
            )]
        }
        try install("__div") { [unowned typeSystem] arguments in
            let lhs = try angleArgument(arguments, index: 0, function: "Angle.__div")
            let scalar = try requiredNumber(arguments, index: 1, function: "Angle.__div")
            return [try makeAngle(
                lhs.pitch / scalar,
                lhs.yaw / scalar,
                lhs.roll / scalar,
                typeSystem: typeSystem
            )]
        }
    }

    private static func installVectorMethods(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        metatable: LuaTable,
        method: (String, LuaTable, @escaping LuaNativeFunction) throws -> Void
    ) throws {
        try method("Add", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Add")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:Add")
            lhs.x += rhs.x; lhs.y += rhs.y; lhs.z += rhs.z
            return []
        }
        try method("Sub", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Sub")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:Sub")
            lhs.x -= rhs.x; lhs.y -= rhs.y; lhs.z -= rhs.z
            return []
        }
        try method("Mul", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Mul")
            guard arguments.count >= 2 else {
                throw LuaError.runtime("bad argument #1 to 'Vector:Mul' (number or Vector expected)")
            }
            if let rhs = try? vectorPayload(arguments[1], function: "Vector:Mul") {
                lhs.x *= rhs.x; lhs.y *= rhs.y; lhs.z *= rhs.z
            } else {
                let scalar = try number(from: arguments[1], function: "Vector:Mul", index: 1)
                lhs.x *= scalar; lhs.y *= scalar; lhs.z *= scalar
            }
            return []
        }
        try method("Div", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Div")
            guard arguments.count >= 2 else {
                throw LuaError.runtime("bad argument #1 to 'Vector:Div' (number or Vector expected)")
            }
            if let rhs = try? vectorPayload(arguments[1], function: "Vector:Div") {
                lhs.x /= rhs.x; lhs.y /= rhs.y; lhs.z /= rhs.z
            } else {
                let scalar = try number(from: arguments[1], function: "Vector:Div", index: 1)
                lhs.x /= scalar; lhs.y /= scalar; lhs.z /= scalar
            }
            return []
        }
        try method("LengthSqr", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:LengthSqr")
            return [.number(lengthSquared(value))]
        }
        try method("Length", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Length")
            return [.number(lengthSquared(value).squareRoot())]
        }
        try method("Length2DSqr", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Length2DSqr")
            return [.number(value.x * value.x + value.y * value.y)]
        }
        try method("Length2D", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Length2D")
            return [.number((value.x * value.x + value.y * value.y).squareRoot())]
        }
        try method("Distance", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Distance")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:Distance")
            return [.number(distanceSquared(lhs, rhs).squareRoot())]
        }
        try method("DistToSqr", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:DistToSqr")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:DistToSqr")
            return [.number(distanceSquared(lhs, rhs))]
        }
        try method("Dot", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Dot")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:Dot")
            return [.number(lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z)]
        }
        try method("Cross", metatable) { [unowned typeSystem] arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Cross")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:Cross")
            return [try makeVector(
                lhs.y * rhs.z - lhs.z * rhs.y,
                lhs.z * rhs.x - lhs.x * rhs.z,
                lhs.x * rhs.y - lhs.y * rhs.x,
                typeSystem: typeSystem
            )]
        }
        try method("GetNormalized", metatable) { [unowned typeSystem] arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:GetNormalized")
            let length = lengthSquared(value).squareRoot()
            guard length != 0 else {
                return [try makeVector(0, 0, 0, typeSystem: typeSystem)]
            }
            return [try makeVector(
                value.x / length,
                value.y / length,
                value.z / length,
                typeSystem: typeSystem
            )]
        }
        try method("Normalize", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Normalize")
            let length = lengthSquared(value).squareRoot()
            if length != 0 {
                value.x /= length; value.y /= length; value.z /= length
            }
            return [.number(length)]
        }
        try method("IsZero", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:IsZero")
            return [.boolean(value.x == 0 && value.y == 0 && value.z == 0)]
        }
        try method("Unpack", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Unpack")
            return [.number(value.x), .number(value.y), .number(value.z)]
        }
        try method("Distance2DSqr", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Distance2DSqr")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:Distance2DSqr")
            let x = lhs.x - rhs.x
            let y = lhs.y - rhs.y
            return [.number(x * x + y * y)]
        }
        try method("Distance2D", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:Distance2D")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:Distance2D")
            let x = lhs.x - rhs.x
            let y = lhs.y - rhs.y
            return [.number((x * x + y * y).squareRoot())]
        }
        try method("DotProduct", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:DotProduct")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:DotProduct")
            return [.number(lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z)]
        }
        try method("GetNegated", metatable) { [unowned typeSystem] arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:GetNegated")
            return [try makeVector(-value.x, -value.y, -value.z, typeSystem: typeSystem)]
        }
        try method("GetNormal", metatable) { [unowned typeSystem] arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:GetNormal")
            let length = lengthSquared(value).squareRoot()
            guard length != 0 else {
                return [try makeVector(0, 0, 0, typeSystem: typeSystem)]
            }
            return [try makeVector(
                value.x / length,
                value.y / length,
                value.z / length,
                typeSystem: typeSystem
            )]
        }
        try method("IsEqualTol", metatable) { arguments in
            let lhs = try vectorArgument(arguments, index: 0, function: "Vector:IsEqualTol")
            let rhs = try vectorArgument(arguments, index: 1, function: "Vector:IsEqualTol")
            let tolerance = try requiredNumber(arguments, index: 2, function: "Vector:IsEqualTol")
            return [.boolean(
                abs(lhs.x - rhs.x) <= tolerance &&
                abs(lhs.y - rhs.y) <= tolerance &&
                abs(lhs.z - rhs.z) <= tolerance
            )]
        }
        try method("Negate", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Negate")
            value.x = -value.x; value.y = -value.y; value.z = -value.z
            return []
        }
        try method("Set", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Set")
            let source = try vectorArgument(arguments, index: 1, function: "Vector:Set")
            value.x = source.x; value.y = source.y; value.z = source.z
            return []
        }
        try method("SetUnpacked", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:SetUnpacked")
            value.x = try requiredNumber(arguments, index: 1, function: "Vector:SetUnpacked")
            value.y = try requiredNumber(arguments, index: 2, function: "Vector:SetUnpacked")
            value.z = try requiredNumber(arguments, index: 3, function: "Vector:SetUnpacked")
            return []
        }
        try method("Zero", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Zero")
            value.x = 0; value.y = 0; value.z = 0
            return []
        }
        try method("WithinAABox", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:WithinAABox")
            let start = try vectorArgument(arguments, index: 1, function: "Vector:WithinAABox")
            let end = try vectorArgument(arguments, index: 2, function: "Vector:WithinAABox")
            return [.boolean(
                value.x >= min(start.x, end.x) && value.x <= max(start.x, end.x) &&
                value.y >= min(start.y, end.y) && value.y <= max(start.y, end.y) &&
                value.z >= min(start.z, end.z) && value.z <= max(start.z, end.z)
            )]
        }
        try method("ToTable", metatable) { [unowned state] arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:ToTable")
            return [.table(try componentTable(
                firstName: "x",
                first: value.x,
                secondName: "y",
                second: value.y,
                thirdName: "z",
                third: value.z,
                state: state
            ))]
        }
        try method("Angle", metatable) { [unowned typeSystem] arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Angle")
            let angle = directionAngle(value)
            return [try makeAngle(angle.0, angle.1, 0, typeSystem: typeSystem)]
        }
        try method("AngleEx", metatable) { [unowned typeSystem] arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:AngleEx")
            let up = try vectorArgument(arguments, index: 1, function: "Vector:AngleEx")
            let angle = directionAngle(value, up: up)
            return [try makeAngle(angle.0, angle.1, angle.2, typeSystem: typeSystem)]
        }
        try method("Rotate", metatable) { arguments in
            let value = try vectorArgument(arguments, index: 0, function: "Vector:Rotate")
            let angle = try angleArgument(arguments, index: 1, function: "Vector:Rotate")
            let basis = basisVectors(angle)
            let x = basis.forward.0 * value.x - basis.right.0 * value.y + basis.up.0 * value.z
            let y = basis.forward.1 * value.x - basis.right.1 * value.y + basis.up.1 * value.z
            let z = basis.forward.2 * value.x - basis.right.2 * value.y + basis.up.2 * value.z
            value.x = x; value.y = y; value.z = z
            return []
        }
    }

    private static func installAngleMethods(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        metatable: LuaTable,
        method: (String, LuaTable, @escaping LuaNativeFunction) throws -> Void
    ) throws {
        try method("Add", metatable) { arguments in
            let lhs = try angleArgument(arguments, index: 0, function: "Angle:Add")
            let rhs = try angleArgument(arguments, index: 1, function: "Angle:Add")
            lhs.pitch += rhs.pitch; lhs.yaw += rhs.yaw; lhs.roll += rhs.roll
            return []
        }
        try method("Sub", metatable) { arguments in
            let lhs = try angleArgument(arguments, index: 0, function: "Angle:Sub")
            let rhs = try angleArgument(arguments, index: 1, function: "Angle:Sub")
            lhs.pitch -= rhs.pitch; lhs.yaw -= rhs.yaw; lhs.roll -= rhs.roll
            return []
        }
        try method("Mul", metatable) { arguments in
            let lhs = try angleArgument(arguments, index: 0, function: "Angle:Mul")
            let scalar = try requiredNumber(arguments, index: 1, function: "Angle:Mul")
            lhs.pitch *= scalar; lhs.yaw *= scalar; lhs.roll *= scalar
            return []
        }
        try method("Div", metatable) { arguments in
            let lhs = try angleArgument(arguments, index: 0, function: "Angle:Div")
            let scalar = try requiredNumber(arguments, index: 1, function: "Angle:Div")
            lhs.pitch /= scalar; lhs.yaw /= scalar; lhs.roll /= scalar
            return []
        }
        try method("Normalize", metatable) { arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle:Normalize")
            value.pitch = normalizedAngle(value.pitch)
            value.yaw = normalizedAngle(value.yaw)
            value.roll = normalizedAngle(value.roll)
            return []
        }
        try method("Unpack", metatable) { arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle:Unpack")
            return [.number(value.pitch), .number(value.yaw), .number(value.roll)]
        }
        try method("Forward", metatable) { [unowned typeSystem] arguments in
            let angle = try angleArgument(arguments, index: 0, function: "Angle:Forward")
            let basis = basisVectors(angle)
            return [try makeVector(basis.forward.0, basis.forward.1, basis.forward.2, typeSystem: typeSystem)]
        }
        try method("Right", metatable) { [unowned typeSystem] arguments in
            let angle = try angleArgument(arguments, index: 0, function: "Angle:Right")
            let basis = basisVectors(angle)
            return [try makeVector(basis.right.0, basis.right.1, basis.right.2, typeSystem: typeSystem)]
        }
        try method("Up", metatable) { [unowned typeSystem] arguments in
            let angle = try angleArgument(arguments, index: 0, function: "Angle:Up")
            let basis = basisVectors(angle)
            return [try makeVector(basis.up.0, basis.up.1, basis.up.2, typeSystem: typeSystem)]
        }
        try method("IsEqualTol", metatable) { arguments in
            let lhs = try angleArgument(arguments, index: 0, function: "Angle:IsEqualTol")
            let rhs = try angleArgument(arguments, index: 1, function: "Angle:IsEqualTol")
            let tolerance = try requiredNumber(arguments, index: 2, function: "Angle:IsEqualTol")
            return [.boolean(
                abs(lhs.pitch - rhs.pitch) <= tolerance &&
                abs(lhs.yaw - rhs.yaw) <= tolerance &&
                abs(lhs.roll - rhs.roll) <= tolerance
            )]
        }
        try method("IsZero", metatable) { arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle:IsZero")
            return [.boolean(value.pitch == 0 && value.yaw == 0 && value.roll == 0)]
        }
        try method("Set", metatable) { arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle:Set")
            let source = try angleArgument(arguments, index: 1, function: "Angle:Set")
            value.pitch = source.pitch; value.yaw = source.yaw; value.roll = source.roll
            return []
        }
        try method("SetUnpacked", metatable) { arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle:SetUnpacked")
            value.pitch = try requiredNumber(arguments, index: 1, function: "Angle:SetUnpacked")
            value.yaw = try requiredNumber(arguments, index: 2, function: "Angle:SetUnpacked")
            value.roll = try requiredNumber(arguments, index: 3, function: "Angle:SetUnpacked")
            return []
        }
        try method("Zero", metatable) { arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle:Zero")
            value.pitch = 0; value.yaw = 0; value.roll = 0
            return []
        }
        try method("ToTable", metatable) { [unowned state] arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle:ToTable")
            return [.table(try componentTable(
                firstName: "p",
                first: value.pitch,
                secondName: "y",
                second: value.yaw,
                thirdName: "r",
                third: value.roll,
                state: state
            ))]
        }
        try method("RotateAroundAxis", metatable) { arguments in
            let value = try angleArgument(arguments, index: 0, function: "Angle:RotateAroundAxis")
            let axis = try vectorArgument(arguments, index: 1, function: "Angle:RotateAroundAxis")
            let degrees = try requiredNumber(arguments, index: 2, function: "Angle:RotateAroundAxis")
            let basis = basisVectors(value)
            let forward = rotate(
                basis.forward,
                around: (axis.x, axis.y, axis.z),
                degrees: degrees
            )
            let up = rotate(
                basis.up,
                around: (axis.x, axis.y, axis.z),
                degrees: degrees
            )
            let converted = directionAngle(forward, up: up)
            value.pitch = converted.0
            value.yaw = converted.1
            value.roll = converted.2
            return []
        }
    }

    private static func installInterpolationGlobals(
        state: LuaState,
        typeSystem: GMLuaTypeSystem
    ) throws {
        state.setGlobal(
            "LerpVector",
            value: .nativeFunction(
                LuaNativeFunctionBox(
                    { [unowned typeSystem] arguments in
                        let fraction = try requiredNumber(arguments, index: 0, function: "LerpVector")
                        let from = try vectorArgument(arguments, index: 1, function: "LerpVector")
                        let to = try vectorArgument(arguments, index: 2, function: "LerpVector")
                        return [try makeVector(
                            from.x + (to.x - from.x) * fraction,
                            from.y + (to.y - from.y) * fraction,
                            from.z + (to.z - from.z) * fraction,
                            typeSystem: typeSystem
                        )]
                    },
                    debugName: "LerpVector"
                )
            )
        )
        state.setGlobal(
            "LerpAngle",
            value: .nativeFunction(
                LuaNativeFunctionBox(
                    { [unowned typeSystem] arguments in
                        let fraction = try requiredNumber(arguments, index: 0, function: "LerpAngle")
                        let from = try angleArgument(arguments, index: 1, function: "LerpAngle")
                        let to = try angleArgument(arguments, index: 2, function: "LerpAngle")
                        return [try makeAngle(
                            from.pitch + normalizedAngle(to.pitch - from.pitch) * fraction,
                            from.yaw + normalizedAngle(to.yaw - from.yaw) * fraction,
                            from.roll + normalizedAngle(to.roll - from.roll) * fraction,
                            typeSystem: typeSystem
                        )]
                    },
                    debugName: "LerpAngle"
                )
            )
        )
    }

    private static func vectorConstructorComponents(
        _ arguments: [LuaValue],
        state: LuaState
    ) throws -> (Double, Double, Double) {
        guard let first = arguments.first, !isNil(first) else { return (0, 0, 0) }
        if arguments.count == 1 {
            if let value = try? vectorPayload(first, function: "Vector") {
                return (value.x, value.y, value.z)
            }
            if case let .string(string) = first {
                return parsedTriple(string.utf8String) ?? (0, 0, 0)
            }
            if case let .table(table) = first {
                let x = try tableNumber(table, primary: "x", fallback: "r", state: state)
                let y = try tableNumber(table, primary: "y", fallback: "g", state: state)
                let z = try tableNumber(table, primary: "z", fallback: "b", state: state)
                if x != nil || y != nil || z != nil { return (x ?? 0, y ?? 0, z ?? 0) }
            }
        }
        return (
            try optionalComponent(arguments, index: 0, function: "Vector"),
            try optionalComponent(arguments, index: 1, function: "Vector"),
            try optionalComponent(arguments, index: 2, function: "Vector")
        )
    }

    private static func angleConstructorComponents(
        _ arguments: [LuaValue],
        state: LuaState
    ) throws -> (Double, Double, Double) {
        guard let first = arguments.first, !isNil(first) else { return (0, 0, 0) }
        if arguments.count == 1 {
            if let value = try? anglePayload(first, function: "Angle") {
                return (value.pitch, value.yaw, value.roll)
            }
            if case let .string(string) = first {
                return parsedTriple(string.utf8String) ?? (0, 0, 0)
            }
            if case let .table(table) = first {
                let pitch = try tableNumber(table, primary: "p", fallback: "pitch", state: state)
                let yaw = try tableNumber(table, primary: "y", fallback: "yaw", state: state)
                let roll = try tableNumber(table, primary: "r", fallback: "roll", state: state)
                if pitch != nil || yaw != nil || roll != nil {
                    return (pitch ?? 0, yaw ?? 0, roll ?? 0)
                }
            }
        }
        return (
            try optionalComponent(arguments, index: 0, function: "Angle"),
            try optionalComponent(arguments, index: 1, function: "Angle"),
            try optionalComponent(arguments, index: 2, function: "Angle")
        )
    }

    private static func tableNumber(
        _ table: LuaTable,
        primary: String,
        fallback: String,
        state: LuaState
    ) throws -> Double? {
        let first = try state.rawTableValue(for: .string(LuaString(primary)), in: table)
        if !isNil(first) { return try number(from: first, function: "Vector/Angle", index: 0) }
        let second = try state.rawTableValue(for: .string(LuaString(fallback)), in: table)
        if !isNil(second) { return try number(from: second, function: "Vector/Angle", index: 0) }
        return nil
    }

    private static func parsedTriple(_ source: String) -> (Double, Double, Double)? {
        let fields = source.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 3,
              let first = Double(fields[0]),
              let second = Double(fields[1]),
              let third = Double(fields[2]) else { return nil }
        return (first, second, third)
    }

    private static func optionalComponent(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Double {
        guard arguments.indices.contains(index), !isNil(arguments[index]) else { return 0 }
        return try number(from: arguments[index], function: function, index: index)
    }

    private static func requiredNumber(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Double {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' (number expected, got no value)"
            )
        }
        return try number(from: arguments[index], function: function, index: index)
    }

    private static func number(from value: LuaValue, function: String, index: Int) throws -> Double {
        switch value {
        case let .number(number): return number
        case let .string(string):
            if let parsed = Double(string.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
            fallthrough
        default:
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' " +
                "(number expected, got \(value.typeName))"
            )
        }
    }

    private static func vectorArgument(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> GMLuaVectorValue {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' (Vector expected, got no value)"
            )
        }
        return try vectorPayload(arguments[index], function: function)
    }

    private static func angleArgument(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> GMLuaAngleValue {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' (Angle expected, got no value)"
            )
        }
        return try anglePayload(arguments[index], function: function)
    }

    private static func vectorPayload(
        _ value: LuaValue?,
        function: String
    ) throws -> GMLuaVectorValue {
        guard let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.metaName == "Vector",
              let payload = object.payload as? GMLuaVectorValue else {
            throw LuaError.runtime(
                "bad argument to '\(function)' (Vector expected, got \(value?.typeName ?? "no value"))"
            )
        }
        return payload
    }

    private static func anglePayload(
        _ value: LuaValue?,
        function: String
    ) throws -> GMLuaAngleValue {
        guard let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.metaName == "Angle",
              let payload = object.payload as? GMLuaAngleValue else {
            throw LuaError.runtime(
                "bad argument to '\(function)' (Angle expected, got \(value?.typeName ?? "no value"))"
            )
        }
        return payload
    }

    /// Copies a Lua Vector into transport-safe scalar components. Network
    /// registries must never retain state-local userdata or its mutable
    /// payload across realm boundaries.
    static func networkVectorComponents(
        from value: LuaValue,
        function: String
    ) throws -> (Double, Double, Double) {
        let payload = try vectorPayload(value, function: function)
        return (payload.x, payload.y, payload.z)
    }

    /// Copies a Lua Angle into transport-safe scalar components.
    static func networkAngleComponents(
        from value: LuaValue,
        function: String
    ) throws -> (Double, Double, Double) {
        let payload = try anglePayload(value, function: function)
        return (payload.pitch, payload.yaw, payload.roll)
    }

    static func makeNetworkVector(
        _ x: Double,
        _ y: Double,
        _ z: Double,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try makeVector(x, y, z, typeSystem: typeSystem)
    }

    static func makeNetworkAngle(
        _ pitch: Double,
        _ yaw: Double,
        _ roll: Double,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try makeAngle(pitch, yaw, roll, typeSystem: typeSystem)
    }

    private static func makeVector(
        _ x: Double,
        _ y: Double,
        _ z: Double,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try typeSystem.makeObject(metaName: "Vector", payload: GMLuaVectorValue(x, y, z))
    }

    private static func makeAngle(
        _ pitch: Double,
        _ yaw: Double,
        _ roll: Double,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try typeSystem.makeObject(metaName: "Angle", payload: GMLuaAngleValue(pitch, yaw, roll))
    }

    private enum VectorComponent { case x, y, z }
    private enum AngleComponent { case pitch, yaw, roll }

    private static func vectorComponent(_ key: LuaValue) -> VectorComponent? {
        switch key {
        case let .number(index):
            if index == 1 { return .x }
            if index == 2 { return .y }
            if index == 3 { return .z }
        case let .string(name):
            switch name.utf8String {
            case "x", "X", "r": return .x
            case "y", "Y", "g": return .y
            case "z", "Z", "b": return .z
            default: break
            }
        default: break
        }
        return nil
    }

    private static func angleComponent(_ key: LuaValue) -> AngleComponent? {
        switch key {
        case let .number(index):
            if index == 1 { return .pitch }
            if index == 2 { return .yaw }
            if index == 3 { return .roll }
        case let .string(name):
            switch name.utf8String {
            case "p", "pitch", "x": return .pitch
            case "y", "yaw": return .yaw
            case "r", "roll", "z": return .roll
            default: break
            }
        default: break
        }
        return nil
    }

    private static func vectorValue(_ value: GMLuaVectorValue, component: VectorComponent) -> Double {
        switch component { case .x: return value.x; case .y: return value.y; case .z: return value.z }
    }

    private static func setVectorValue(
        _ value: GMLuaVectorValue,
        component: VectorComponent,
        number: Double
    ) {
        switch component { case .x: value.x = number; case .y: value.y = number; case .z: value.z = number }
    }

    private static func angleValue(_ value: GMLuaAngleValue, component: AngleComponent) -> Double {
        switch component {
        case .pitch: return value.pitch
        case .yaw: return value.yaw
        case .roll: return value.roll
        }
    }

    private static func setAngleValue(
        _ value: GMLuaAngleValue,
        component: AngleComponent,
        number: Double
    ) {
        switch component {
        case .pitch: value.pitch = number
        case .yaw: value.yaw = number
        case .roll: value.roll = number
        }
    }

    private static func lengthSquared(_ value: GMLuaVectorValue) -> Double {
        value.x * value.x + value.y * value.y + value.z * value.z
    }

    private static func distanceSquared(_ lhs: GMLuaVectorValue, _ rhs: GMLuaVectorValue) -> Double {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        let z = lhs.z - rhs.z
        return x * x + y * y + z * z
    }

    private static func componentTable(
        firstName: String,
        first: Double,
        secondName: String,
        second: Double,
        thirdName: String,
        third: Double,
        state: LuaState
    ) throws -> LuaTable {
        let table = LuaTable()
        try state.setRawTableValue(
            .number(first),
            for: .string(LuaString(firstName)),
            in: table
        )
        try state.setRawTableValue(
            .number(second),
            for: .string(LuaString(secondName)),
            in: table
        )
        try state.setRawTableValue(
            .number(third),
            for: .string(LuaString(thirdName)),
            in: table
        )
        return table
    }

    private static func directionAngle(
        _ forward: GMLuaVectorValue,
        up: GMLuaVectorValue? = nil
    ) -> (Double, Double, Double) {
        directionAngle(
            (forward.x, forward.y, forward.z),
            up: up.map { ($0.x, $0.y, $0.z) }
        )
    }

    private static func directionAngle(
        _ forward: (Double, Double, Double),
        up: (Double, Double, Double)? = nil
    ) -> (Double, Double, Double) {
        let length = (forward.0 * forward.0 + forward.1 * forward.1 + forward.2 * forward.2)
            .squareRoot()
        let x = length == 0 ? 0 : forward.0 / length
        let y = length == 0 ? 0 : forward.1 / length
        let z = length == 0 ? 0 : forward.2 / length
        let pitch = atan2(-z, (x * x + y * y).squareRoot()) * 180 / .pi
        let yaw = atan2(y, x) * 180 / .pi
        guard let up else { return (pitch, yaw, 0) }

        let pitchRadians = pitch * .pi / 180
        let yawRadians = yaw * .pi / 180
        let sp = sin(pitchRadians), cp = cos(pitchRadians)
        let sy = sin(yawRadians), cy = cos(yawRadians)
        let rightAtZeroRoll = (sy, -cy, 0.0)
        let upAtZeroRoll = (sp * cy, sp * sy, cp)
        let sine = up.0 * rightAtZeroRoll.0 +
            up.1 * rightAtZeroRoll.1 +
            up.2 * rightAtZeroRoll.2
        let cosine = up.0 * upAtZeroRoll.0 +
            up.1 * upAtZeroRoll.1 +
            up.2 * upAtZeroRoll.2
        let roll = atan2(sine, cosine) * 180 / .pi
        return (pitch, yaw, roll)
    }

    private static func rotate(
        _ value: (Double, Double, Double),
        around axis: (Double, Double, Double),
        degrees: Double
    ) -> (Double, Double, Double) {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let dot = axis.0 * value.0 + axis.1 * value.1 + axis.2 * value.2
        let cross = (
            axis.1 * value.2 - axis.2 * value.1,
            axis.2 * value.0 - axis.0 * value.2,
            axis.0 * value.1 - axis.1 * value.0
        )
        let scale = dot * (1 - cosine)
        return (
            value.0 * cosine + cross.0 * sine + axis.0 * scale,
            value.1 * cosine + cross.1 * sine + axis.1 * scale,
            value.2 * cosine + cross.2 * sine + axis.2 * scale
        )
    }

    private static func normalizedAngle(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        var result = value.truncatingRemainder(dividingBy: 360)
        if result >= 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }

    private static func basisVectors(
        _ angle: GMLuaAngleValue
    ) -> (
        forward: (Double, Double, Double),
        right: (Double, Double, Double),
        up: (Double, Double, Double)
    ) {
        let pitch = angle.pitch * .pi / 180
        let yaw = angle.yaw * .pi / 180
        let roll = angle.roll * .pi / 180
        let sp = sin(pitch), cp = cos(pitch)
        let sy = sin(yaw), cy = cos(yaw)
        let sr = sin(roll), cr = cos(roll)
        return (
            (cp * cy, cp * sy, -sp),
            (-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp),
            (cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp)
        )
    }

    private static func format(_ first: Double, _ second: Double, _ third: Double, decimals: Int) -> String {
        let specifier = "%.\(decimals)f %.\(decimals)f %.\(decimals)f"
        return String(
            format: specifier,
            locale: Locale(identifier: "en_US_POSIX"),
            first,
            second,
            third
        )
    }

    private static func isNil(_ value: LuaValue) -> Bool {
        if case .nilValue = value { return true }
        return false
    }
}
