import Foundation

extension LuaState {
    func installStandardLibrary() {
        globalTable.rawSetValue(.table(globalTable), forString: "_G")
        globalTable.rawSetValue(.string("Lua 5.1"), forString: "_VERSION")

        installBaseLibrary()
        installCoroutineLibrary()
        installPackageLibrary()
        installMathLibrary()
        installStringLibrary()
        installTableLibrary()
        installOSLibrary()
        installIOLibrary()
        installDebugLibrary()
    }

    // MARK: - Base library

    private func installBaseLibrary() {
        register("print") { [unowned self] arguments in
            self.emit(try arguments.map { try self.luaString($0) }.joined(separator: "\t"))
            return []
        }

        register("type") { arguments in
            [.string(LuaString(arguments.first?.typeName ?? "nil"))]
        }

        register("tostring") { [unowned self] arguments in
            [.string(LuaString(try self.luaString(arguments.first ?? .nilValue)))]
        }

        register("tonumber") { [unowned self] arguments in
            guard let first = arguments.first else { return [.nilValue] }
            if case let .number(number) = first { return [.number(number)] }
            guard case let .string(text) = first else { return [.nilValue] }

            if arguments.count >= 2, case let .number(baseNumber) = arguments[1] {
                let base = Int(baseNumber)
                guard (2...36).contains(base) else {
                    throw LuaError.runtime("bad argument #2 to 'tonumber' (base out of range)")
                }
                let raw = text.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
                var sign: Double = 1
                var digits = raw
                if digits.first == "-" { sign = -1; digits.removeFirst() }
                else if digits.first == "+" { digits.removeFirst() }
                guard !digits.isEmpty, let value = UInt64(digits, radix: base) else { return [.nilValue] }
                return [.number(sign * Double(value))]
            }

            return self.coerceNumber(first).map { [.number($0)] } ?? [.nilValue]
        }

        register("assert") { arguments in
            let condition = arguments.first ?? .nilValue
            guard condition.isTruthy else {
                let message = arguments.count > 1 ? arguments[1] : .string("assertion failed!")
                throw LuaRaisedError(message)
            }
            return arguments
        }

        register("error") { arguments in
            throw LuaRaisedError(arguments.first ?? .nilValue)
        }

        register("pcall") { [unowned self] arguments in
            guard let callable = arguments.first else {
                return [.boolean(false), .string("attempt to call a nil value")]
            }
            do {
                return [.boolean(true)] + (try self.callValue(callable, arguments: Array(arguments.dropFirst())))
            } catch {
                return [.boolean(false), self.errorValue(error)]
            }
        }

        register("xpcall") { [unowned self] arguments in
            guard arguments.count >= 2 else {
                return [.boolean(false), .string("bad arguments to 'xpcall'")]
            }
            let callable = arguments[0]
            let handler = arguments[1]
            do {
                return [.boolean(true)] + (try self.callValue(callable, arguments: []))
            } catch {
                let original = self.errorValue(error)
                do {
                    let transformed = try self.callValue(handler, arguments: [original])
                    return [.boolean(false)] + transformed
                } catch {
                    return [.boolean(false), self.errorValue(error)]
                }
            }
        }

        register("select") { arguments in
            guard let selector = arguments.first else { throw LuaError.runtime("bad argument #1 to 'select'") }
            let values = Array(arguments.dropFirst())
            if case let .string(text) = selector, text == LuaString("#") {
                return [.number(Double(values.count))]
            }
            guard case let .number(number) = selector else {
                throw LuaError.runtime("bad argument #1 to 'select' (number expected)")
            }
            var index = Int(number)
            if index < 0 { index = values.count + index + 1 }
            guard index >= 1, index <= values.count + 1 else {
                throw LuaError.runtime("bad argument #1 to 'select' (index out of range)")
            }
            return index > values.count ? [] : Array(values[(index - 1)...])
        }

        register("rawequal") { [unowned self] arguments in
            guard arguments.count >= 2 else { return [.boolean(false)] }
            return [.boolean(self.rawEqual(arguments[0], arguments[1]))]
        }

        register("rawget") { arguments in
            guard arguments.count >= 2, case let .table(table) = arguments[0] else {
                throw LuaError.runtime("bad argument #1 to 'rawget' (table expected)")
            }
            return [try table.rawValue(for: arguments[1])]
        }

        register("rawset") { arguments in
            guard arguments.count >= 3, case let .table(table) = arguments[0] else {
                throw LuaError.runtime("bad argument #1 to 'rawset' (table expected)")
            }
            try table.rawSetValue(arguments[2], for: arguments[1])
            return [.table(table)]
        }

        register("gcinfo") { [unowned self] _ in
            [.number(self.estimatedMemoryKilobytes())]
        }

        register("newproxy") { [unowned self] arguments in
            let userdata = LuaUserdata()
            if let first = arguments.first {
                switch first {
                case .boolean(true):
                    userdata.metatable = LuaTable()
                case let .userdata(other):
                    guard let metatable = other.metatable else {
                        throw LuaError.runtime("boolean or proxy expected")
                    }
                    userdata.metatable = metatable
                case .boolean(false), .nilValue:
                    break
                default:
                    throw LuaError.runtime("boolean or proxy expected")
                }
            }
            userdata.environment = self.globalTable
            return [.userdata(userdata)]
        }

        register("getmetatable") { [unowned self] arguments in
            guard let value = arguments.first, let metatable = self.metatable(of: value) else { return [.nilValue] }
            let protected = metatable.rawValue(forString: "__metatable")
            return self.isNil(protected) ? [.table(metatable)] : [protected]
        }

        register("setmetatable") { [unowned self] arguments in
            guard arguments.count >= 2, case let .table(table) = arguments[0] else {
                throw LuaError.runtime("bad argument #1 to 'setmetatable' (table expected)")
            }
            if let existing = table.metatable {
                let protected = existing.rawValue(forString: "__metatable")
                if !self.isNil(protected) { throw LuaError.runtime("cannot change a protected metatable") }
            }
            switch arguments[1] {
            case .nilValue: table.metatable = nil
            case let .table(metatable): table.metatable = metatable
            default: throw LuaError.runtime("bad argument #2 to 'setmetatable' (nil or table expected)")
            }
            return [.table(table)]
        }

        register("getfenv") { [unowned self] arguments in
            let target = arguments.first ?? .number(1)
            switch target {
            case let .luaFunction(function): return [.table(function.environmentTable)]
            case let .number(levelNumber):
                let level = Int(levelNumber)
                if level == 0 { return [.table(self.globalTable)] }
                return [.table(self.currentLuaFunction(level: level)?.environmentTable ?? self.globalTable)]
            default:
                return [.table(self.globalTable)]
            }
        }

        register("setfenv") { [unowned self] arguments in
            guard arguments.count >= 2, case let .table(environment) = arguments[1] else {
                throw LuaError.runtime("bad argument #2 to 'setfenv' (table expected)")
            }
            switch arguments[0] {
            case let .luaFunction(function):
                function.environmentTable = environment
                return [arguments[0]]
            case let .number(levelNumber):
                let level = Int(levelNumber)
                guard level > 0, let function = self.currentLuaFunction(level: level) else {
                    throw LuaError.runtime("'setfenv' cannot change environment of given object")
                }
                function.environmentTable = environment
                self.currentLuaEnvironment(level: level)?.globalTable = environment
                return [arguments[0]]
            default:
                throw LuaError.runtime("'setfenv' cannot change environment of given object")
            }
        }

        register("next") { arguments in
            guard let first = arguments.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'next' (table expected)")
            }
            let key = arguments.count > 1 ? arguments[1] : .nilValue
            if let pair = try table.nextPair(after: key) { return [pair.0, pair.1] }
            return [.nilValue]
        }

        register("pairs") { [unowned self] arguments in
            guard let first = arguments.first, case .table = first else {
                throw LuaError.runtime("bad argument #1 to 'pairs' (table expected)")
            }
            return [self.getGlobal("next"), first, .nilValue]
        }

        register("ipairs") { arguments in
            guard let first = arguments.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'ipairs' (table expected)")
            }
            let iterator = LuaNativeFunctionBox({ args in
                let previous: Double
                if args.count > 1, case let .number(value) = args[1] { previous = value } else { previous = 0 }
                let next = previous + 1
                let value = table.rawValue(forNumber: next)
                if case .nilValue = value { return [.nilValue] }
                return [.number(next), value]
            }, debugName: "ipairsaux")
            return [.nativeFunction(iterator), first, .number(0)]
        }

        register("unpack") { arguments in
            guard let first = arguments.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'unpack' (table expected)")
            }
            let start = arguments.count > 1 ? Int(try self.numberFromValue(arguments[1])) : 1
            let end = arguments.count > 2 ? Int(try self.numberFromValue(arguments[2])) : table.rawLength()
            if end < start { return [] }
            return (start...end).map { table.rawValue(forNumber: Double($0)) }
        }

        register("loadstring") { [unowned self] arguments in
            guard let first = arguments.first, case let .string(sourceBytes) = first else {
                throw LuaError.runtime("bad argument #1 to 'loadstring' (string expected)")
            }
            if let dumped = self.dumpRegistry[sourceBytes] { return [.luaFunction(dumped)] }
            let sourceName = try self.optionalStringArgument(
                arguments,
                at: 1,
                defaultValue: sourceBytes.utf8String
            )
            do {
                let function = try self.compile(sourceBytes.utf8String, sourceName: sourceName)
                function.environmentTable = self.currentLuaFunction()?.environmentTable ?? self.globalTable
                return [.luaFunction(function)]
            } catch {
                return [.nilValue, self.errorValue(error)]
            }
        }

        register("load") { [unowned self] arguments in
            guard let reader = arguments.first else { throw LuaError.runtime("bad argument #1 to 'load' (function expected)") }
            let chunkName = try self.optionalStringArgument(
                arguments,
                at: 1,
                defaultValue: "=(load)"
            )
            var bytes: [UInt8] = []
            while true {
                let results = try self.callValue(reader, arguments: [])
                let value = results.first ?? .nilValue
                if case .nilValue = value { break }
                guard case let .string(piece) = value else {
                    return [.nilValue, .string("reader function must return a string")]
                }
                if piece.isEmpty { break }
                bytes.append(contentsOf: piece.bytes)
            }
            do {
                let function = try self.compile(String(decoding: bytes, as: UTF8.self), sourceName: chunkName)
                function.environmentTable = self.currentLuaFunction()?.environmentTable ?? self.globalTable
                return [.luaFunction(function)]
            } catch {
                return [.nilValue, self.errorValue(error)]
            }
        }

        register("loadfile") { [unowned self] arguments in
            guard let loader = self.fileLoader else {
                return [.nilValue, .string("file loading is unavailable")]
            }
            let filename = arguments.first.map { try? self.stringFromValue($0) } ?? nil
            guard let filename else { return [.nilValue, .string("stdin loading is unavailable")] }
            do {
                let source = try loader(filename)
                let function = try self.compile(source, sourceName: "@\(filename)")
                function.environmentTable = self.currentLuaFunction()?.environmentTable ?? self.globalTable
                return [.luaFunction(function)]
            } catch {
                return [.nilValue, self.errorValue(error)]
            }
        }

        register("dofile") { [unowned self] arguments in
            let loadfile = self.getGlobal("loadfile")
            let loaded = try self.callValue(loadfile, arguments: arguments)
            guard let function = loaded.first, !self.isNil(function) else {
                throw LuaRaisedError(loaded.count > 1 ? loaded[1] : .string("cannot load file"))
            }
            return try self.callValue(function, arguments: [])
        }

        register("collectgarbage") { [unowned self] arguments in
            let option = arguments.first.map { try? self.stringFromValue($0) } ?? "collect"
            switch option {
            case "collect", "stop", "restart", "step": return [.number(0)]
            case "count": return [.number(self.estimatedMemoryKilobytes())]
            case "setpause", "setstepmul": return [.number(200)]
            default: throw LuaError.runtime("bad argument #1 to 'collectgarbage' (invalid option)")
            }
        }
    }

    // MARK: - Coroutine library

    private func installCoroutineLibrary() {
        let coroutine = LuaTable()
        func native(_ name: String, _ body: @escaping LuaNativeFunction) {
            coroutine.rawSetValue(.nativeFunction(LuaNativeFunctionBox(body, debugName: "coroutine.\(name)")), forString: name)
        }

        native("create") { [unowned self] args in
            guard let function = args.first else { throw LuaError.runtime("bad argument #1 to 'create' (function expected)") }
            switch function {
            case .luaFunction, .nativeFunction: break
            default: throw LuaError.runtime("bad argument #1 to 'create' (function expected)")
            }
            return [.thread(LuaThread(state: self, entry: function))]
        }

        native("resume") { args in
            guard let first = args.first, case let .thread(thread) = first else {
                throw LuaError.runtime("bad argument #1 to 'resume' (thread expected)")
            }
            let parent = LuaThread.current
            parent?.markNormal()
            defer { parent?.markRunning() }
            switch thread.resume(Array(args.dropFirst())) {
            case let .success(values): return [.boolean(true)] + values
            case let .failure(value): return [.boolean(false), value]
            }
        }

        native("yield") { args in
            guard let current = LuaThread.current else {
                throw LuaError.runtime("attempt to yield from outside a coroutine")
            }
            return try current.yield(args)
        }

        native("status") { args in
            guard let first = args.first, case let .thread(thread) = first else {
                throw LuaError.runtime("bad argument #1 to 'status' (thread expected)")
            }
            return [.string(LuaString(thread.status.rawValue))]
        }

        native("running") { _ in
            if let current = LuaThread.current { return [.thread(current)] }
            return [.nilValue]
        }

        native("wrap") { [unowned self] args in
            guard let function = args.first else { throw LuaError.runtime("bad argument #1 to 'wrap' (function expected)") }
            let thread = LuaThread(state: self, entry: function)
            let wrapper = LuaNativeFunctionBox({ args in
                switch thread.resume(args) {
                case let .success(values): return values
                case let .failure(value): throw LuaRaisedError(value)
                }
            }, debugName: "coroutine.wrap")
            return [.nativeFunction(wrapper)]
        }

        setGlobal("coroutine", value: .table(coroutine))
    }

    // MARK: - Package library

    private func installPackageLibrary() {
        let package = LuaTable()
        let loaded = LuaTable()
        let preload = LuaTable()
        let loaders = LuaTable()

        package.rawSetValue(.table(loaded), forString: "loaded")
        package.rawSetValue(.table(preload), forString: "preload")
        package.rawSetValue(.table(loaders), forString: "loaders")
        package.rawSetValue(.string("?.lua;?/init.lua"), forString: "path")
        package.rawSetValue(.string(""), forString: "cpath")
        package.rawSetValue(.string("/\n;\n?\n!\n-"), forString: "config")

        let preloadLoader = LuaNativeFunctionBox({ args in
            guard let name = args.first, case let .string(moduleName) = name else { return [.string("\n\tinvalid module name")] }
            let candidate = preload.rawValue(forString: moduleName)
            if self.isNil(candidate) {
                return [.string(LuaString("\n\tno field package.preload['\(moduleName.utf8String)']"))]
            }
            return [candidate]
        }, debugName: "package.loader.preload")

        let fileLoader = LuaNativeFunctionBox({ args in
            guard let nameValue = args.first, case let .string(moduleName) = nameValue else { return [.string("\n\tinvalid module name")] }
            guard let hostLoader = self.fileLoader else { return [.string("\n\tno host file loader")] }
            let modulePath = moduleName.utf8String.replacingOccurrences(of: ".", with: "/")
            let pathText: String
            if case let .string(path) = package.rawValue(forString: "path") { pathText = path.utf8String }
            else { pathText = "?.lua;?/init.lua" }
            var errors = ""
            for template in pathText.split(separator: ";", omittingEmptySubsequences: true) {
                let candidate = String(template).replacingOccurrences(of: "?", with: modulePath)
                do {
                    let source = try hostLoader(candidate)
                    let function = try self.compile(source, sourceName: "@\(candidate)")
                    return [.luaFunction(function), .string(LuaString(candidate))]
                } catch {
                    errors += "\n\tno file '\(candidate)'"
                }
            }
            return [.string(LuaString(errors))]
        }, debugName: "package.loader.lua")

        loaders.rawSetValue(.nativeFunction(preloadLoader), forNumber: 1)
        loaders.rawSetValue(.nativeFunction(fileLoader), forNumber: 2)

        setGlobal("package", value: .table(package))

        register("require") { [unowned self] args in
            guard let first = args.first, case let .string(name) = first else {
                throw LuaError.runtime("bad argument #1 to 'require' (string expected)")
            }
            let already = loaded.rawValue(forString: name)
            if already.isTruthy { return [already] }

            var diagnostics = ""
            var index = 1
            var foundLoader: LuaValue?
            var loaderExtra: LuaValue = .nilValue
            while true {
                let loader = loaders.rawValue(forNumber: Double(index))
                if self.isNil(loader) { break }
                let results = try self.callValue(loader, arguments: [.string(name)])
                if let first = results.first {
                    switch first {
                    case .luaFunction, .nativeFunction:
                        foundLoader = first
                        loaderExtra = results.count > 1 ? results[1] : .nilValue
                    case let .string(message): diagnostics += message.utf8String
                    default: break
                    }
                }
                if foundLoader != nil { break }
                index += 1
            }

            guard let foundLoader else {
                throw LuaError.runtime("module '\(name.utf8String)' not found:\(diagnostics)")
            }

            // Loop sentinel compatible with the usual package.loaded behavior.
            loaded.rawSetValue(.boolean(true), forString: name)
            let results = try self.callValue(foundLoader, arguments: [.string(name), loaderExtra])
            if let result = results.first, !self.isNil(result) {
                loaded.rawSetValue(result, forString: name)
            }
            let final = loaded.rawValue(forString: name)
            return [self.isNil(final) ? .boolean(true) : final]
        }

        register("module") { [unowned self] args in
            guard let first = args.first, case let .string(name) = first else {
                throw LuaError.runtime("bad argument #1 to 'module' (string expected)")
            }
            let components = name.utf8String.split(separator: ".").map(String.init)
            var container = self.globalTable
            var moduleTable: LuaTable?
            for component in components {
                let existing = container.rawValue(forString: component)
                if case let .table(table) = existing {
                    moduleTable = table
                    container = table
                } else {
                    let table = LuaTable()
                    container.rawSetValue(.table(table), forString: component)
                    moduleTable = table
                    container = table
                }
            }
            guard let moduleTable else { throw LuaError.runtime("invalid module name") }
            moduleTable.rawSetValue(.string(name), forString: "_NAME")
            moduleTable.rawSetValue(.table(moduleTable), forString: "_M")
            let packagePrefix: String
            if let dot = name.utf8String.lastIndex(of: ".") {
                packagePrefix = String(name.utf8String[...dot])
            } else { packagePrefix = "" }
            moduleTable.rawSetValue(.string(LuaString(packagePrefix)), forString: "_PACKAGE")
            loaded.rawSetValue(.table(moduleTable), forString: name)
            if let current = self.currentLuaFunction() { current.environmentTable = moduleTable }
            self.currentLuaEnvironment()?.globalTable = moduleTable
            for option in args.dropFirst() { _ = try self.callValue(option, arguments: [.table(moduleTable)]) }
            return []
        }

        let seeall = LuaNativeFunctionBox({ args in
            guard let first = args.first, case let .table(moduleTable) = first else {
                throw LuaError.runtime("bad argument #1 to 'seeall' (table expected)")
            }
            let metatable = moduleTable.metatable ?? LuaTable()
            metatable.rawSetValue(.table(self.globalTable), forString: "__index")
            moduleTable.metatable = metatable
            return []
        }, debugName: "package.seeall")
        package.rawSetValue(.nativeFunction(seeall), forString: "seeall")

        package.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ _ in
            [.nilValue, .string("dynamic libraries are unavailable on this platform")]
        }, debugName: "package.loadlib")), forString: "loadlib")
    }

    // MARK: - Math

    private func installMathLibrary() {
        let math = LuaTable()
        func native(_ name: String, _ body: @escaping LuaNativeFunction) {
            math.rawSetValue(.nativeFunction(LuaNativeFunctionBox(body, debugName: "math.\(name)")), forString: name)
        }
        math.rawSetValue(.number(Double.pi), forString: "pi")
        math.rawSetValue(.number(Double.infinity), forString: "huge")

        native("abs") { [.number(abs(try self.requireNumber($0, 0, "abs")))] }
        native("acos") { [.number(acos(try self.requireNumber($0, 0, "acos")))] }
        native("asin") { [.number(asin(try self.requireNumber($0, 0, "asin")))] }
        native("atan") { [.number(atan(try self.requireNumber($0, 0, "atan")))] }
        native("atan2") { [.number(atan2(try self.requireNumber($0, 0, "atan2"), try self.requireNumber($0, 1, "atan2")))] }
        native("ceil") { [.number(ceil(try self.requireNumber($0, 0, "ceil")))] }
        native("cos") { [.number(cos(try self.requireNumber($0, 0, "cos")))] }
        native("cosh") { [.number(cosh(try self.requireNumber($0, 0, "cosh")))] }
        native("deg") { [.number((try self.requireNumber($0, 0, "deg")) * 180 / .pi)] }
        native("exp") { [.number(exp(try self.requireNumber($0, 0, "exp")))] }
        native("floor") { [.number(floor(try self.requireNumber($0, 0, "floor")))] }
        native("fmod") { [.number(fmod(try self.requireNumber($0, 0, "fmod"), try self.requireNumber($0, 1, "fmod")))] }
        native("mod") { [.number(fmod(try self.requireNumber($0, 0, "mod"), try self.requireNumber($0, 1, "mod")))] }
        native("frexp") { args in
            let x = try self.requireNumber(args, 0, "frexp")
            if x == 0 { return [.number(0), .number(0)] }
            let exponent = floor(log2(abs(x))) + 1
            return [.number(x / pow(2, exponent)), .number(exponent)]
        }
        native("ldexp") { [.number(try self.requireNumber($0, 0, "ldexp") * pow(2, try self.requireNumber($0, 1, "ldexp")))] }
        native("log") { [.number(log(try self.requireNumber($0, 0, "log")))] }
        native("log10") { [.number(log10(try self.requireNumber($0, 0, "log10")))] }
        native("max") { args in
            guard !args.isEmpty else { throw LuaError.runtime("bad argument to 'max'") }
            return [.number(try args.map { try self.numberFromValue($0) }.max()!)]
        }
        native("min") { args in
            guard !args.isEmpty else { throw LuaError.runtime("bad argument to 'min'") }
            return [.number(try args.map { try self.numberFromValue($0) }.min()!)]
        }
        native("modf") { args in
            let x = try self.requireNumber(args, 0, "modf")
            let integral = x.rounded(.towardZero)
            return [.number(integral), .number(x - integral)]
        }
        native("pow") { [.number(pow(try self.requireNumber($0, 0, "pow"), try self.requireNumber($0, 1, "pow")))] }
        native("rad") { [.number((try self.requireNumber($0, 0, "rad")) * .pi / 180)] }
        native("random") { [unowned self] args in
            let unit = self.nextRandomUnit()
            if args.isEmpty { return [.number(unit)] }
            if args.count == 1 {
                let upper = Int(try self.numberFromValue(args[0]))
                guard upper >= 1 else { throw LuaError.runtime("interval is empty") }
                return [.number(Double(Int(unit * Double(upper)) + 1))]
            }
            let lower = Int(try self.numberFromValue(args[0]))
            let upper = Int(try self.numberFromValue(args[1]))
            guard lower <= upper else { throw LuaError.runtime("interval is empty") }
            return [.number(Double(lower + Int(unit * Double(upper - lower + 1))))]
        }
        native("randomseed") { [unowned self] args in
            let seed = UInt64(bitPattern: Int64(try self.requireNumber(args, 0, "randomseed")))
            self.randomState = seed == 0 ? 1 : seed
            return []
        }
        native("sin") { [.number(sin(try self.requireNumber($0, 0, "sin")))] }
        native("sinh") { [.number(sinh(try self.requireNumber($0, 0, "sinh")))] }
        native("sqrt") { [.number(sqrt(try self.requireNumber($0, 0, "sqrt")))] }
        native("tan") { [.number(tan(try self.requireNumber($0, 0, "tan")))] }
        native("tanh") { [.number(tanh(try self.requireNumber($0, 0, "tanh")))] }

        setGlobal("math", value: .table(math))
    }

    // MARK: - String

    private func installStringLibrary() {
        let string = LuaTable()
        func native(_ name: String, _ body: @escaping LuaNativeFunction) {
            string.rawSetValue(.nativeFunction(LuaNativeFunctionBox(body, debugName: "string.\(name)")), forString: name)
        }

        native("len") { [.number(Double(try self.requireLuaString($0, 0, "len").count))] }
        native("lower") { [.string(try self.requireLuaString($0, 0, "lower").lowercased())] }
        native("upper") { [.string(try self.requireLuaString($0, 0, "upper").uppercased())] }
        native("reverse") { args in [.string(LuaString(bytes: Array(try self.requireLuaString(args, 0, "reverse").bytes.reversed())))] }
        native("rep") { args in
            let value = try self.requireLuaString(args, 0, "rep")
            let count = Int(try self.requireNumber(args, 1, "rep"))
            if count <= 0 { return [.string("")] }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(value.count * count)
            for _ in 0..<count { bytes += value.bytes }
            return [.string(LuaString(bytes: bytes))]
        }
        native("sub") { args in
            let value = try self.requireLuaString(args, 0, "sub")
            let i = Int(try self.requireNumber(args, 1, "sub"))
            let j = args.count > 2 ? Int(try self.requireNumber(args, 2, "sub")) : -1
            return [.string(self.byteSubstring(value, i: i, j: j))]
        }
        native("byte") { args in
            let value = try self.requireLuaString(args, 0, "byte")
            let i = args.count > 1 ? Int(try self.requireNumber(args, 1, "byte")) : 1
            let j = args.count > 2 ? Int(try self.requireNumber(args, 2, "byte")) : i
            let range = self.normalizedByteRange(count: value.count, i: i, j: j)
            guard let range else { return [] }
            return range.map { .number(Double(value.bytes[$0])) }
        }
        native("char") { args in
            var bytes: [UInt8] = []
            for (index, value) in args.enumerated() {
                let number = Int(try self.numberFromValue(value))
                guard (0...255).contains(number) else {
                    throw LuaError.runtime("bad argument #\(index + 1) to 'char' (value out of range)")
                }
                bytes.append(UInt8(number))
            }
            return [.string(LuaString(bytes: bytes))]
        }
        native("find") { [unowned self] args in
            let subject = try self.requireLuaString(args, 0, "find")
            let pattern = try self.requireLuaString(args, 1, "find")
            let initIndex = args.count > 2 ? Int(try self.numberFromValue(args[2])) : 1
            let plain = args.count > 3 ? args[3].isTruthy : false
            let start = self.normalizeStringIndex(initIndex, count: subject.count, allowPastEnd: true)
            if plain {
                guard let range = self.findPlain(subject: subject, needle: pattern, from: start) else { return [.nilValue] }
                return [.number(Double(range.lowerBound + 1)), .number(Double(range.upperBound))]
            }
            guard let match = try LuaPatternMatcher(subject: subject, pattern: pattern).firstMatch(from: start) else { return [.nilValue] }
            return [.number(Double(match.start + 1)), .number(Double(match.end))] + match.captures
        }
        native("match") { [unowned self] args in
            let subject = try self.requireLuaString(args, 0, "match")
            let pattern = try self.requireLuaString(args, 1, "match")
            let initIndex = args.count > 2 ? Int(try self.numberFromValue(args[2])) : 1
            let start = self.normalizeStringIndex(initIndex, count: subject.count, allowPastEnd: true)
            guard let match = try LuaPatternMatcher(subject: subject, pattern: pattern).firstMatch(from: start) else { return [.nilValue] }
            if !match.captures.isEmpty { return match.captures }
            return [.string(LuaString(bytes: Array(subject.bytes[match.start..<match.end])))]
        }
        native("gmatch") { [unowned self] args in
            let subject = try self.requireLuaString(args, 0, "gmatch")
            let pattern = try self.requireLuaString(args, 1, "gmatch")
            var offset = 0
            let iterator = LuaNativeFunctionBox({ _ in
                guard let match = try LuaPatternMatcher(subject: subject, pattern: pattern).firstMatch(from: offset) else { return [] }
                offset = match.end > match.start ? match.end : min(subject.count + 1, match.end + 1)
                if !match.captures.isEmpty { return match.captures }
                return [.string(LuaString(bytes: Array(subject.bytes[match.start..<match.end])))]
            }, debugName: "string.gmatch iterator")
            return [.nativeFunction(iterator)]
        }
        native("gfind") { [unowned self] args in
            let gmatch = string.rawValue(forString: "gmatch")
            return try self.callValue(gmatch, arguments: args)
        }
        native("gsub") { [unowned self] args in
            let subject = try self.requireLuaString(args, 0, "gsub")
            let pattern = try self.requireLuaString(args, 1, "gsub")
            guard args.count > 2 else { throw LuaError.runtime("bad argument #3 to 'gsub'") }
            let replacement = args[2]
            let maxCount = args.count > 3 ? Int(try self.numberFromValue(args[3])) : Int.max
            var output: [UInt8] = []
            var cursor = 0
            var search = 0
            var replacements = 0
            let matcher = LuaPatternMatcher(subject: subject, pattern: pattern)

            while replacements < maxCount, search <= subject.count,
                  let match = try matcher.firstMatch(from: search) {
                if match.start < cursor { break }
                output += subject.bytes[cursor..<match.start]
                let whole = LuaString(bytes: Array(subject.bytes[match.start..<match.end]))
                let captures = match.captures.isEmpty ? [.string(whole)] : match.captures
                let replacementValue = try self.gsubReplacement(replacement, captures: captures, whole: whole)
                if let replacementValue {
                    output += replacementValue.bytes
                } else {
                    output += whole.bytes
                }
                replacements += 1
                cursor = match.end
                search = match.end > match.start ? match.end : match.end + 1
                if search > subject.count { break }
            }
            if cursor < subject.count { output += subject.bytes[cursor...] }
            return [.string(LuaString(bytes: output)), .number(Double(replacements))]
        }
        native("format") { [unowned self] args in
            guard !args.isEmpty else { throw LuaError.runtime("bad argument #1 to 'format'") }
            let format = try self.requireLuaString(args, 0, "format")
            return [.string(try self.luaFormat(format, arguments: Array(args.dropFirst())))]
        }
        native("dump") { [unowned self] args in
            guard let first = args.first, case let .luaFunction(function) = first else {
                throw LuaError.runtime("bad argument #1 to 'dump' (Lua function expected)")
            }
            self.dumpSerial &+= 1
            var bytes: [UInt8] = [0x1B] + Array("GModLua51\0".utf8)
            withUnsafeBytes(of: self.dumpSerial.littleEndian) { bytes += $0 }
            let key = LuaString(bytes: bytes)
            self.dumpRegistry[key] = function
            return [.string(key)]
        }

        setGlobal("string", value: .table(string))
        let stringMetatable = LuaTable()
        stringMetatable.rawSetValue(.table(string), forString: "__index")
        setPrimitiveMetatable(typeName: "string", table: stringMetatable)
    }

    // MARK: - Table

    private func installTableLibrary() {
        let tableLib = LuaTable()
        func native(_ name: String, _ body: @escaping LuaNativeFunction) {
            tableLib.rawSetValue(.nativeFunction(LuaNativeFunctionBox(body, debugName: "table.\(name)")), forString: name)
        }

        native("insert") { args in
            guard let first = args.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'insert' (table expected)")
            }
            if args.count == 2 {
                table.rawSetValue(args[1], forNumber: Double(table.rawLength() + 1))
            } else if args.count >= 3 {
                let position = Int(try self.numberFromValue(args[1]))
                let length = table.rawLength()
                guard position >= 1, position <= length + 1 else { throw LuaError.runtime("position out of bounds") }
                if length >= position {
                    for index in stride(from: length, through: position, by: -1) {
                        table.rawSetValue(table.rawValue(forNumber: Double(index)), forNumber: Double(index + 1))
                    }
                }
                table.rawSetValue(args[2], forNumber: Double(position))
            } else { throw LuaError.runtime("wrong number of arguments to 'insert'") }
            return []
        }

        native("remove") { args in
            guard let first = args.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'remove' (table expected)")
            }
            let length = table.rawLength()
            let position = args.count > 1 ? Int(try self.numberFromValue(args[1])) : length
            guard position >= 1, position <= length, length > 0 else { return [.nilValue] }
            let removed = table.rawValue(forNumber: Double(position))
            if position < length {
                for index in position..<length {
                    table.rawSetValue(table.rawValue(forNumber: Double(index + 1)), forNumber: Double(index))
                }
            }
            table.rawSetValue(.nilValue, forNumber: Double(length))
            return [removed]
        }

        native("concat") { [unowned self] args in
            guard let first = args.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'concat' (table expected)")
            }
            let separator = args.count > 1 ? try self.luaStringBytes(args[1]) : LuaString("")
            let start = args.count > 2 ? Int(try self.numberFromValue(args[2])) : 1
            let end = args.count > 3 ? Int(try self.numberFromValue(args[3])) : table.rawLength()
            if end < start { return [.string("")] }
            var bytes: [UInt8] = []
            for index in start...end {
                if index > start { bytes += separator.bytes }
                bytes += try self.luaStringBytes(table.rawValue(forNumber: Double(index))).bytes
            }
            return [.string(LuaString(bytes: bytes))]
        }

        // Lua 5.1 keeps table.getn as the library equivalent of the length
        // operator. The official conformance suite still calls it directly.
        native("getn") { args in
            guard let first = args.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'getn' (table expected)")
            }
            return [.number(Double(table.rawLength()))]
        }

        native("maxn") { args in
            guard let first = args.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'maxn' (table expected)")
            }
            var maximum = 0.0
            for (key, _) in table.allPairs() {
                if case let .number(number) = key, number > maximum { maximum = number }
            }
            return [.number(maximum)]
        }

        native("sort") { [unowned self] args in
            guard let first = args.first, case let .table(table) = first else {
                throw LuaError.runtime("bad argument #1 to 'sort' (table expected)")
            }
            let comparator = args.count > 1 ? args[1] : .nilValue
            var values = (1...table.rawLength()).map { table.rawValue(forNumber: Double($0)) }
            // Stable insertion sort avoids throwing from Swift's nonthrowing comparator.
            if values.count > 1 {
                for i in 1..<values.count {
                    var j = i
                    while j > 0 {
                        let shouldSwap: Bool
                        if self.isNil(comparator) {
                            shouldSwap = try self.luaLessThan(values[j], values[j - 1])
                        } else {
                            shouldSwap = (try self.callValue(comparator, arguments: [values[j], values[j - 1]]).first ?? .nilValue).isTruthy
                        }
                        if !shouldSwap { break }
                        values.swapAt(j, j - 1)
                        j -= 1
                    }
                }
            }
            for (index, value) in values.enumerated() { table.rawSetValue(value, forNumber: Double(index + 1)) }
            return []
        }

        native("foreach") { [unowned self] args in
            guard args.count >= 2, case let .table(table) = args[0] else { throw LuaError.runtime("table expected") }
            let function = args[1]
            for (key, value) in table.allPairs() {
                let result = try self.callValue(function, arguments: [key, value]).first ?? .nilValue
                if !self.isNil(result) { return [result] }
            }
            return []
        }
        native("foreachi") { [unowned self] args in
            guard args.count >= 2, case let .table(table) = args[0] else { throw LuaError.runtime("table expected") }
            let function = args[1]
            let length = table.rawLength()
            if length > 0 {
                for index in 1...length {
                    let result = try self.callValue(function, arguments: [.number(Double(index)), table.rawValue(forNumber: Double(index))]).first ?? .nilValue
                    if !self.isNil(result) { return [result] }
                }
            }
            return []
        }

        setGlobal("table", value: .table(tableLib))
    }

    // MARK: - OS

    private func installOSLibrary() {
        let os = LuaTable()
        func native(_ name: String, _ body: @escaping LuaNativeFunction) {
            os.rawSetValue(.nativeFunction(LuaNativeFunctionBox(body, debugName: "os.\(name)")), forString: name)
        }

        let clockOrigin = ProcessInfo.processInfo.systemUptime
        native("clock") { _ in [.number(ProcessInfo.processInfo.systemUptime - clockOrigin)] }
        native("difftime") { [.number(try self.requireNumber($0, 0, "difftime") - self.requireNumber($0, 1, "difftime"))] }
        native("time") { args in
            if args.isEmpty || self.isNil(args[0]) { return [.number(Date().timeIntervalSince1970)] }
            guard case let .table(table) = args[0] else { throw LuaError.runtime("bad argument #1 to 'time' (table expected)") }
            var components = DateComponents()
            components.year = Int(self.numberOrDefault(table.rawValue(forString: "year"), 1970))
            components.month = Int(self.numberOrDefault(table.rawValue(forString: "month"), 1))
            components.day = Int(self.numberOrDefault(table.rawValue(forString: "day"), 1))
            components.hour = Int(self.numberOrDefault(table.rawValue(forString: "hour"), 12))
            components.minute = Int(self.numberOrDefault(table.rawValue(forString: "min"), 0))
            components.second = Int(self.numberOrDefault(table.rawValue(forString: "sec"), 0))
            guard let date = Calendar.current.date(from: components) else { return [.nilValue] }
            return [.number(date.timeIntervalSince1970)]
        }
        native("date") { args in
            let format = args.isEmpty ? "%c" : try self.stringFromValue(args[0])
            let timestamp = args.count > 1 ? try self.numberFromValue(args[1]) : Date().timeIntervalSince1970
            let utc = format.first == "!"
            let cleanFormat = utc ? String(format.dropFirst()) : format
            let date = Date(timeIntervalSince1970: timestamp)
            if cleanFormat == "*t" {
                var calendar = Calendar.current
                if utc { calendar.timeZone = TimeZone(secondsFromGMT: 0)! }
                let comps = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second,.weekday], from: date)
                let table = LuaTable()
                table.rawSetValue(.number(Double(comps.year ?? 0)), forString: "year")
                table.rawSetValue(.number(Double(comps.month ?? 0)), forString: "month")
                table.rawSetValue(.number(Double(comps.day ?? 0)), forString: "day")
                table.rawSetValue(.number(Double(comps.hour ?? 0)), forString: "hour")
                table.rawSetValue(.number(Double(comps.minute ?? 0)), forString: "min")
                table.rawSetValue(.number(Double(comps.second ?? 0)), forString: "sec")
                table.rawSetValue(.number(Double(comps.weekday ?? 0)), forString: "wday")
                table.rawSetValue(.boolean(false), forString: "isdst")
                return [.table(table)]
            }
            return [.string(LuaString(self.strftimeLike(cleanFormat, date: date, utc: utc)))]
        }
        native("getenv") { args in
            let name = try self.requireString(args, 0, "getenv")
            return ProcessInfo.processInfo.environment[name].map { [.string(LuaString($0))] } ?? [.nilValue]
        }
        native("remove") { args in
            let path = try self.requireString(args, 0, "remove")
            do { try FileManager.default.removeItem(atPath: path); return [.boolean(true)] }
            catch { return [.nilValue, .string(LuaString(error.localizedDescription))] }
        }
        native("rename") { args in
            let from = try self.requireString(args, 0, "rename")
            let to = try self.requireString(args, 1, "rename")
            do { try FileManager.default.moveItem(atPath: from, toPath: to); return [.boolean(true)] }
            catch { return [.nilValue, .string(LuaString(error.localizedDescription))] }
        }
        native("tmpname") { _ in [.string(LuaString(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path))] }
        native("execute") { _ in [.number(-1)] } // iOS does not permit spawning arbitrary processes.
        native("setlocale") { args in
            if args.isEmpty || self.isNil(args[0]) { return [.string("C")] }
            let locale = try self.stringFromValue(args[0])
            return locale == "C" ? [.string("C")] : [.nilValue]
        }
        native("exit") { args in
            let code = args.isEmpty ? 0 : Int(try self.numberFromValue(args[0]))
            throw LuaError.runtime("os.exit(\(code)) requested")
        }
        setGlobal("os", value: .table(os))
    }

    // MARK: - IO (sandbox-safe subset with Lua 5.1 API shape)

    private func installIOLibrary() {
        let io = LuaTable()
        func native(_ name: String, _ body: @escaping LuaNativeFunction) {
            io.rawSetValue(.nativeFunction(LuaNativeFunctionBox(body, debugName: "io.\(name)")), forString: name)
        }

        native("open") { [unowned self] args in
            let path = try self.requireString(args, 0, "open")
            let mode = args.count > 1 ? try self.stringFromValue(args[1]) : "r"
            do {
                let file = try LuaFile.open(path: path, mode: mode)
                return [.userdata(self.makeFileUserdata(file))]
            } catch {
                return [.nilValue, .string(LuaString(error.localizedDescription))]
            }
        }

        native("lines") { [unowned self] args in
            let path = try self.requireString(args, 0, "lines")
            let file = try LuaFile.open(path: path, mode: "r")
            return [.nativeFunction(self.makeLineIterator(file, closeOnEOF: true))]
        }

        native("write") { [unowned self] args in
            self.emit(try args.map { try self.luaString($0) }.joined())
            return [.boolean(true)]
        }
        native("flush") { _ in [.boolean(true)] }
        native("close") { _ in [.boolean(true)] }
        native("input") { _ in [.nilValue] }
        native("output") { _ in [.nilValue] }
        native("read") { _ in [.nilValue] }
        native("popen") { _ in [.nilValue, .string("popen is unavailable on iOS")] }
        native("tmpfile") { [unowned self] _ in
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            let file = try LuaFile.open(path: path, mode: "w+")
            return [.userdata(self.makeFileUserdata(file))]
        }
        native("type") { args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { return [.nilValue] }
            return [.string(LuaString(file.closed ? "closed file" : "file"))]
        }

        setGlobal("io", value: .table(io))
    }

    // MARK: - Debug library

    private func installDebugLibrary() {
        let debug = LuaTable()
        func native(_ name: String, _ body: @escaping LuaNativeFunction) {
            debug.rawSetValue(.nativeFunction(LuaNativeFunctionBox(body, debugName: "debug.\(name)")), forString: name)
        }

        native("getregistry") { [unowned self] _ in [.table(self.registryTable)] }
        native("getmetatable") { [unowned self] args in
            guard let first = args.first, let mt = self.metatable(of: first) else { return [.nilValue] }
            return [.table(mt)]
        }
        native("setmetatable") { [unowned self] args in
            guard args.count >= 2 else { throw LuaError.runtime("bad arguments to 'debug.setmetatable'") }
            let table: LuaTable?
            switch args[1] { case .nilValue: table = nil; case let .table(mt): table = mt; default: throw LuaError.runtime("table expected") }
            switch args[0] {
            case let .table(value): value.metatable = table
            case let .userdata(value): value.metatable = table
            default: self.setPrimitiveMetatable(typeName: args[0].typeName, table: table)
            }
            return [args[0]]
        }
        native("getfenv") { [unowned self] args in
            guard let value = args.first else { return [.table(self.globalTable)] }
            switch value {
            case let .luaFunction(function): return [.table(function.environmentTable)]
            case let .userdata(userdata): return [.table(userdata.environment ?? self.globalTable)]
            case let .nativeFunction(function): return [.table(function.environment ?? self.globalTable)]
            default: return [.table(self.globalTable)]
            }
        }
        native("setfenv") { args in
            guard args.count >= 2, case let .table(env) = args[1] else { throw LuaError.runtime("table expected") }
            switch args[0] {
            case let .luaFunction(function): function.environmentTable = env
            case let .userdata(userdata): userdata.environment = env
            case let .nativeFunction(function): function.environment = env
            default: throw LuaError.runtime("cannot change environment")
            }
            return [args[0]]
        }
        native("getinfo") { [unowned self] args in
            let target: LuaValue
            let isStackQuery: Bool
            let stackFrame: LuaCallFrame?
            if let first = args.first {
                switch first {
                case .luaFunction, .nativeFunction:
                    target = first
                    isStackQuery = false
                    stackFrame = nil
                case let .number(level):
                    guard let frame = self.currentLuaCallFrame(level: Int(level)) else {
                        return [.nilValue]
                    }
                    target = .luaFunction(frame.function)
                    isStackQuery = true
                    stackFrame = frame
                default:
                    return [.nilValue]
                }
            } else {
                guard let frame = self.currentLuaCallFrame() else { return [.nilValue] }
                target = .luaFunction(frame.function)
                isStackQuery = true
                stackFrame = frame
            }

            let table = LuaTable()

            switch target {
            case let .nativeFunction(function):
                table.rawSetValue(.string("=[C]"), forString: "source")
                table.rawSetValue(.string("[C]"), forString: "short_src")
                table.rawSetValue(.number(-1), forString: "linedefined")
                table.rawSetValue(.number(-1), forString: "lastlinedefined")
                table.rawSetValue(.string("C"), forString: "what")
                table.rawSetValue(.string(""), forString: "namewhat")
                table.rawSetValue(.number(-1), forString: "currentline")
                table.rawSetValue(.number(0), forString: "nups")
                table.rawSetValue(.nativeFunction(function), forString: "func")

            case let .luaFunction(function):
                table.rawSetValue(.string(LuaString(function.sourceName)), forString: "source")
                table.rawSetValue(.string(LuaString(self.debugShortSource(function.sourceName))), forString: "short_src")
                table.rawSetValue(.number(Double(function.lineDefined)), forString: "linedefined")
                table.rawSetValue(.number(Double(function.lastLineDefined)), forString: "lastlinedefined")
                table.rawSetValue(.string(LuaString(function.lineDefined == 0 ? "main" : "Lua")), forString: "what")
                table.rawSetValue(.string(LuaString(stackFrame?.nameWhat ?? "")), forString: "namewhat")
                if let name = stackFrame?.name {
                    table.rawSetValue(.string(LuaString(name)), forString: "name")
                }
                table.rawSetValue(.number(Double(isStackQuery ? 0 : -1)), forString: "currentline")
                table.rawSetValue(.number(Double(function.closure.capturedEntries().count)), forString: "nups")
                table.rawSetValue(.luaFunction(function), forString: "func")

                let activeLines = LuaTable()
                for line in function.activeLines.sorted() {
                    activeLines.rawSetValue(.boolean(true), forNumber: Double(line))
                }
                table.rawSetValue(.table(activeLines), forString: "activelines")

            default:
                return [.nilValue]
            }

            return [.table(table)]
        }
        native("traceback") { [unowned self] args in
            let message = args.first.map { try? self.luaString($0) } ?? nil
            let stack = self.currentCallStack().frames.reversed().map {
                "\t\($0.function.sourceName): in function"
            }.joined(separator: "\n")
            let prefix = message ?? ""
            return [.string(LuaString(prefix + (prefix.isEmpty ? "" : "\n") + "stack traceback:\n" + stack))]
        }
        native("getupvalue") { [unowned self] args in
            guard args.count >= 2, case let .luaFunction(function) = args[0] else { return [.nilValue] }
            let index = Int(try self.numberFromValue(args[1]))
            let entries = function.closure.capturedEntries()
            guard index >= 1, index <= entries.count else { return [.nilValue] }
            let entry = entries[index - 1]
            return [.string(LuaString(entry.0)), entry.1]
        }
        native("setupvalue") { [unowned self] args in
            guard args.count >= 3, case let .luaFunction(function) = args[0] else { return [.nilValue] }
            let index = Int(try self.numberFromValue(args[1]))
            let entries = function.closure.capturedEntries()
            guard index >= 1, index <= entries.count else { return [.nilValue] }
            let name = entries[index - 1].0
            _ = function.closure.assignExisting(name, value: args[2])
            return [.string(LuaString(name))]
        }
        native("getlocal") { [unowned self] args in
            guard args.count >= 2 else { return [.nilValue] }
            let level = Int(try self.numberFromValue(args[0]))
            let index = Int(try self.numberFromValue(args[1]))
            guard let env = self.currentLuaEnvironment(level: level + 1) else { return [.nilValue] }
            let entries = env.directEntries()
            guard index >= 1, index <= entries.count else { return [.nilValue] }
            let entry = entries[index - 1]
            return [.string(LuaString(entry.0)), entry.1]
        }
        native("setlocal") { [unowned self] args in
            guard args.count >= 3 else { return [.nilValue] }
            let level = Int(try self.numberFromValue(args[0]))
            let index = Int(try self.numberFromValue(args[1]))
            guard let env = self.currentLuaEnvironment(level: level + 1) else { return [.nilValue] }
            let entries = env.directEntries()
            guard index >= 1, index <= entries.count else { return [.nilValue] }
            let name = entries[index - 1].0
            _ = env.assignExisting(name, value: args[2])
            return [.string(LuaString(name))]
        }
        native("gethook") { _ in [.nilValue, .string(""), .number(0)] }
        native("sethook") { _ in [] }
        native("debug") { _ in [] }

        setGlobal("debug", value: .table(debug))
    }

    private func debugShortSource(_ source: String) -> String {
        if source.hasPrefix("@") {
            let path = String(source.dropFirst())
            let maximumLength = 60
            if path.count > maximumLength {
                return "..." + String(path.suffix(maximumLength - 3))
            }
            return path
        }

        if source.hasPrefix("=") {
            return String(source.dropFirst())
        }

        if source.first == "\n" || source.first == "\r" {
            return "[string \"...\"]"
        }

        let maximumSnippetLength = 51
        let firstLine = source.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let wasTruncated = firstLine.count < source.count || firstLine.count > maximumSnippetLength
        var snippet = String(firstLine.prefix(maximumSnippetLength))
        if wasTruncated { snippet += "..." }
        return "[string \"\(snippet)\"]"
    }

    // MARK: - Helpers

    func errorText(_ error: Error) -> String {
        if let raised = error as? LuaRaisedError { return raised.value.printable }
        if let luaError = error as? LuaError {
            switch luaError { case let .runtime(message): return message; default: return luaError.description }
        }
        return String(describing: error)
    }

    func requireNumber(_ args: [LuaValue], _ index: Int, _ name: String) throws -> Double {
        guard index < args.count else { throw LuaError.runtime("bad argument #\(index + 1) to '\(name)' (number expected)") }
        return try numberFromValue(args[index])
    }

    func requireString(_ args: [LuaValue], _ index: Int, _ name: String) throws -> String {
        try requireLuaString(args, index, name).utf8String
    }

    func requireLuaString(_ args: [LuaValue], _ index: Int, _ name: String) throws -> LuaString {
        guard index < args.count else { throw LuaError.runtime("bad argument #\(index + 1) to '\(name)' (string expected)") }
        return try luaStringBytes(args[index])
    }

    func numberFromValue(_ value: LuaValue) throws -> Double {
        if let number = coerceNumber(value) { return number }
        throw LuaError.runtime("number expected, got \(value.typeName)")
    }

    func stringFromValue(_ value: LuaValue) throws -> String {
        try luaStringBytes(value).utf8String
    }

    func optionalStringArgument(
        _ arguments: [LuaValue],
        at index: Int,
        defaultValue: String
    ) throws -> String {
        guard index < arguments.count, !isNil(arguments[index]) else { return defaultValue }
        return try stringFromValue(arguments[index])
    }

    func luaStringBytes(_ value: LuaValue) throws -> LuaString {
        switch value {
        case let .string(text): return text
        case .number: return LuaString(value.printable)
        default: throw LuaError.runtime("string expected, got \(value.typeName)")
        }
    }

    func byteSubstring(_ value: LuaString, i: Int, j: Int) -> LuaString {
        guard let range = normalizedByteRange(count: value.count, i: i, j: j) else { return LuaString("") }
        return LuaString(bytes: Array(value.bytes[range]))
    }

    func normalizedByteRange(count: Int, i: Int, j: Int) -> Range<Int>? {
        func normalize(_ index: Int) -> Int {
            if index > 0 { return index }
            if index < 0 { return count + index + 1 }
            return 1
        }
        let start = max(1, normalize(i))
        let end = min(count, normalize(j))
        guard start <= end, start <= count else { return nil }
        return (start - 1)..<end
    }

    func normalizeStringIndex(_ index: Int, count: Int, allowPastEnd: Bool) -> Int {
        var normalized: Int
        if index > 0 { normalized = index - 1 }
        else if index < 0 { normalized = count + index }
        else { normalized = 0 }
        let upper = allowPastEnd ? count : max(0, count - 1)
        return max(0, min(normalized, upper))
    }

    func findPlain(subject: LuaString, needle: LuaString, from: Int) -> Range<Int>? {
        if needle.isEmpty { return from..<from }
        guard needle.count <= subject.count else { return nil }
        if from > subject.count - needle.count { return nil }
        for i in from...(subject.count - needle.count) {
            if subject.bytes[i..<(i + needle.count)].elementsEqual(needle.bytes) { return i..<(i + needle.count) }
        }
        return nil
    }

    func gsubReplacement(_ replacement: LuaValue, captures: [LuaValue], whole: LuaString) throws -> LuaString? {
        switch replacement {
        case let .string(template):
            var out: [UInt8] = []
            var i = 0
            while i < template.count {
                let byte = template.bytes[i]
                if byte == 37, i + 1 < template.count { // %
                    let code = template.bytes[i + 1]
                    if code == 37 { out.append(37); i += 2; continue }
                    if code >= 48, code <= 57 {
                        let index = Int(code - 48)
                        if index == 0 { out += whole.bytes }
                        else if index - 1 < captures.count { out += try luaStringBytes(captures[index - 1]).bytes }
                        i += 2; continue
                    }
                }
                out.append(byte); i += 1
            }
            return LuaString(bytes: out)
        case let .table(table):
            let key = captures.first ?? .string(whole)
            let value = try getTableValue(table: table, receiver: .table(table), key: key, depth: 0)
            if isNil(value) || (value == false) { return nil }
            return try luaStringBytes(value)
        case .luaFunction, .nativeFunction:
            let results = try callValue(replacement, arguments: captures)
            let value = results.first ?? .nilValue
            if isNil(value) || (value == false) { return nil }
            return try luaStringBytes(value)
        default:
            throw LuaError.runtime("bad argument #3 to 'gsub' (string/function/table expected)")
        }
    }

    func luaFormat(_ format: LuaString, arguments: [LuaValue]) throws -> LuaString {
        let bytes = format.bytes
        var output: [UInt8] = []
        var index = 0
        var argumentIndex = 0

        while index < bytes.count {
            if bytes[index] != 37 { output.append(bytes[index]); index += 1; continue }
            if index + 1 < bytes.count, bytes[index + 1] == 37 { output.append(37); index += 2; continue }

            let specStart = index
            index += 1
            while index < bytes.count, [45,43,32,35,48].contains(bytes[index]) { index += 1 }
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            }
            guard index < bytes.count else { throw LuaError.runtime("invalid format (ends with '%')") }
            let conversion = bytes[index]
            index += 1
            guard argumentIndex < arguments.count else { throw LuaError.runtime("bad argument #\(argumentIndex + 2) to 'format' (no value)") }
            let argument = arguments[argumentIndex]
            argumentIndex += 1
            let spec = String(decoding: bytes[specStart..<index], as: UTF8.self)

            let rendered: String
            switch conversion {
            case 115: // s
                rendered = try luaString(argument)
            case 113: // q
                rendered = quoteLuaString(try luaStringBytes(argument))
            case 99: // c
                rendered = String(UnicodeScalar(UInt8(truncatingIfNeeded: Int(try numberFromValue(argument)))))
            case 100, 105: // d i
                rendered = String(format: spec, Int64(try numberFromValue(argument)))
            case 111, 117, 120, 88: // o u x X
                rendered = String(format: spec, UInt64(bitPattern: Int64(try numberFromValue(argument))))
            case 101, 69, 102, 103, 71: // e E f g G
                rendered = String(format: spec, try numberFromValue(argument))
            default:
                throw LuaError.runtime("invalid option '%\(Character(UnicodeScalar(conversion)))' to 'format'")
            }
            output += rendered.utf8
        }
        return LuaString(bytes: output)
    }

    func quoteLuaString(_ value: LuaString) -> String {
        var result = "\""
        for byte in value.bytes {
            switch byte {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 0: result += "\\000"
            case 32...126: result.append(Character(UnicodeScalar(byte)))
            default: result += String(format: "\\%03d", Int(byte))
            }
        }
        result += "\""
        return result
    }

    func estimatedMemoryKilobytes() -> Double { 0 }

    func numberOrDefault(_ value: LuaValue, _ fallback: Double) -> Double {
        (try? numberFromValue(value)) ?? fallback
    }

    func strftimeLike(_ format: String, date: Date, utc: Bool) -> String {
        var calendar = Calendar.current
        if utc { calendar.timeZone = TimeZone(secondsFromGMT: 0)! }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Common Lua/C strftime tokens. Unknown tokens are preserved.
        var result = format
        let replacements: [(String, String)] = [
            ("%Y", "yyyy"), ("%y", "yy"), ("%m", "MM"), ("%d", "dd"),
            ("%H", "HH"), ("%M", "mm"), ("%S", "ss"), ("%c", "yyyy-MM-dd HH:mm:ss"),
            ("%x", "yyyy-MM-dd"), ("%X", "HH:mm:ss"), ("%a", "EEE"), ("%A", "EEEE"),
            ("%b", "MMM"), ("%B", "MMMM")
        ]
        for (token, template) in replacements where result.contains(token) {
            formatter.dateFormat = template
            result = result.replacingOccurrences(of: token, with: formatter.string(from: date))
        }
        result = result.replacingOccurrences(of: "%%", with: "%")
        return result
    }

    func makeFileUserdata(_ file: LuaFile) -> LuaUserdata {
        let userdata = LuaUserdata(payload: file)
        let methods = LuaTable()
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            try file.close(); return [.boolean(true)]
        })), forString: "close")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            let formats = Array(args.dropFirst())
            return try self.readFile(file, formats: formats)
        })), forString: "read")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            for value in args.dropFirst() { try file.write(self.luaStringBytes(value).bytes) }
            return [first]
        })), forString: "write")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            try file.flush(); return [.boolean(true)]
        })), forString: "flush")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            let whence = args.count > 1 ? try self.stringFromValue(args[1]) : "cur"
            let offset = args.count > 2 ? Int64(try self.numberFromValue(args[2])) : 0
            return [.number(Double(try file.seek(whence: whence, offset: offset)))]
        })), forString: "seek")
        methods.rawSetValue(.nativeFunction(makeLineIterator(file, closeOnEOF: false)), forString: "lines")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ _ in [] })), forString: "setvbuf")
        let mt = LuaTable()
        mt.rawSetValue(.table(methods), forString: "__index")
        mt.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { return [] }
            try? file.close(); return []
        })), forString: "__gc")
        mt.rawSetValue(.string("FILE*"), forString: "__metatable")
        userdata.metatable = mt
        return userdata
    }

    func makeLineIterator(_ file: LuaFile, closeOnEOF: Bool) -> LuaNativeFunctionBox {
        LuaNativeFunctionBox({ _ in
            if let line = try file.readLine() { return [.string(LuaString(bytes: line))] }
            if closeOnEOF { try? file.close() }
            return []
        }, debugName: "file:lines iterator")
    }

    func readFile(_ file: LuaFile, formats: [LuaValue]) throws -> [LuaValue] {
        let formats = formats.isEmpty ? [LuaValue.string("*l")] : formats
        var results: [LuaValue] = []
        for formatValue in formats {
            if case let .number(count) = formatValue {
                if let bytes = try file.read(count: Int(count)) { results.append(.string(LuaString(bytes: bytes))) }
                else { results.append(.nilValue) }
                continue
            }
            let format = try stringFromValue(formatValue)
            switch format {
            case "*l":
                if let line = try file.readLine() { results.append(.string(LuaString(bytes: line))) }
                else { results.append(.nilValue) }
            case "*a":
                results.append(.string(LuaString(bytes: try file.readAll())))
            case "*n":
                if let number = try file.readNumber() { results.append(.number(number)) }
                else { results.append(.nilValue) }
            default: throw LuaError.runtime("invalid format")
            }
        }
        return results
    }
}

// MARK: - Lua file object

final class LuaFile: @unchecked Sendable {
    let handle: FileHandle
    let readable: Bool
    let writable: Bool
    var closed = false
    private var pushback: [UInt8] = []

    private init(handle: FileHandle, readable: Bool, writable: Bool) {
        self.handle = handle
        self.readable = readable
        self.writable = writable
    }

    static func open(path: String, mode: String) throws -> LuaFile {
        let fm = FileManager.default
        let readable = mode.contains("r") || mode.contains("+")
        let writable = mode.contains("w") || mode.contains("a") || mode.contains("+")
        if mode.contains("w") {
            _ = fm.createFile(atPath: path, contents: Data())
        } else if mode.contains("a"), !fm.fileExists(atPath: path) {
            _ = fm.createFile(atPath: path, contents: Data())
        }
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        if mode.contains("w") { try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0) }
        if mode.contains("a") { try handle.seekToEnd() }
        return LuaFile(handle: handle, readable: readable, writable: writable)
    }

    func close() throws {
        guard !closed else { return }
        try handle.close(); closed = true
    }

    func flush() throws { try ensureOpen(); try handle.synchronize() }

    func write(_ bytes: [UInt8]) throws {
        try ensureOpen(); guard writable else { throw LuaError.runtime("file is not writable") }
        try handle.write(contentsOf: Data(bytes))
    }

    func read(count: Int) throws -> [UInt8]? {
        try ensureOpen(); guard readable else { throw LuaError.runtime("file is not readable") }
        if count == 0 { return [] }
        var result: [UInt8] = []
        while !pushback.isEmpty && result.count < count { result.append(pushback.removeFirst()) }
        if result.count < count, let data = try handle.read(upToCount: count - result.count), !data.isEmpty { result += data }
        return result.isEmpty ? nil : result
    }

    func readAll() throws -> [UInt8] {
        try ensureOpen(); guard readable else { throw LuaError.runtime("file is not readable") }
        var result = pushback; pushback.removeAll()
        if let data = try handle.readToEnd() { result += data }
        return result
    }

    func readLine() throws -> [UInt8]? {
        var bytes: [UInt8] = []
        while let next = try read(count: 1)?.first {
            if next == 10 { break }
            bytes.append(next)
        }
        return bytes.isEmpty ? nil : bytes
    }

    func readNumber() throws -> Double? {
        try ensureOpen()
        guard readable else { throw LuaError.runtime("file is not readable") }

        // Lua's *n reader skips leading whitespace, consumes one numeric token,
        // and leaves the first non-number byte for the next read.
        var bytes: [UInt8] = []
        var started = false
        let allowed = Set("+-.0123456789eExXaAbBcCdDeEfF".utf8)

        while let byte = try read(count: 1)?.first {
            if !started && [9, 10, 13, 32].contains(byte) { continue }
            if allowed.contains(byte) {
                started = true
                bytes.append(byte)
                continue
            }
            pushback.insert(byte, at: 0)
            break
        }

        guard !bytes.isEmpty else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        if text.lowercased().hasPrefix("0x") {
            let body = String(text.dropFirst(2))
            if let value = UInt64(body, radix: 16) { return Double(value) }
        }
        return Double(text)
    }

    func seek(whence: String, offset: Int64) throws -> UInt64 {
        try ensureOpen()
        let base: Int64
        switch whence {
        case "set": base = 0
        case "cur": base = Int64(try handle.offset())
        case "end": base = Int64(try handle.seekToEnd())
        default: throw LuaError.runtime("invalid option")
        }
        let target = max(0, base + offset)
        try handle.seek(toOffset: UInt64(target))
        return UInt64(target)
    }

    private func ensureOpen() throws {
        if closed { throw LuaError.runtime("attempt to use a closed file") }
    }
}

private extension LuaValue {
    static func == (lhs: LuaValue, rhs: Bool) -> Bool {
        if case let .boolean(value) = lhs { return value == rhs }
        return false
    }
}
