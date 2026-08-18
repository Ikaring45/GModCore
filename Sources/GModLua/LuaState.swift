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

        /*
         Lua:
         undefined global -> nil
        */
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

    public init(
        output:
            @escaping (String) -> Void =
                { print($0) }
    ) {

        /*
         Lua print()
        */
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

        /*
         1 chunkにつき
         top-level local scopeを作る。

         globalsとは別。
        */
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

    /*
     nil:
       blockが普通に終了

     [LuaValue]:
       returnが発生
    */
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

        /*
         local function f()

         Lua semanticsとして、

         local f
         f = function()

         に近い。

         先にlocalを作るので
         再帰関数も後で対応できる。
        */
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

            return try expressions
                .map {

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

            /*
             既存localがあればそこへ。

             なければglobal。
            */
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

            let base =
                try evaluate(
                    baseExpression,
                    environment:
                        environment
                )

            guard
                case let
                    .table(table) =
                    base
            else {

                throw LuaError.runtime(
                    "attempt to index a " +
                    "\(base.typeName) value"
                )
            }

            table.setValue(
                value,
                forString:
                    name
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

        /*
         {
             value = 42
         }
        */
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

                    table.setValue(
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

                    table.setValue(
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

        /*
         anonymous function:

         function()
             ...
         end
        */
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

        /*
         self.value
        */
        case let .field(
            baseExpression,
            name
        ):

            let base =
                try evaluate(
                    baseExpression,
                    environment:
                        environment
                )

            guard
                case let
                    .table(table) =
                    base
            else {

                throw LuaError.runtime(
                    "attempt to index a " +
                    "\(base.typeName) value"
                )
            }

            return table.value(
                forString:
                    name
            )

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

                return .number(
                    lhs -
                    floor(
                        lhs / rhs
                    ) * rhs
                )
            }

        /*
         counter()
         print(...)
        */
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
                try argumentExpressions
                    .map {

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

        /*
         t:GetValue()

         receiverをselfとして
         argument 0へ自動挿入。
        */
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
                case let
                    .table(table) =
                    receiver
            else {

                throw LuaError.runtime(
                    "attempt to index a " +
                    "\(receiver.typeName) value"
                )
            }

            let callable =
                table.value(
                    forString:
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

    private func call(
        _ callable:
            LuaValue,

        arguments:
            [LuaValue]
    ) throws -> [LuaValue] {

        switch callable {

        /*
         Swift側から登録した関数。
        */
        case let .nativeFunction(
            function
        ):

            return try function(
                arguments
            )

        /*
         Luaで定義された関数。
        */
        case let .luaFunction(
            function
        ):

            let callEnvironment =
                LuaEnvironment(
                    parent:
                        function.closure
                )

            /*
             足りない引数はnil。

             余分な引数は
             vararg未実装なので今は捨てる。
            */
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

    private func numericValue(
        _ value:
            LuaValue
    ) throws -> Double {

        switch value {

        case let .number(
            number
        ):

            return number

        /*
         Lua 5.1では
         arithmetic時に数値文字列を
         numberへcoerceする。
        */
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
