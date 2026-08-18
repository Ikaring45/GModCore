enum LuaTableKey:
    Hashable
{

    case string(
        String
    )

    case number(
        Double
    )

    case boolean(
        Bool
    )
}

public final class LuaTable {

    private var storage:
        [LuaTableKey: LuaValue] = [:]

    /*
     次Phaseで
     __index / __newindex 等を実装するとき使う。
    */
    public var metatable:
        LuaTable?

    public init() {
    }

    public func value(
        forString key: String
    ) -> LuaValue {

        storage[
            .string(key)
        ] ?? .nilValue
    }

    public func setValue(
        _ value: LuaValue,
        forString key: String
    ) {

        set(
            value,
            for:
                .string(key)
        )
    }

    func value(
        forNumber key: Double
    ) -> LuaValue {

        storage[
            .number(key)
        ] ?? .nilValue
    }

    func setValue(
        _ value: LuaValue,
        forNumber key: Double
    ) {

        set(
            value,
            for:
                .number(key)
        )
    }

    private func set(
        _ value: LuaValue,
        for key: LuaTableKey
    ) {

        /*
         Luaでは

         table[key] = nil

         はキーの削除。
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
}
