import Foundation

public typealias LuaNativeFunction = ([LuaValue]) throws -> [LuaValue]

public final class LuaNativeFunctionBox: @unchecked Sendable {
    let body: LuaNativeFunction
    var environment: LuaTable?
    let debugName: String?
    let gcReferences: () -> [LuaValue]

    public init(
        _ body: @escaping LuaNativeFunction,
        environment: LuaTable? = nil,
        debugName: String? = nil,
        gcReferences: @escaping () -> [LuaValue] = { [] }
    ) {
        self.body = body
        self.environment = environment
        self.debugName = debugName
        self.gcReferences = gcReferences
    }
}

public final class LuaUserdata: @unchecked Sendable {
    public let payload: Any?
    public var metatable: LuaTable?
    public var environment: LuaTable?

    public init(payload: Any? = nil) {
        self.payload = payload
    }

    func gcClearReferences() {
        metatable = nil
        environment = nil
    }
}

public enum LuaValue: @unchecked Sendable {
    case nilValue
    case boolean(Bool)
    case number(Double)
    case string(LuaString)
    case table(LuaTable)
    case luaFunction(LuaFunction)
    case nativeFunction(LuaNativeFunctionBox)
    case userdata(LuaUserdata)
    case thread(LuaThread)
}

public final class LuaRaisedError: Error, @unchecked Sendable {
    public let value: LuaValue
    public init(_ value: LuaValue) { self.value = value }
}

public enum LuaError: Error, CustomStringConvertible, Sendable {
    case lexer(line: Int, column: Int, message: String)
    case parser(line: Int, column: Int, message: String)
    case syntax(source: String, line: Int, message: String, near: String)
    case runtime(String)
    case runtimeAt(source: String, line: Int, message: String)

    public var description: String {
        switch self {
        case let .lexer(line, column, message):
            return "Lua lexer error \(line):\(column): \(message)"
        case let .parser(line, column, message):
            return "Lua parser error \(line):\(column): \(message)"
        case let .syntax(source, line, message, near):
            return "\(source):\(line): \(message) near '\(near)'"
        case let .runtime(message):
            return "Lua runtime error: \(message)"
        case let .runtimeAt(source, line, message):
            return "\(source):\(line): \(message)"
        }
    }
}

extension LuaValue {
    var collectableObjectIdentifier: ObjectIdentifier? {
        switch self {
        case let .table(value): return ObjectIdentifier(value)
        case let .luaFunction(value): return ObjectIdentifier(value)
        case let .nativeFunction(value): return ObjectIdentifier(value)
        case let .userdata(value): return ObjectIdentifier(value)
        case let .thread(value): return ObjectIdentifier(value)
        case .nilValue, .boolean, .number, .string: return nil
        }
    }

    public var typeName: String {
        switch self {
        case .nilValue: return "nil"
        case .boolean: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .table: return "table"
        case .luaFunction, .nativeFunction: return "function"
        case .userdata: return "userdata"
        case .thread: return "thread"
        }
    }

    public var printable: String {
        switch self {
        case .nilValue:
            return "nil"
        case let .boolean(value):
            return value ? "true" : "false"
        case let .number(value):
            if value.isFinite,
               value >= Double(Int64.min),
               value <= Double(Int64.max),
               value.rounded(.towardZero) == value {
                return String(Int64(value))
            }
            return String(value)
        case let .string(value):
            return value.utf8String
        case let .table(table):
            return "table: \(LuaValue.identityHex(table))"
        case let .luaFunction(function):
            return "function: \(LuaValue.identityHex(function))"
        case let .nativeFunction(function):
            return "function: \(LuaValue.identityHex(function))"
        case let .userdata(userdata):
            return "userdata: \(LuaValue.identityHex(userdata))"
        case let .thread(thread):
            return "thread: \(LuaValue.identityHex(thread))"
        }
    }

    public var isTruthy: Bool {
        switch self {
        case .nilValue, .boolean(false): return false
        default: return true
        }
    }

    static func identityHex(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object)), radix: 16)
    }
}
