public typealias LuaNativeFunction =
    ([LuaValue]) throws -> [LuaValue]

public enum LuaValue {

    case nilValue
    case boolean(Bool)
    case number(Double)
    case string(String)

    case nativeFunction(
        LuaNativeFunction
    )
}

public enum LuaError:
    Error,
    CustomStringConvertible
{

    case lexer(
        line: Int,
        column: Int,
        message: String
    )

    case parser(
        line: Int,
        column: Int,
        message: String
    )

    case runtime(
        String
    )

    public var description: String {

        switch self {

        case let .lexer(
            line,
            column,
            message
        ):

            return
                "Lua lexer error " +
                "\(line):\(column): " +
                message

        case let .parser(
            line,
            column,
            message
        ):

            return
                "Lua parser error " +
                "\(line):\(column): " +
                message

        case let .runtime(
            message
        ):

            return
                "Lua runtime error: " +
                message
        }
    }
}

extension LuaValue {

    public var typeName: String {

        switch self {

        case .nilValue:
            return "nil"

        case .boolean:
            return "boolean"

        case .number:
            return "number"

        case .string:
            return "string"

        case .nativeFunction:
            return "function"
        }
    }

    public var printable: String {

        switch self {

        case .nilValue:
            return "nil"

        case let .boolean(value):
            return value
                ? "true"
                : "false"

        case let .number(value):

            if
                value.isFinite,
                value >= Double(Int64.min),
                value <= Double(Int64.max),
                value.rounded(
                    .towardZero
                ) == value
            {
                return String(
                    Int64(value)
                )
            }

            return String(value)

        case let .string(value):
            return value

        case .nativeFunction:
            return "function"
        }
    }

    public var isTruthy: Bool {

        switch self {

        case .nilValue:
            return false

        case .boolean(false):
            return false

        default:
            return true
        }
    }
}
