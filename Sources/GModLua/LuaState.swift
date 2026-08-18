import Foundation

final class LuaEnvironment {

    private var values:
        [String: LuaValue] = [:]

    private let parent:
        LuaEnvironment?

    init(
        parent: LuaEnvironment? = nil
    ) {

        self.parent =
            parent
    }

    func define(
        _ name: String,
        value: LuaValue
    ) {

        values[name] =
            value
    }

    func get(
        _ name: String
    ) -> LuaValue {

        if let value =
            values[name]
        {
            return value
        }

        if let parent {
            return parent.get(name)
        }

        // Luaでは存在しないglobalはnil。
        return .nilValue
    }

    @discardableResult
    func assignExisting(
        _ name: String,
        value: LuaValue
    ) -> Bool {

        if values[name] != nil {

            values[name] =
                value

            return true
        }

        if let parent {

            return parent
                .assignExisting(
                    name,
                    value: value
                )
        }

        return false
    }
}

public final class LuaState {

    private let globals =
        LuaEnvironment()

    public init(
        output:
            @escaping (String) -> Void =
                { print($0) }
    ) {

        register(
            "print"
        ) { arguments in

            let message =
                arguments
                    .map {
                        $0.printable
                    }
                    .joined(
                        separator: "\t"
                    )

            output(
                message
            )

            return []
        }
    }

    public func register(
        _ name: String,
        function:
            @escaping LuaNativeFunction
    ) {

        globals.define(
            name,
            value:
                .nativeFunction(
                    function
                )
        )
    }

    public func setGlobal(
        _ name: String,
        value: LuaValue
    ) {

        globals.define(
            name,
            value: value
        )
    }

    public func getGlobal(
        _ name: String
    ) -> LuaValue {

        globals.get(
            name
        )
    }

    public func execute(
        _ source: String
    ) throws {

        let lexer =
            LuaLexer(
                source: source
            )

        let tokens =
            try lexer.tokenize()

        let parser =
            LuaParser(
                tokens:
                    tokens
            )

        let chunk =
            try parser.parse()

        /*
         Top-level local variables belong
         to this chunk.

         Globals live in `globals`.
        */
        let environment =
            LuaEnvironment(
                parent:
                    globals
            )

        for statement
            in chunk.statements
        {

            try execute(
                statement,
                environment:
                    environment
            )
        }
    }

    private func execute(
        _ statement:
            LuaStatement,

        environment:
            LuaEnvironment
    ) throws {

        switch statement {

        case let .localDeclaration(
            name,
            expression
        ):

            let value:
                LuaValue

            if let expression {

                value =
                    try evaluate(
                        expression,
                        environment:
                            environment
                    )

            } else {

                value =
                    .nilValue
            }

            environment.define(
                name,
                value:
                    value
            )

        case let .assignment(
            name,
            expression
        ):

            let value =
                try evaluate(
                    expression,
                    environment:
                        environment
                )

            if !environment
                .assignExisting(
                    name,
                    value:
                        value
                )
            {
                globals.define(
                    name,
                    value:
                        value
                )
            }

        case let .expression(
            expression
        ):

            _ = try evaluate(
                expression,
                environment:
                    environment
            )
        }
    }

    private func evaluate(
        _ expression:
            LuaExpression,

        environment:
            LuaEnvironment
    ) throws -> LuaValue {

        switch expression {

        case let .number(value):

            return .number(
                value
            )

        case let .string(value):

            return .string(
                value
            )

        case let .boolean(value):

            return .boolean(
                value
            )

        case .nilValue:

            return .nilValue

        case let .variable(name):

            return environment.get(
                name
            )

        case let .unary(
            operation,
            expression
        ):

            let value =
                try evaluate(
                    expression,
                    environment:
                        environment
                )

            switch operation {

            case .negate:

                let number =
                    try numericValue(
                        value
                    )

                return .number(
                    -number
                )
            }

        case let .binary(
            left,
            operation,
            right
        ):

            let leftValue =
                try evaluate(
                    left,
                    environment:
                        environment
                )

            let rightValue =
                try evaluate(
                    right,
                    environment:
                        environment
                )

            let lhs =
                try numericValue(
                    leftValue
                )

            let rhs =
                try numericValue(
                    rightValue
                )

            switch operation {

            case .add:

                return .number(
                    lhs + rhs
                )

            case .subtract:

                return .number(
                    lhs - rhs
                )

            case .multiply:

                return .number(
                    lhs * rhs
                )

            case .divide:

                return .number(
                    lhs / rhs
                )

            case .modulo:

                /*
                 Lua modulo semantics:
                 a - floor(a / b) * b
                */

                return .number(
                    lhs -
                    floor(
                        lhs / rhs
                    ) * rhs
                )
            }

        case let .call(
            name,
            argumentExpressions
        ):

            let callable =
                environment.get(
                    name
                )

            let arguments =
                try argumentExpressions
                    .map {

                        try evaluate(
                            $0,
                            environment:
                                environment
                        )
                    }

            guard
                case let .nativeFunction(
                    function
                ) =
                    callable
            else {

                throw LuaError.runtime(
                    "attempt to call " +
                    "a \(callable.typeName) value"
                )
            }

            let results =
                try function(
                    arguments
                )

            return
                results.first ??
                .nilValue
        }
    }

    private func numericValue(
        _ value: LuaValue
    ) throws -> Double {

        switch value {

        case let .number(number):

            return number

        case let .string(string):

            if let number =
                Double(string)
            {
                return number
            }

            fallthrough

        default:

            throw LuaError.runtime(
                "attempt to perform " +
                "arithmetic on a " +
                "\(value.typeName) value"
            )
        }
    }
}