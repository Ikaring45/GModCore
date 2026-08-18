enum LuaTableKey:
    Hashable
{
    case string(String)
    case number(Double)
    case boolean(Bool)
}

public final class LuaTable {

    private var storage:
        [LuaTableKey: LuaValue] = [:]

    public var metatable:
        LuaTable?

    public init() {
    }

    // MARK: - Raw access

    func rawValue(
        for key: LuaValue
    ) throws -> LuaValue {

        let tableKey =
            try makeKey(
                from: key
            )

        return storage[
            tableKey
        ] ?? .nilValue
    }

    func rawSetValue(
        _ value: LuaValue,
        for key: LuaValue
    ) throws {

        let tableKey =
            try makeKey(
                from: key
            )

        set(
            value,
            for:
                tableKey
        )
    }

    func rawValue(
        forString key: String
    ) -> LuaValue {

        storage[
            .string(key)
        ] ?? .nilValue
    }

    func rawSetValue(
        _ value: LuaValue,
        forString key: String
    ) {

        set(
            value,
            for:
                .string(key)
        )
    }

    func rawValue(
        forNumber key: Double
    ) -> LuaValue {

        storage[
            .number(key)
        ] ?? .nilValue
    }

    func rawSetValue(
        _ value: LuaValue,
        forNumber key: Double
    ) {

        set(
            value,
            for:
                .number(key)
        )
    }

    // MARK: - Internal

    private func set(
        _ value: LuaValue,
        for key: LuaTableKey
    ) {

        /*
         Lua:
         table[key] = nil
         removes the key.
        */

        if case .nilValue = value {

            storage.removeValue(
                forKey: key
            )

        } else {

            storage[key] =
                value
        }
    }

    private func makeKey(
        from value: LuaValue
    ) throws -> LuaTableKey {

        switch value {

        case let .string(string):

            return .string(
                string
            )

        case let .number(number):

            guard !number.isNaN
            else {

                throw LuaError.runtime(
                    "table index is NaN"
                )
            }

            return .number(
                number
            )

        case let .boolean(boolean):

            return .boolean(
                boolean
            )

        case .nilValue:

            throw LuaError.runtime(
                "table index is nil"
            )

        default:

            /*
             Lua itself also allows
             tables/functions as keys.

             We add reference identity
             keys in a later phase.
            */

            throw LuaError.runtime(
                "unsupported table key type: " +
                value.typeName
            )
        }
    }
}