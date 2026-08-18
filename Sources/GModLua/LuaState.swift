import Foundation

final class LuaEnvironment {

    private var values:
        [String: LuaValue] = [:]

    private let parent:
        LuaEnvironment?

    init(
        parent:
            LuaEnvironment? = nil
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

            return parent.get(
                name
            )
        }

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
                    value:
                        value
                )
        }

        return false
    }
}

public final class LuaState {

    private let globals =
        LuaEnvironment()

    private static let
        maxMetatableChainDepth = 100

    public init(
        output:
            @escaping (String) -> Void =
                { print($0) }
    ) {

        // -------------------------
        // print
        // -------------------------

        register(
            "print"
        ) { arguments in

            let text =
                arguments
                    .map {
                        $0.printable
                    }
                    .joined(
                        separator:
                            "\t"
                    )

            output(
                text
            )

            return []
        }

        // -------------------------
        // setmetatable
        // -------------------------

        register(
            "setmetatable"
        ) { arguments in

            guard
                arguments.count >= 2
            else {

                throw LuaError.runtime(
                    "bad argument to 'setmetatable'"
                )
            }

            guard
                case let .table(table) =
                    arguments[0]
            else {

                throw LuaError.runtime(
                    "bad argument #1 to 'setmetatable' " +
                    "(table expected)"
                )
            }

            switch arguments[1] {

            case .nilValue:

                table.metatable =
                    nil

            case let .table(
                metatable
            ):

                table.metatable =
                    metatable

            default:

                throw LuaError.runtime(
                    "bad argument #2 to 'setmetatable' " +
                    "(nil or table expected)"
                )
            }

            return [
                .table(table)
            ]
        }

        // -------------------------
        // getmetatable
        // -------------------------

        register(
            "getmetatable"
        ) { arguments in

            guard
                let first =
                    arguments.first
            else {

                throw LuaError.runtime(
                    "bad argument to 'getmetatable'"
                )
            }

            guard
                case let .table(table) =
                    first
            else {

                return [
                    .nilValue
                ]
            }

            if let metatable =
                table.metatable
            {

                return [
                    .table(
                        metatable
                    )
                ]
            }

            return [
                .nilValue
            ]
        }

        // -------------------------
        // rawget
        // -------------------------

        register(
            "rawget"
        ) { arguments in

            guard
                arguments.count >= 2
            else {

                throw LuaError.runtime(
                    "bad argument to 'rawget'"
                )
            }

            guard
                case let .table(table) =
                    arguments[0]
            else {

                throw LuaError.runtime(
                    "bad argument #1 to 'rawget' " +
                    "(table expected)"
                )
            }

            return [
                try table.rawValue(
                    for:
                        arguments[1]
                )
            ]
        }

        // -------------------------
        // rawset
        // -------------------------

        register(
            "rawset"
        ) { arguments in

            guard
                arguments.count >= 3
            else {

                throw LuaError.runtime(
                    "bad argument to 'rawset'"
                )
            }

            guard
                case let .table(table) =
                    arguments[0]
            else {

                throw LuaError.runtime(
                    "bad argument #1 to 'rawset' " +
                    "(table expected)"
                )
            }

            try table.rawSetValue(
                arguments[2],
                for:
                    arguments[1]
            )

            return [
                .table(table)
            ]
        }
    }

    // MARK: - Public API

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
            value:
                value
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

        let tokens =
            try LuaLexer(
                source:
                    source
            )
            .tokenize()

        let chunk =
            try LuaParser(
                tokens:
                    tokens
            )
            .parse()

        let environment =
            LuaEnvironment(
                parent:
                    globals
            )

        _ = try executeBlock(
            chunk.statements,
            environment:
                environment
        )
    }

    // MARK: - Statements

    private func executeBlock(
        _ statements:
            [LuaStatement],

        environment:
            LuaEnvironment
    ) throws -> [LuaValue]? {

        for statement
            in statements
        {

            if let returned =
                try execute(
                    statement,
                    environment:
                        environment
                )
            {

                return returned
            }
        }

        return nil
    }

    private func execute(
        _ statement:
            LuaStatement,

        environment:
            LuaEnvironment
    ) throws -> [LuaValue]? {

        switch statement {

        case let .localDeclaration(
            name,
            expression
        ):

            let value =
                try expression.map {

                    try evaluate(
                        $0,
                        environment:
                            environment
                    )

                } ?? .nilValue

            environment.define(
                name,
                value:
                    value
            )

            return nil

        case let .localFunction(
            name,
            parameters,
            body
        ):

            environment.define(
                name,
                value:
                    .nilValue
            )

            let function =
                LuaFunction(
                    parameters:
                        parameters,
                    body:
                        body,
                    closure:
                        environment
                )

            _ = environment
                .assignExisting(
                    name,
                    value:
                        .luaFunction(
                            function
                        )
                )

            return nil

        case let .assignment(
            target,
            expression
        ):

            let value =
                try evaluate(
                    expression,
                    environment:
                        environment
                )

            try assign(
                target,
                value:
                    value,
                environment:
                    environment
            )

            return nil

        case let .functionDeclaration(
            target,
            parameters,
            body
        ):

            let function =
                LuaFunction(
                    parameters:
                        parameters,
                    body:
                        body,
                    closure:
                        environment
                )

            try assign(
                target,
                value:
                    .luaFunction(
                        function
                    ),
                environment:
                    environment
            )

            return nil

        case let .returnValues(
            expressions
        ):

            return try expressions.map {

                try evaluate(
                    $0,
                    environment:
                        environment
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

            return nil
        }
    }

    // MARK: - Assignment

    private func assign(
        _ target:
            LuaAssignmentTarget,

        value:
            LuaValue,

        environment:
            LuaEnvironment
    ) throws {

        switch target {

        case let .variable(
            name
        ):

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

        case let .field(
            baseExpression,
            name
        ):

            let receiver =
                try evaluate(
                    baseExpression,
                    environment:
                        environment
                )

            guard
                case let .table(table) =
                    receiver
            else {

                throw LuaError.runtime(
                    "attempt to index a " +
                    "\(receiver.typeName) value"
                )
            }

            try setTableValue(
                table: table,
                receiver:
                    receiver,
                key:
                    .string(name),
                value:
                    value,
                depth:
                    0
            )
        }
    }

    // MARK: - Evaluation

    private func evaluate(
        _ expression:
            LuaExpression,

        environment:
            LuaEnvironment
    ) throws -> LuaValue {

        switch expression {

        case let .number(
            value
        ):

            return .number(
                value
            )

        case let .string(
            value
        ):

            return .string(
                value
            )

        case let .boolean(
            value
        ):

            return .boolean(
                value
            )

        case .nilValue:

            return .nilValue

        case let .variable(
            name
        ):

            return environment.get(
                name
            )

        // -------------------------
        // table constructor
        // -------------------------

        case let .table(
            fields
        ):

            let table =
                LuaTable()

            var arrayIndex =
                1.0

            for field in fields {

                switch field {

                case let .named(
                    name,
                    valueExpression
                ):

                    table.rawSetValue(
                        try evaluate(
                            valueExpression,
                            environment:
                                environment
                        ),
                        forString:
                            name
                    )

                case let .array(
                    valueExpression
                ):

                    table.rawSetValue(
                        try evaluate(
                            valueExpression,
                            environment:
                                environment
                        ),
                        forNumber:
                            arrayIndex
                    )

                    arrayIndex += 1
                }
            }

            return .table(
                table
            )

        // -------------------------
        // function literal
        // -------------------------

        case let .function(
            parameters,
            body
        ):

            return .luaFunction(
                LuaFunction(
                    parameters:
                        parameters,
                    body:
                        body,
                    closure:
                        environment
                )
            )

        // -------------------------
        // t.field
        // -------------------------

        case let .field(
            baseExpression,
            name
        ):

            let receiver =
                try evaluate(
                    baseExpression,
                    environment:
                        environment
                )

            guard
                case let .table(table) =
                    receiver
            else {

                throw LuaError.runtime(
                    "attempt to index a " +
                    "\(receiver.typeName) value"
                )
            }

            return try getTableValue(
                table:
                    table,
                receiver:
                    receiver,
                key:
                    .string(name),
                depth:
                    0
            )

        // -------------------------
        // unary
        // -------------------------

        case let .unary(
            operation,
            inner
        ):

            let value =
                try evaluate(
                    inner,
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

        // -------------------------
        // binary
        // -------------------------

        case let .binary(
            left,
            operation,
            right
        ):

            let lhs =
                try numericValue(
                    evaluate(
                        left,
                        environment:
                            environment
                    )
                )

            let rhs =
                try numericValue(
                    evaluate(
                        right,
                        environment:
                            environment
                    )
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

                return .number(
                    lhs -
                    floor(
                        lhs / rhs
                    ) * rhs
                )
            }

        // -------------------------
        // f(...)
        // -------------------------

        case let .call(
            calleeExpression,
            argumentExpressions
        ):

            let callable =
                try evaluate(
                    calleeExpression,
                    environment:
                        environment
                )

            let arguments =
                try argumentExpressions.map {

                    try evaluate(
                        $0,
                        environment:
                            environment
                    )
                }

            let results =
                try call(
                    callable,
                    arguments:
                        arguments
                )

            return
                results.first ??
                .nilValue

        // -------------------------
        // t:method(...)
        // -------------------------

        case let .methodCall(
            receiverExpression,
            name,
            argumentExpressions
        ):

            let receiver =
                try evaluate(
                    receiverExpression,
                    environment:
                        environment
                )

            guard
                case let .table(table) =
                    receiver
            else {

                throw LuaError.runtime(
                    "attempt to index a " +
                    "\(receiver.typeName) value"
                )
            }

            /*
             IMPORTANT:

             Method lookup must also honor
             __index.

             This will later allow
             Entity / Vector methods to
             live in prototype tables.
            */

            let callable =
                try getTableValue(
                    table:
                        table,
                    receiver:
                        receiver,
                    key:
                        .string(name),
                    depth:
                        0
                )

            let arguments =
                try argumentExpressions.map {

                    try evaluate(
                        $0,
                        environment:
                            environment
                    )
                }

            let results =
                try call(
                    callable,
                    arguments:
                        [receiver] +
                        arguments
                )

            return
                results.first ??
                .nilValue
        }
    }

    // MARK: - Metatables

    private func getTableValue(
        table:
            LuaTable,

        receiver:
            LuaValue,

        key:
            LuaValue,

        depth:
            Int
    ) throws -> LuaValue {

        guard
            depth <
                Self.maxMetatableChainDepth
        else {

            throw LuaError.runtime(
                "loop in gettable"
            )
        }

        /*
         Raw value always wins.
        */

        let raw =
            try table.rawValue(
                for:
                    key
            )

        if !isNil(raw) {
            return raw
        }

        guard
            let metatable =
                table.metatable
        else {

            return .nilValue
        }

        let index =
            metatable.rawValue(
                forString:
                    "__index"
            )

        switch index {

        case .nilValue:

            return .nilValue

        /*
         __index = anotherTable
        */

        case let .table(
            fallbackTable
        ):

            return try getTableValue(
                table:
                    fallbackTable,
                receiver:
                    .table(
                        fallbackTable
                    ),
                key:
                    key,
                depth:
                    depth + 1
            )

        /*
         __index = function(t, key)
        */

        case .luaFunction,
             .nativeFunction:

            let results =
                try call(
                    index,
                    arguments: [
                        receiver,
                        key
                    ]
                )

            return
                results.first ??
                .nilValue

        default:

            throw LuaError.runtime(
                "attempt to index a " +
                "\(index.typeName) value"
            )
        }
    }

    private func setTableValue(
        table:
            LuaTable,

        receiver:
            LuaValue,

        key:
            LuaValue,

        value:
            LuaValue,

        depth:
            Int
    ) throws {

        guard
            depth <
                Self.maxMetatableChainDepth
        else {

            throw LuaError.runtime(
                "loop in settable"
            )
        }

        /*
         Existing raw key:
         write directly.

         __newindex is only consulted
         when the key is absent.
        */

        let existing =
            try table.rawValue(
                for:
                    key
            )

        if !isNil(existing) {

            try table.rawSetValue(
                value,
                for:
                    key
            )

            return
        }

        guard
            let metatable =
                table.metatable
        else {

            try table.rawSetValue(
                value,
                for:
                    key
            )

            return
        }

        let newIndex =
            metatable.rawValue(
                forString:
                    "__newindex"
            )

        switch newIndex {

        case .nilValue:

            try table.rawSetValue(
                value,
                for:
                    key
            )

        /*
         __newindex = anotherTable
        */

        case let .table(
            targetTable
        ):

            try setTableValue(
                table:
                    targetTable,
                receiver:
                    .table(
                        targetTable
                    ),
                key:
                    key,
                value:
                    value,
                depth:
                    depth + 1
            )

        /*
         __newindex =
             function(t, key, value)
        */

        case .luaFunction,
             .nativeFunction:

            _ = try call(
                newIndex,
                arguments: [
                    receiver,
                    key,
                    value
                ]
            )

        default:

            throw LuaError.runtime(
                "attempt to index a " +
                "\(newIndex.typeName) value"
            )
        }
    }

    private func isNil(
        _ value:
            LuaValue
    ) -> Bool {

        if case .nilValue = value {
            return true
        }

        return false
    }

    // MARK: - Calls

    private func call(
        _ callable:
            LuaValue,

        arguments:
            [LuaValue]
    ) throws -> [LuaValue] {

        switch callable {

        case let .nativeFunction(
            function
        ):

            return try function(
                arguments
            )

        case let .luaFunction(
            function
        ):

            let callEnvironment =
                LuaEnvironment(
                    parent:
                        function.closure
                )

            for (
                index,
                parameter
            ) in function
                .parameters
                .enumerated()
            {

                callEnvironment.define(
                    parameter,
                    value:
                        index <
                            arguments.count

                        ? arguments[index]

                        : .nilValue
                )
            }

            return try
                executeBlock(
                    function.body,
                    environment:
                        callEnvironment
                ) ?? []

        default:

            throw LuaError.runtime(
                "attempt to call a " +
                "\(callable.typeName) value"
            )
        }
    }

    // MARK: - Number conversion

    private func numericValue(
        _ value:
            LuaValue
    ) throws -> Double {

        switch value {

        case let .number(
            number
        ):

            return number

        case let .string(
            string
        ):

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