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
        registerLoadedStandardLibraries()
    }

    private func registerLoadedStandardLibraries() {
        guard case let .table(package) = getGlobal("package"),
              case let .table(loaded) = package.rawValue(forString: "loaded") else { return }
        for name in ["_G", "package", "coroutine", "table", "io", "os", "string", "math", "debug"] {
            let value = name == "_G" ? LuaValue.table(globalTable) : getGlobal(name)
            if !isNil(value) { loaded.rawSetValue(value, forString: name) }
        }
    }

    // MARK: - Base library

    private func installBaseLibrary() {
        register("print") { [unowned self] arguments in
            let tostring = self.getGlobal("tostring")
            var fields: [String] = []
            fields.reserveCapacity(arguments.count)
            for argument in arguments {
                let value = try self.callValue(tostring, arguments: [argument]).first ?? .nilValue
                guard case let .string(string) = value else {
                    throw LuaError.runtime("'tostring' must return a string to 'print'")
                }
                fields.append(string.utf8String)
            }
            self.emit(fields.joined(separator: "\t"))
            return []
        }

        register("type") { arguments in
            [.string(LuaString(arguments.first?.typeName ?? "nil"))]
        }

        register("tostring") { [unowned self] arguments in
            guard let value = arguments.first else {
                throw LuaError.runtime("bad argument #1 to 'tostring' (value expected)")
            }
            return [try self.luaTostringValue(value)]
        }

        register("tonumber") { [unowned self] arguments in
            guard let first = arguments.first else {
                throw LuaError.runtime("bad argument #1 to 'tonumber' (value expected)")
            }
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

        register("assert") { [unowned self] arguments in
            let condition = arguments.first ?? .nilValue
            guard condition.isTruthy else {
                let message: LuaString
                if arguments.count > 1, !self.isNil(arguments[1]) {
                    do {
                        message = try self.luaStringBytes(arguments[1])
                    } catch {
                        throw LuaError.runtime("bad argument #2 to 'assert' (string expected, got \(arguments[1].typeName))")
                    }
                } else {
                    message = "assertion failed!"
                }

                if let frame = self.currentLuaCallFrame(level: 2),
                   case let .luaFunction(function) = frame.callable {
                    let location = LuaString("\(self.debugShortSource(function.sourceName)):\(max(0, frame.currentLine)): ")
                    throw LuaRaisedError(.string(location + message))
                }
                throw LuaRaisedError(.string(message))
            }
            return arguments
        }

        register("error") { [unowned self] arguments in
            let value = arguments.first ?? .nilValue
            let level = arguments.count > 1 && !self.isNil(arguments[1])
                ? Int(try self.numberFromValue(arguments[1]))
                : 1
            guard level > 0,
                  case let .string(message) = value,
                  let frame = self.currentLuaCallFrame(level: level + 1),
                  case let .luaFunction(function) = frame.callable else {
                throw LuaRaisedError(value)
            }
            let whereText = LuaString("\(self.debugShortSource(function.sourceName)):\(max(0, frame.currentLine)): ")
            throw LuaRaisedError(.string(whereText + message))
        }

        register("pcall") { [unowned self] arguments in
            guard let callable = arguments.first else {
                return [.boolean(false), .string("attempt to call a nil value")]
            }
            self.clearFailureFramesForCurrentThread()
            defer { self.clearFailureFramesForCurrentThread() }
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
            self.clearFailureFramesForCurrentThread()
            defer { self.clearFailureFramesForCurrentThread() }
            do {
                return [.boolean(true)] + (try self.callValue(callable, arguments: []))
            } catch {
                let original = self.errorValue(error)
                do {
                    let transformed = try self.callValue(handler, arguments: [original])
                    return [.boolean(false)] + transformed
                } catch {
                    return [.boolean(false), .string("error in error handling")]
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
                if level == 0 { return [.table(self.currentThreadEnvironmentTable)] }
                guard level > 0,
                      let frame = self.currentLuaCallFrame(level: level + 1),
                      !frame.isTailCall else {
                    throw LuaError.runtime("bad argument #1 to 'getfenv' (invalid level)")
                }
                switch frame.callable {
                case let .luaFunction(function): return [.table(function.environmentTable)]
                case .nativeFunction: return [.table(self.currentThreadEnvironmentTable)]
                default: throw LuaError.runtime("bad argument #1 to 'getfenv' (invalid level)")
                }
            default:
                return [.table(self.currentThreadEnvironmentTable)]
            }
        }

        register("setfenv") { [unowned self] arguments in
            guard arguments.count >= 2, case let .table(environment) = arguments[1] else {
                throw LuaError.runtime("bad argument #2 to 'setfenv' (table expected)")
            }
            switch arguments[0] {
            case let .luaFunction(function):
                self.setEnvironment(environment, for: function)
                return [arguments[0]]
            case let .number(levelNumber):
                let level = Int(levelNumber)
                if level == 0 {
                    self.currentThreadEnvironmentTable = environment
                    return [arguments[0]]
                }
                // level 1 is the Lua caller; level 1 in the raw stack is this
                // native setfenv() frame.
                let frameLevel = level + 1
                guard level > 0,
                      let frame = self.currentLuaCallFrame(level: frameLevel),
                      !frame.isTailCall,
                      let function = self.currentLuaFunction(level: frameLevel) else {
                    throw LuaError.runtime("'setfenv' cannot change environment of given object")
                }
                self.setEnvironment(environment, for: function)
                return [.luaFunction(function)]
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
            let start = arguments.count > 1 && !self.isNil(arguments[1])
                ? Int(try self.numberFromValue(arguments[1]))
                : 1
            let end = arguments.count > 2 && !self.isNil(arguments[2])
                ? Int(try self.numberFromValue(arguments[2]))
                : table.rawLength()
            if end < start { return [] }
            return (start...end).map { table.rawValue(forNumber: Double($0)) }
        }

        register("loadstring") { [unowned self] arguments in
            guard let first = arguments.first, case let .string(sourceBytes) = first else {
                throw LuaError.runtime("bad argument #1 to 'loadstring' (string expected)")
            }
            let sourceName: String?
            if arguments.indices.contains(1), !self.isNil(arguments[1]) {
                sourceName = try self.stringFromValue(arguments[1])
            } else {
                sourceName = nil
            }
            return self.loadChunk(sourceBytes, sourceName: sourceName)
        }

        register("load") { [unowned self] arguments in
            guard let reader = arguments.first else {
                throw LuaError.runtime("bad argument #1 to 'load' (function expected)")
            }
            switch reader {
            case .luaFunction, .nativeFunction:
                break
            default:
                throw LuaError.runtime("bad argument #1 to 'load' (function expected)")
            }
            let chunkName = try self.optionalStringArgument(
                arguments,
                at: 1,
                defaultValue: "=(load)"
            )
            var bytes: [UInt8] = []
            while true {
                let results: [LuaValue]
                let previousFailureFrames = self.failureFramesForCurrentThread()
                do {
                    results = try self.callValue(reader, arguments: [])
                } catch {
                    // lua_load runs its reader inside the protected parser.
                    // Reader failures therefore become load's nil/error
                    // results instead of escaping as an error from load.
                    let error = self.errorValue(error)
                    self.restoreFailureFramesForCurrentThread(previousFailureFrames)
                    return [.nilValue, error]
                }
                let value = results.first ?? .nilValue
                if case .nilValue = value { break }
                let piece: LuaString
                switch value {
                case let .string(string):
                    piece = string
                case .number:
                    // lua_isstring accepts numbers and lua_tolstring performs
                    // this coercion in Lua 5.1's generic reader.
                    piece = try self.luaStringBytes(value)
                default:
                    return [.nilValue, .string("reader function must return a string")]
                }
                // Lua 5.1's ZIO treats a zero-length reader buffer as EOF.
                // This is also how the official suite's byte-at-a-time
                // reader terminates: string.sub returns "" past the end.
                if piece.isEmpty { break }
                bytes.append(contentsOf: piece.bytes)

                let collected = LuaString(bytes: bytes)
                if dumpedFunction(matchingPrefixOf: collected) != nil {
                    return loadChunk(collected, sourceName: chunkName)
                }
                if dumpRegistry.keys.contains(where: {
                    collected.count < $0.count && $0.bytes.starts(with: collected.bytes)
                }) {
                    continue
                }

                guard let source = LuaSourceDecoder.decode(Data(bytes)) else {
                    return [.nilValue, .string("cannot decode Lua source")]
                }
                do {
                    // This is a compatibility probe over all bytes collected so
                    // far, not a streaming parser. It exists only to reproduce
                    // lua_load's observable reader-call stopping behavior.
                    _ = try parseRawSourceChunk(source)
                } catch {
                    // Lua's parser pulls reader buffers on demand and stops
                    // without draining the callback after a definitive syntax
                    // error. A token at the current buffer boundary may still
                    // need more bytes (for example the official suite's first
                    // `*` byte needs one-token lookahead), so only return once
                    // the error can no longer be completed by another piece.
                    if readerSyntaxErrorNeedsMoreInput(error, source: source) {
                        continue
                    }
                    let diagnostic = syntaxDiagnostic(
                        for: error,
                        source: source,
                        sourceName: chunkName
                    )
                    return [.nilValue, errorValue(diagnostic)]
                }
            }
            return self.loadChunk(LuaString(bytes: bytes), sourceName: chunkName)
        }

        register("loadfile") { [unowned self] arguments in
            let filename = arguments.first.map { try? self.stringFromValue($0) } ?? nil
            guard let filename else { return [.nilValue, .string("stdin loading is unavailable")] }
            do {
                let source = try self.loadSourceFile(filename)
                let function = try self.compile(source, sourceName: "@\(filename)")
                function.environmentTable = self.currentThreadEnvironmentTable
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
            case "collect":
                return [.number(Double(try self.garbageCollector.fullCollection()))]
            case "stop":
                return [.number(Double(self.garbageCollector.stop()))]
            case "restart":
                return [.number(Double(self.garbageCollector.restart()))]
            case "step":
                let size = arguments.count > 1
                    ? try self.collectGarbageIntegerArgument(arguments[1])
                    : 0
                return [.boolean(try self.garbageCollector.step(size))]
            case "count": return [.number(self.estimatedMemoryKilobytes())]
            case "setpause":
                let value = arguments.count > 1
                    ? try self.collectGarbageIntegerArgument(arguments[1])
                    : 0
                return [.number(Double(self.garbageCollector.setPause(value)))]
            case "setstepmul":
                let value = arguments.count > 1
                    ? try self.collectGarbageIntegerArgument(arguments[1])
                    : 0
                return [.number(Double(self.garbageCollector.setStepMultiplier(value)))]
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
            }, debugName: "coroutine.wrap", gcReferences: { [.thread(thread)] })
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
            let modulePath = moduleName.utf8String.replacingOccurrences(of: ".", with: "/")
            let pathText: String
            if case let .string(path) = package.rawValue(forString: "path") { pathText = path.utf8String }
            else { pathText = "?.lua;?/init.lua" }
            var errors = ""
            for template in pathText.split(separator: ";", omittingEmptySubsequences: true) {
                let candidate = String(template).replacingOccurrences(of: "?", with: modulePath)
                do {
                    let source = try self.loadSourceFile(candidate)
                    let function = try self.compile(source, sourceName: "@\(candidate)")
                    return [.luaFunction(function)]
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
            while true {
                let loader = loaders.rawValue(forNumber: Double(index))
                if self.isNil(loader) { break }
                let results = try self.callValue(loader, arguments: [.string(name)])
                if let first = results.first {
                    switch first {
                    case .luaFunction, .nativeFunction:
                        foundLoader = first
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
            // Lua 5.1 loaders receive only the module name. The searcher
            // "extra value" parameter was introduced in later Lua versions.
            let results = try self.callValue(foundLoader, arguments: [.string(name)])
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
            let alreadyLoaded = loaded.rawValue(forString: name)
            let moduleTable: LuaTable
            if case let .table(table) = alreadyLoaded {
                moduleTable = table
            } else {
                var container = self.globalTable
                var found: LuaTable?
                for component in components {
                    let existing = container.rawValue(forString: component)
                    if case let .table(table) = existing {
                        found = table
                        container = table
                    } else if self.isNil(existing) {
                        let table = LuaTable()
                        container.rawSetValue(.table(table), forString: component)
                        found = table
                        container = table
                    } else {
                        throw LuaError.runtime("name conflict for module '\(name.utf8String)'")
                    }
                }
                guard let found else { throw LuaError.runtime("invalid module name") }
                moduleTable = found
            }
            moduleTable.rawSetValue(.string(name), forString: "_NAME")
            moduleTable.rawSetValue(.table(moduleTable), forString: "_M")
            let packagePrefix: String
            if let dot = name.utf8String.lastIndex(of: ".") {
                packagePrefix = String(name.utf8String[...dot])
            } else { packagePrefix = "" }
            moduleTable.rawSetValue(.string(LuaString(packagePrefix)), forString: "_PACKAGE")
            loaded.rawSetValue(.table(moduleTable), forString: name)
            // level 1 is this native module() frame; level 2 is its Lua caller.
            if let current = self.currentLuaFunction(level: 2) {
                self.setEnvironment(moduleTable, for: current)
            }
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

        package.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            _ = try self.requireLuaString(args, 0, "loadlib")
            _ = try self.requireLuaString(args, 1, "loadlib")
            return [
                .nilValue,
                .string("dynamic libraries not enabled; check your Lua installation"),
                .string("absent")
            ]
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
            if count <= 0 || value.isEmpty { return [.string("")] }
            let (total, overflow) = value.count.multipliedReportingOverflow(by: count)
            guard !overflow, total <= Int(UInt32.max) else {
                throw LuaError.runtime("string length overflow")
            }
            var bytes = value.bytes
            bytes.reserveCapacity(total)
            while bytes.count < total {
                let amount = min(bytes.count, total - bytes.count)
                let chunk = Array(bytes.prefix(amount))
                bytes.append(contentsOf: chunk)
            }
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
            let initIndex = args.count > 2 && !self.isNil(args[2])
                ? Int(try self.numberFromValue(args[2]))
                : 1
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
            let initIndex = args.count > 2 && !self.isNil(args[2])
                ? Int(try self.numberFromValue(args[2]))
                : 1
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
        string.rawSetValue(string.rawValue(forString: "gmatch"), forString: "gfind")
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
            var nonce = self.dumpRegistryNonce.uuid
            withUnsafeBytes(of: &nonce) { bytes += $0 }
            withUnsafeBytes(of: self.dumpSerial.littleEndian) { bytes += $0 }
            let key = LuaString(bytes: bytes)
            self.dumpRegistry[key] = LuaDumpedFunction(function)
            return [.string(key)]
        }

        setGlobal("string", value: .table(string))
        let stringMetatable = LuaTable()
        stringMetatable.rawSetValue(.table(string), forString: "__index")
        setPrimitiveMetatable(typeName: "string", table: stringMetatable)
    }

    private func loadChunk(_ bytes: LuaString, sourceName: String?) -> [LuaValue] {
        if let dumped = dumpedFunction(matchingPrefixOf: bytes) {
            let function = dumped.instantiate(
                environmentTable: currentThreadEnvironmentTable
            )
            garbageCollector.adopt(.luaFunction(function))
            return [.luaFunction(function)]
        }

        guard let decodedSource = LuaSourceDecoder.decode(Data(bytes.bytes)) else {
            return [.nilValue, .string("cannot decode Lua source")]
        }
        do {
            let function = try compile(
                decodedSource,
                sourceName: sourceName ?? decodedSource
            )
            function.environmentTable = currentThreadEnvironmentTable
            return [.luaFunction(function)]
        } catch {
            return [.nilValue, errorValue(error)]
        }
    }

    private func dumpedFunction(matchingPrefixOf bytes: LuaString) -> LuaDumpedFunction? {
        dumpRegistry.first { entry in
            bytes.count >= entry.key.count && bytes.bytes.starts(with: entry.key.bytes)
        }?.value
    }

    private func readerSyntaxErrorNeedsMoreInput(
        _ error: Error,
        source: String
    ) -> Bool {
        let line: Int
        let column: Int
        let message: String
        let isLexerError: Bool
        switch error {
        case let LuaError.lexer(errorLine, errorColumn, errorMessage):
            line = errorLine
            column = errorColumn
            message = errorMessage
            isLexerError = true
        case let LuaError.parser(errorLine, errorColumn, errorMessage):
            line = errorLine
            column = errorColumn
            message = errorMessage
            isLexerError = false
        default:
            return false
        }

        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\r", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 1, line <= lines.count else {
            return false
        }
        let characters = Array(lines[line - 1])
        let start = max(0, column - 1)

        if isLexerError {
            // These scanners reached the current buffer boundary while inside
            // a token. Quoted strings need extra inspection because Lua allows
            // a backslash-escaped physical line ending inside the token.
            if message == "unfinished long string/comment" ||
                message == "unfinished block comment" {
                return true
            }
            if message == "unfinished string" {
                guard line < lines.count else { return true }

                // The lexer reports the opening quote's line for both cases.
                // A raw newline is definitive, while a backslash-escaped line
                // ending is part of a valid quoted string and may be followed
                // by the closing quote in a later reader piece.
                for lineIndex in (line - 1)..<(lines.count - 1) {
                    let lineCharacters = Array(lines[lineIndex])
                    let relevantCharacters = lineIndex == line - 1
                        ? Array(lineCharacters.dropFirst(start + 1))
                        : lineCharacters
                    let trailingBackslashes = relevantCharacters
                        .reversed()
                        .prefix { $0 == "\\" }
                        .count
                    if trailingBackslashes.isMultiple(of: 2) {
                        return false
                    }
                }
                return true
            }

            guard line == lines.count, start < characters.count else {
                return false
            }
            let remainder = String(characters[start...]).lowercased()
            switch message {
            case "malformed number":
                return remainder.hasSuffix("e") ||
                    remainder.hasSuffix("e+") ||
                    remainder.hasSuffix("e-") ||
                    remainder.hasSuffix("0x")
            case "expected '&' after '&'":
                return remainder == "&"
            case "expected '|' after '|'":
                return remainder == "|"
            case "unexpected '~'":
                return remainder == "~"
            default:
                return false
            }
        }

        let near = sourceTokenNear(source, line: line, column: column)
        if near == "<eof>" {
            return true
        }
        guard line == lines.count, start < characters.count else {
            return false
        }

        let remainder = String(characters[start...])
        if near == "[" {
            if remainder.first == "[" &&
                remainder.dropFirst().allSatisfy({ $0 == "=" }) {
                return true
            }
        }
        if near == "." && (remainder == "." || remainder == "..") {
            return true
        }
        if near == "/" && remainder == "/" {
            return true
        }

        let tokenEnd = min(characters.count, start + near.count)
        return tokenEnd == characters.count
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
            let insertedIndex: Int
            if args.count == 2 {
                insertedIndex = table.rawLength() + 1
                table.rawSetValue(args[1], forNumber: Double(insertedIndex))
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
                insertedIndex = position
            } else { throw LuaError.runtime("wrong number of arguments to 'insert'") }
            // GLua extends Lua 5.1's table.insert by returning the actual
            // 1-based position. Stock DComboBox uses this value as its data key.
            return [.number(Double(insertedIndex))]
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
            switch comparator {
            case .nilValue, .luaFunction, .nativeFunction:
                break
            default:
                throw LuaError.runtime("bad argument #2 to 'sort' (function expected, got \(comparator.typeName))")
            }

            let length = table.rawLength()
            guard length > 1 else { return [] }
            var values = (0..<length).map { table.rawValue(forNumber: Double($0 + 1)) }

            func comesBefore(_ lhs: LuaValue, _ rhs: LuaValue) throws -> Bool {
                if self.isNil(comparator) {
                    return try self.luaLessThan(lhs, rhs)
                }
                return (try self.callValue(comparator, arguments: [lhs, rhs]).first ?? .nilValue).isTruthy
            }

            // Lua 5.1's table library uses a median-of-three quicksort. Recurse
            // into the smaller partition and iterate over the larger one so the
            // native stack remains logarithmic even for adversarial inputs.
            func auxiliarySort(_ initialLower: Int, _ initialUpper: Int) throws {
                var lower = initialLower
                var upper = initialUpper

                while lower < upper {
                    if try comesBefore(values[upper], values[lower]) {
                        values.swapAt(lower, upper)
                    }
                    if upper - lower == 1 { break }

                    var middle = (lower + upper) / 2
                    if try comesBefore(values[middle], values[lower]) {
                        values.swapAt(middle, lower)
                    } else if try comesBefore(values[upper], values[middle]) {
                        values.swapAt(middle, upper)
                    }
                    if upper - lower == 2 { break }

                    values.swapAt(middle, upper - 1)
                    let pivot = values[upper - 1]
                    var left = lower
                    var right = upper - 1

                    while true {
                        repeat {
                            left += 1
                            guard left <= upper else {
                                throw LuaError.runtime("invalid order function for sorting")
                            }
                        } while try comesBefore(values[left], pivot)

                        repeat {
                            right -= 1
                            guard right >= lower else {
                                throw LuaError.runtime("invalid order function for sorting")
                            }
                        } while try comesBefore(pivot, values[right])

                        if right < left { break }
                        values.swapAt(left, right)
                    }

                    values.swapAt(upper - 1, left)
                    middle = left

                    if middle - lower < upper - middle {
                        try auxiliarySort(lower, middle - 1)
                        lower = middle + 1
                    } else {
                        try auxiliarySort(middle + 1, upper)
                        upper = middle - 1
                    }
                }
            }

            try auxiliarySort(0, values.count - 1)
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
            if args.isEmpty || self.isNil(args[0]) {
                return [.number(Date().timeIntervalSince1970.rounded(.towardZero))]
            }
            guard case let .table(table) = args[0] else { throw LuaError.runtime("bad argument #1 to 'time' (table expected)") }

            var components = DateComponents()
            components.second = try self.luaOSDateComponent(table, named: "sec", defaultValue: 0)
            components.minute = try self.luaOSDateComponent(table, named: "min", defaultValue: 0)
            components.hour = try self.luaOSDateComponent(table, named: "hour", defaultValue: 12)
            components.day = try self.luaOSDateComponent(table, named: "day")
            components.month = try self.luaOSDateComponent(table, named: "month")
            components.year = try self.luaOSDateComponent(table, named: "year")

            let isDSTValue = try self.luaOSDateField(table, named: "isdst")
            let requestedDST = self.isNil(isDSTValue) ? nil : isDSTValue.isTruthy
            guard let date = self.luaOSLocalDate(
                from: components,
                requestedDaylightSavingTime: requestedDST
            ) else { return [.nilValue] }
            return [.number(date.timeIntervalSince1970.rounded(.towardZero))]
        }
        native("date") { args in
            let format = args.isEmpty ? "%c" : try self.stringFromValue(args[0])
            let timestamp = args.count > 1 ? try self.numberFromValue(args[1]) : Date().timeIntervalSince1970
            let utc = format.first == "!"
            let cleanFormat = utc ? String(format.dropFirst()) : format
            let date = Date(timeIntervalSince1970: timestamp.rounded(.towardZero))
            if cleanFormat == "*t" {
                let calendar = self.luaOSCalendar(utc: utc)
                let comps = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second,.weekday], from: date)
                let table = LuaTable()
                table.rawSetValue(.number(Double(comps.year ?? 0)), forString: "year")
                table.rawSetValue(.number(Double(comps.month ?? 0)), forString: "month")
                table.rawSetValue(.number(Double(comps.day ?? 0)), forString: "day")
                table.rawSetValue(.number(Double(comps.hour ?? 0)), forString: "hour")
                table.rawSetValue(.number(Double(comps.minute ?? 0)), forString: "min")
                table.rawSetValue(.number(Double(comps.second ?? 0)), forString: "sec")
                table.rawSetValue(.number(Double(comps.weekday ?? 0)), forString: "wday")
                table.rawSetValue(
                    .number(Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 0)),
                    forString: "yday"
                )
                table.rawSetValue(
                    .boolean(calendar.timeZone.isDaylightSavingTime(for: date)),
                    forString: "isdst"
                )
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
            do {
                if let virtualFileSystem = self.virtualFileSystem {
                    try virtualFileSystem.removeFile(at: path)
                } else {
                    try FileManager.default.removeItem(atPath: path)
                }
                return [.boolean(true)]
            }
            catch { return [.nilValue, .string(LuaString(error.localizedDescription))] }
        }
        native("rename") { args in
            let from = try self.requireString(args, 0, "rename")
            let to = try self.requireString(args, 1, "rename")
            do {
                if let virtualFileSystem = self.virtualFileSystem {
                    try virtualFileSystem.moveFile(from: from, to: to)
                } else {
                    try FileManager.default.moveItem(atPath: from, toPath: to)
                }
                return [.boolean(true)]
            }
            catch { return [.nilValue, .string(LuaString(error.localizedDescription))] }
        }
        native("tmpname") { _ in
            let path = self.virtualFileSystem == nil
                ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
                : ".tmp/\(UUID().uuidString)"
            return [.string(LuaString(path))]
        }
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
        func native(
            _ name: String,
            gcReferences: @escaping () -> [LuaValue] = { [] },
            _ body: @escaping LuaNativeFunction
        ) {
            io.rawSetValue(
                .nativeFunction(LuaNativeFunctionBox(
                    body,
                    debugName: "io.\(name)",
                    gcReferences: gcReferences
                )),
                forString: name
            )
        }

        func file(from value: LuaValue, function: String) throws -> LuaFile {
            guard case let .userdata(userdata) = value,
                  let file = userdata.payload as? LuaFile else {
                throw LuaError.runtime("bad argument #1 to '\(function)' (file expected)")
            }
            return file
        }

        func openValue(path: String, mode: String) throws -> LuaValue {
            .userdata(makeFileUserdata(try LuaFile.open(
                path: path,
                mode: mode,
                virtualFileSystem: virtualFileSystem
            )))
        }

        // The embedded runtime has no process-level stdin/stdout FILE pointers,
        // but Lua code relies on their identity and file-handle behaviour. Keep
        // sandboxed handles for those values; io.write still forwards stdout to
        // the host console emitter below.
        let standardFileSystem = try! LuaMemoryFileSystem(initialFiles: [
            ".stdio/stdin": Data(),
            ".stdio/stdout": Data(),
            ".stdio/stderr": Data()
        ])
        let stdinValue = LuaValue.userdata(makeFileUserdata(
            try! LuaFile.open(path: ".stdio/stdin", mode: "r", virtualFileSystem: standardFileSystem),
            closeOnGC: false
        ))
        let stdoutValue = LuaValue.userdata(makeFileUserdata(
            try! LuaFile.open(path: ".stdio/stdout", mode: "a", virtualFileSystem: standardFileSystem),
            closeOnGC: false
        ))
        let stderrValue = LuaValue.userdata(makeFileUserdata(
            try! LuaFile.open(path: ".stdio/stderr", mode: "a", virtualFileSystem: standardFileSystem),
            closeOnGC: false
        ))
        io.rawSetValue(stdinValue, forString: "stdin")
        io.rawSetValue(stdoutValue, forString: "stdout")
        io.rawSetValue(stderrValue, forString: "stderr")
        var defaultInput = stdinValue
        var defaultOutput = stdoutValue

        native("open") { [unowned self] args in
            let path = try self.requireString(args, 0, "open")
            let mode = args.count > 1 ? try self.stringFromValue(args[1]) : "r"
            do {
                return [try openValue(path: path, mode: mode)]
            } catch {
                return self.luaFileFailure(error)
            }
        }

        native("lines", gcReferences: { [defaultInput, defaultOutput] }) { [unowned self] args in
            if args.isEmpty {
                let input = try file(from: defaultInput, function: "lines")
                return [.nativeFunction(self.makeLineIterator(
                    input,
                    closeOnEOF: false,
                    retainedValue: defaultInput
                ))]
            }
            let path = try self.requireString(args, 0, "lines")
            let value = try openValue(path: path, mode: "r")
            return [.nativeFunction(self.makeLineIterator(
                try file(from: value, function: "lines"),
                closeOnEOF: true,
                retainedValue: value
            ))]
        }

        native("write") { [unowned self] args in
            if self.rawEqual(defaultOutput, stdoutValue) {
                let bytes = try args.flatMap { try self.luaStringBytes($0).bytes }
                self.emit(LuaString(bytes: bytes).utf8String)
                return [stdoutValue]
            }
            let output = try file(from: defaultOutput, function: "write")
            do {
                try output.validateWritable()
                for value in args { try output.write(self.luaStringBytes(value).bytes) }
                return [defaultOutput]
            } catch let error as LuaFileOperationError where error.isRecoverableIOFailure {
                return self.luaFileFailure(error)
            }
        }
        native("flush") { _ in
            guard case .nilValue = defaultOutput else {
                try file(from: defaultOutput, function: "flush").flush()
                return [.boolean(true)]
            }
            return [.boolean(true)]
        }
        native("close") { args in
            let target = args.first ?? defaultOutput
            if case .nilValue = target { return [.boolean(true)] }
            try file(from: target, function: "close").close()
            return [.boolean(true)]
        }
        native("input") { [unowned self] args in
            guard let value = args.first else { return [defaultInput] }
            if case .string = value {
                defaultInput = try openValue(path: try self.stringFromValue(value), mode: "r")
            } else {
                _ = try file(from: value, function: "input")
                defaultInput = value
            }
            return [defaultInput]
        }
        native("output") { [unowned self] args in
            guard let value = args.first else { return [defaultOutput] }
            if case .string = value {
                defaultOutput = try openValue(path: try self.stringFromValue(value), mode: "w")
            } else {
                _ = try file(from: value, function: "output")
                defaultOutput = value
            }
            return [defaultOutput]
        }
        native("read") { args in
            let input = try file(from: defaultInput, function: "read")
            return try self.readFile(input, formats: args)
        }
        native("popen") { _ in
            throw LuaError.runtime("popen is unavailable in the embedded runtime")
        }
        native("tmpfile") { [unowned self] _ in
            let path = self.virtualFileSystem == nil
                ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
                : ".tmp/\(UUID().uuidString)"
            return [try openValue(path: path, mode: "w+")]
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
            case let .thread(thread): return [.table(thread.environmentTable)]
            default: return [.table(self.globalTable)]
            }
        }
        native("setfenv") { args in
            guard args.count >= 2, case let .table(env) = args[1] else { throw LuaError.runtime("table expected") }
            switch args[0] {
            case let .luaFunction(function): self.setEnvironment(env, for: function)
            case let .userdata(userdata): userdata.environment = env
            case let .nativeFunction(function): function.environment = env
            case let .thread(thread): thread.environmentTable = env
            default: throw LuaError.runtime("cannot change environment")
            }
            return [args[0]]
        }
        native("getinfo") { [unowned self] args in
            let queryArguments: [LuaValue]
            let queriedThreadFrames: [LuaCallFrame]?
            if let first = args.first, case let .thread(thread) = first {
                queryArguments = Array(args.dropFirst())
                queriedThreadFrames = thread.luaDebugFrames()
            } else {
                queryArguments = args
                queriedThreadFrames = nil
            }

            let target: LuaValue
            let isStackQuery: Bool
            let stackFrame: LuaCallFrame?
            let isTailStackFrame: Bool
            if let first = queryArguments.first {
                switch first {
                case .luaFunction, .nativeFunction:
                    target = first
                    isStackQuery = false
                    stackFrame = nil
                    isTailStackFrame = false
                case let .number(level):
                    // The native debug.getinfo call itself occupies the top
                    // frame; Lua level 1 is its caller.
                    let frame: LuaCallFrame
                    if let frames = queriedThreadFrames {
                        let levelIndex = Int(level)
                        guard levelIndex >= 1, levelIndex <= frames.count else { return [.nilValue] }
                        frame = frames[frames.count - levelIndex]
                    } else {
                        guard let currentFrame = self.currentLuaCallFrame(level: Int(level) + 1) else {
                            return [.nilValue]
                        }
                        frame = currentFrame
                    }
                    target = frame.callable
                    isStackQuery = true
                    stackFrame = frame
                    isTailStackFrame = frame.isTailCall
                default:
                    return [.nilValue]
                }
            } else {
                guard queriedThreadFrames == nil,
                      let frame = self.currentLuaCallFrame(level: 2) else { return [.nilValue] }
                target = frame.callable
                isStackQuery = true
                stackFrame = frame
                isTailStackFrame = frame.isTailCall
            }

            let table = LuaTable()

            if isTailStackFrame {
                table.rawSetValue(.string("=(tail call)"), forString: "source")
                table.rawSetValue(.string("(tail call)"), forString: "short_src")
                table.rawSetValue(.number(-1), forString: "linedefined")
                table.rawSetValue(.number(-1), forString: "lastlinedefined")
                table.rawSetValue(.string("tail"), forString: "what")
                table.rawSetValue(.string(""), forString: "namewhat")
                table.rawSetValue(.number(-1), forString: "currentline")
                table.rawSetValue(.number(0), forString: "nups")
                return [.table(table)]
            }

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
                table.rawSetValue(.number(Double(isStackQuery ? (stackFrame?.currentLine ?? 0) : -1)), forString: "currentline")
                table.rawSetValue(.number(Double(function.upvalueNames.count)), forString: "nups")
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
            let sourceFrames: [LuaCallFrame]
            let messageIndex: Int
            let defaultLevel: Int
            if let first = args.first, case let .thread(thread) = first {
                sourceFrames = thread.callStackFrames()
                messageIndex = 1
                defaultLevel = 0
            } else {
                let failedFrames = self.failureFramesForCurrentThread()
                sourceFrames = failedFrames ?? self.currentCallStack().frames
                messageIndex = 0
                defaultLevel = failedFrames == nil ? 1 : 0
            }

            var message: String?
            if args.indices.contains(messageIndex), !self.isNil(args[messageIndex]) {
                switch args[messageIndex] {
                case .string, .number:
                    message = try self.luaString(args[messageIndex])
                default:
                    // Lua 5.1 preserves non-string error objects verbatim.
                    return [args[messageIndex]]
                }
            }

            let levelIndex = messageIndex + 1
            let level = args.indices.contains(levelIndex)
                ? max(0, Int(try self.numberFromValue(args[levelIndex])))
                : defaultLevel
            let frames = Array(sourceFrames.reversed().dropFirst(level))
            let stack = frames.map { frame -> String in
                if frame.isTailCall { return "\t(tail call): ?" }
                let quotedName = frame.name.map { " in function '\($0)'" } ?? " in function <?>"
                switch frame.callable {
                case let .luaFunction(function):
                    return "\t\(self.debugShortSource(function.sourceName)):\(frame.currentLine):\(quotedName)"
                case .nativeFunction:
                    return "\t[C]:\(quotedName)"
                default:
                    return "\t?:\(quotedName)"
                }
            }.joined(separator: "\n")
            let prefix = message.map { $0 + "\n" } ?? ""
            return [.string(LuaString(prefix + "stack traceback:\n" + stack))]
        }
        native("getupvalue") { [unowned self] args in
            guard args.count >= 2, case let .luaFunction(function) = args[0] else { return [.nilValue] }
            let index = Int(try self.numberFromValue(args[1]))
            let entries = function.upvalueEntries()
            guard index >= 1, index <= entries.count else { return [.nilValue] }
            let entry = entries[index - 1]
            return [.string(LuaString(entry.0)), entry.1]
        }
        native("setupvalue") { [unowned self] args in
            guard args.count >= 3, case let .luaFunction(function) = args[0] else { return [.nilValue] }
            let index = Int(try self.numberFromValue(args[1]))
            let entries = function.upvalueEntries()
            guard index >= 1, index <= entries.count else { return [.nilValue] }
            let name = entries[index - 1].0
            _ = function.closure.assignExisting(name, value: args[2])
            return [.string(LuaString(name))]
        }
        native("getlocal") { [unowned self] args in
            var argumentIndex = 0
            let thread: LuaThread?
            if let first = args.first, case let .thread(value) = first {
                thread = value
                argumentIndex = 1
            } else {
                thread = nil
            }
            guard args.indices.contains(argumentIndex + 1) else { return [.nilValue] }
            let level = Int(try self.numberFromValue(args[argumentIndex]))
            let index = Int(try self.numberFromValue(args[argumentIndex + 1]))
            if thread == nil, level == 0 {
                guard index >= 1,
                      let frame = self.currentLuaCallFrame(),
                      index <= frame.temporaries.count else { return [.nilValue] }
                return [.string("(*temporary)"), frame.temporaries[index - 1]]
            }
            let frame: LuaCallFrame
            if let thread {
                let frames = thread.luaDebugFrames()
                guard level >= 1, level <= frames.count else { return [.nilValue] }
                frame = frames[frames.count - level]
            } else {
                guard let currentFrame = self.currentLuaCallFrame(level: level + 1) else { return [.nilValue] }
                frame = currentFrame
            }
            guard let env = frame.environment else { return [.nilValue] }
            let entries = env.activeFunctionEntries()
            guard index >= 1 else { return [.nilValue] }
            if index <= entries.count {
                let entry = entries[index - 1]
                return [.string(LuaString(entry.0)), entry.1]
            }
            let temporaryIndex = index - entries.count - 1
            guard frame.temporaries.indices.contains(temporaryIndex) else { return [.nilValue] }
            return [.string("(*temporary)"), frame.temporaries[temporaryIndex]]
        }
        native("setlocal") { [unowned self] args in
            var argumentIndex = 0
            let thread: LuaThread?
            if let first = args.first, case let .thread(value) = first {
                thread = value
                argumentIndex = 1
            } else {
                thread = nil
            }
            guard args.indices.contains(argumentIndex + 2) else { return [.nilValue] }
            let level = Int(try self.numberFromValue(args[argumentIndex]))
            let index = Int(try self.numberFromValue(args[argumentIndex + 1]))
            let replacement = args[argumentIndex + 2]
            let frameLevel = level + 1
            let frame: LuaCallFrame
            if let thread {
                let frames = thread.luaDebugFrames()
                guard level >= 1, level <= frames.count else { return [.nilValue] }
                frame = frames[frames.count - level]
            } else {
                guard let currentFrame = self.currentLuaCallFrame(level: frameLevel) else { return [.nilValue] }
                frame = currentFrame
            }
            guard index >= 1, let env = frame.environment else { return [.nilValue] }
            let entries = env.activeFunctionEntries()
            if index <= entries.count,
               let name = env.assignActiveFunctionEntry(at: index, value: replacement) {
                return [.string(LuaString(name))]
            }
            let temporaryIndex = index - entries.count - 1
            guard thread == nil, frame.temporaries.indices.contains(temporaryIndex) else { return [.nilValue] }
            let stack = self.currentCallStack()
            let storageIndex = stack.frames.count - frameLevel
            stack.frames[storageIndex].temporaries[temporaryIndex] = replacement
            return [.string("(*temporary)")]
        }
        native("gethook") { [unowned self] args in
            let thread: LuaThread?
            if let first = args.first, case let .thread(value) = first { thread = value }
            else { thread = nil }
            let hookState = self.debugHookState(for: thread)
            let function = self.isNil(hookState.function) ? LuaValue.nilValue : hookState.function
            return [function, .string(LuaString(hookState.mask)), .number(Double(hookState.count))]
        }
        native("sethook") { [unowned self] args in
            var argumentIndex = 0
            let thread: LuaThread?
            if let first = args.first, case let .thread(value) = first {
                thread = value
                argumentIndex = 1
            } else {
                thread = nil
            }

            guard args.indices.contains(argumentIndex), !self.isNil(args[argumentIndex]) else {
                self.clearDebugHook(thread: thread)
                return []
            }
            let first = args[argumentIndex]
            guard first.typeName == "function" else {
                throw LuaError.runtime("bad argument to 'sethook' (function expected)")
            }
            let maskIndex = argumentIndex + 1
            let countIndex = argumentIndex + 2
            let mask = args.indices.contains(maskIndex) ? try self.stringFromValue(args[maskIndex]) : ""
            let count = args.indices.contains(countIndex) ? Int(try self.numberFromValue(args[countIndex])) : 0
            self.setDebugHook(function: first, mask: mask, count: count, thread: thread)
            return []
        }
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
        guard let number = coerceNumber(args[index]) else {
            throw LuaError.runtime("bad argument #\(index + 1) to '\(name)' (number expected)")
        }
        return number
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

    func collectGarbageIntegerArgument(_ value: LuaValue) throws -> Int {
        let number = try numberFromValue(value)
        let truncated = number.rounded(.towardZero)
        let lowerInclusive = Double(Int.min)
        let upperExclusive = -lowerInclusive
        guard truncated.isFinite,
              truncated >= lowerInclusive,
              truncated < upperExclusive else {
            throw LuaError.runtime(
                "bad argument #2 to 'collectgarbage' (number has no integer representation)"
            )
        }
        return Int(truncated)
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
            return 0
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
                        else if index - 1 < captures.count {
                            out += try luaStringBytes(captures[index - 1]).bytes
                        } else {
                            throw LuaError.runtime("invalid capture index")
                        }
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

        func padded(_ value: [UInt8], width: Int?, leftAligned: Bool) -> [UInt8] {
            guard let width, width > value.count else { return value }
            let padding = Array(repeating: UInt8(32), count: width - value.count)
            return leftAligned ? value + padding : padding + value
        }

        while index < bytes.count {
            if bytes[index] != 37 { output.append(bytes[index]); index += 1; continue }
            if index + 1 < bytes.count, bytes[index + 1] == 37 { output.append(37); index += 2; continue }

            let specStart = index
            index += 1
            var leftAligned = false
            while index < bytes.count, [45,43,32,35,48].contains(bytes[index]) {
                if bytes[index] == 45 { leftAligned = true }
                index += 1
            }
            let widthStart = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            let width = widthStart < index
                ? Int(String(decoding: bytes[widthStart..<index], as: UTF8.self))
                : nil
            var precision: Int?
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                let precisionStart = index
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
                precision = precisionStart < index
                    ? Int(String(decoding: bytes[precisionStart..<index], as: UTF8.self))
                    : 0
            }
            guard index < bytes.count else { throw LuaError.runtime("invalid format (ends with '%')") }
            let conversion = bytes[index]
            index += 1
            guard argumentIndex < arguments.count else { throw LuaError.runtime("bad argument #\(argumentIndex + 2) to 'format' (no value)") }
            let argument = arguments[argumentIndex]
            argumentIndex += 1
            let spec = String(decoding: bytes[specStart..<index], as: UTF8.self)

            let rendered: [UInt8]
            switch conversion {
            case 115: // s
                var value = try luaStringBytes(argument).bytes
                if let precision, value.count > precision { value = Array(value.prefix(precision)) }
                rendered = padded(value, width: width, leftAligned: leftAligned)
            case 113: // q
                rendered = quoteLuaString(try luaStringBytes(argument))
            case 99: // c
                let value = [UInt8(truncatingIfNeeded: Int(try numberFromValue(argument)))]
                rendered = padded(value, width: width, leftAligned: leftAligned)
            case 100, 105: // d i
                rendered = Array(String(format: spec, Int64(try numberFromValue(argument))).utf8)
            case 111, 117, 120, 88: // o u x X
                rendered = Array(String(format: spec, UInt64(bitPattern: Int64(try numberFromValue(argument)))).utf8)
            case 101, 69, 102, 103, 71: // e E f g G
                rendered = Array(String(format: spec, try numberFromValue(argument)).utf8)
            default:
                throw LuaError.runtime("invalid option '%\(Character(UnicodeScalar(conversion)))' to 'format'")
            }
            output += rendered
        }
        return LuaString(bytes: output)
    }

    func quoteLuaString(_ value: LuaString) -> [UInt8] {
        var result: [UInt8] = [34]
        for byte in value.bytes {
            switch byte {
            case 34, 92, 10: result += [92, byte]
            case 13: result += [92, 114]
            case 0: result += [92, 48, 48, 48]
            default: result.append(byte)
            }
        }
        result.append(34)
        return result
    }

    func estimatedMemoryKilobytes() -> Double { garbageCollector.memoryKilobytes() }

    func luaOSCalendar(utc: Bool) -> Calendar {
        luaOSCalendar(timeZone: utc ? TimeZone(secondsFromGMT: 0)! : TimeZone.current)
    }

    func luaOSCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    func luaOSDateField(_ table: LuaTable, named name: String) throws -> LuaValue {
        try getTableValue(
            table: table,
            receiver: .table(table),
            key: .string(LuaString(name)),
            depth: 0
        )
    }

    func luaOSDateComponent(
        _ table: LuaTable,
        named name: String,
        defaultValue: Int? = nil
    ) throws -> Int {
        let value = try luaOSDateField(table, named: name)
        guard let number = coerceNumber(value) else {
            guard let defaultValue else {
                throw LuaError.runtime("field '\(name)' missing in date table")
            }
            return defaultValue
        }

        guard number.isFinite,
              number >= Double(Int32.min),
              number <= Double(Int32.max) else {
            throw LuaError.runtime("field '\(name)' is out of range")
        }
        return Int(number)
    }

    func luaOSLocalDate(
        from components: DateComponents,
        requestedDaylightSavingTime: Bool?,
        timeZone: TimeZone = .current
    ) -> Date? {
        let localCalendar = luaOSCalendar(timeZone: timeZone)
        guard let inferredDate = localCalendar.date(from: components) else { return nil }
        guard let requestedDaylightSavingTime else { return inferredDate }

        guard let requestedOffset = luaOSGMTOffset(
            matchingDaylightSavingTime: requestedDaylightSavingTime,
            in: timeZone,
            around: inferredDate
        ) else {
            // Zones without the requested state have no alternate UTC offset;
            // mktime normalizes the flag back to the zone's only valid state.
            return inferredDate
        }

        let utcCalendar = luaOSCalendar(utc: true)
        guard let wallClockAsUTC = utcCalendar.date(from: components) else { return nil }
        return wallClockAsUTC.addingTimeInterval(-Double(requestedOffset))
    }

    func luaOSGMTOffset(
        matchingDaylightSavingTime requestedState: Bool,
        in timeZone: TimeZone,
        around date: Date
    ) -> Int? {
        for distance in 0...370 {
            let directions = distance == 0 ? [0] : [-1, 1]
            for direction in directions {
                let probe = date.addingTimeInterval(Double(distance * direction) * 86_400)
                if timeZone.isDaylightSavingTime(for: probe) == requestedState {
                    return timeZone.secondsFromGMT(for: probe)
                }
            }
        }
        return nil
    }

    func strftimeLike(_ format: String, date: Date, utc: Bool) -> String {
        let calendar = luaOSCalendar(utc: utc)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        // Common Lua/C strftime tokens. Unknown tokens are preserved.
        var result = format
        let components = calendar.dateComponents([.weekday], from: date)
        let weekday = (components.weekday ?? 1) - 1 // C strftime: Sunday is zero.
        let yearDay = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        result = result.replacingOccurrences(of: "%w", with: String(weekday))
        result = result.replacingOccurrences(of: "%j", with: String(format: "%03d", yearDay))
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

    func loadSourceFile(_ path: String) throws -> String {
        if let virtualFileSystem, virtualFileSystem.fileExists(at: path) {
            let data = try virtualFileSystem.readFile(at: path)
            guard let source = LuaSourceDecoder.decode(data) else {
                throw LuaError.runtime("cannot decode Lua source: \(path)")
            }
            return source
        }
        if let fileLoader { return try fileLoader(path) }
        if virtualFileSystem == nil, FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let source = LuaSourceDecoder.decode(data) else {
                throw LuaError.runtime("cannot decode Lua source: \(path)")
            }
            return source
        }
        throw LuaError.runtime("file not found: \(path)")
    }

    func makeFileUserdata(_ file: LuaFile, closeOnGC: Bool = true) -> LuaUserdata {
        let userdata = LuaUserdata(payload: file)
        let methods = LuaTable()
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            try file.close(); return [.boolean(true)]
        })), forString: "close")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            let formats = Array(args.dropFirst())
            do {
                return try self.readFile(file, formats: formats)
            } catch let error as LuaFileOperationError where error.isRecoverableIOFailure {
                return self.luaFileFailure(error)
            }
        })), forString: "read")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            do {
                try file.validateWritable()
                for value in args.dropFirst() { try file.write(self.luaStringBytes(value).bytes) }
                return [first]
            } catch let error as LuaFileOperationError where error.isRecoverableIOFailure {
                return self.luaFileFailure(error)
            }
        })), forString: "write")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            do {
                try file.flush()
                return [.boolean(true)]
            } catch let error as LuaFileOperationError where error.isRecoverableIOFailure {
                return self.luaFileFailure(error)
            }
        })), forString: "flush")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            guard let first = args.first, case let .userdata(ud) = first, let file = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            let whence = args.count > 1 ? try self.stringFromValue(args[1]) : "cur"
            let offset = args.count > 2 ? Int64(try self.numberFromValue(args[2])) : 0
            do {
                return [.number(Double(try file.seek(whence: whence, offset: offset)))]
            } catch let error as LuaFileOperationError where error.isRecoverableIOFailure {
                return self.luaFileFailure(error)
            }
        })), forString: "seek")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            guard let first = args.first,
                  case let .userdata(ud) = first,
                  let target = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            return [.nativeFunction(self.makeLineIterator(
                target,
                closeOnEOF: false,
                retainedValue: first
            ))]
        })), forString: "lines")
        methods.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ [unowned self] args in
            guard let first = args.first,
                  case let .userdata(ud) = first,
                  let target = ud.payload as? LuaFile else { throw LuaError.runtime("file expected") }
            let mode = try self.requireString(args, 1, "setvbuf")
            let size = args.count > 2 ? Int(try self.numberFromValue(args[2])) : nil
            try target.setBuffer(mode: mode, size: size)
            return [.boolean(true)]
        })), forString: "setvbuf")
        let mt = LuaTable()
        mt.rawSetValue(.table(methods), forString: "__index")
        mt.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ args in
            guard let first = args.first else {
                throw LuaError.runtime("bad argument #1 to '__gc' (FILE* expected, got no value)")
            }
            guard case let .userdata(ud) = first, let file = ud.payload as? LuaFile else {
                throw LuaError.runtime("bad argument #1 to '__gc' (FILE* expected)")
            }
            if closeOnGC { try? file.close() }
            return []
        })), forString: "__gc")
        mt.rawSetValue(.nativeFunction(LuaNativeFunctionBox({ args in
            guard let first = args.first,
                  case let .userdata(ud) = first,
                  let file = ud.payload as? LuaFile else { return [.string("file")] }
            return [.string(LuaString(file.closed ? "file (closed)" : "file (open)"))]
        })), forString: "__tostring")
        userdata.metatable = mt
        return userdata
    }

    func makeLineIterator(
        _ file: LuaFile,
        closeOnEOF: Bool,
        retainedValue: LuaValue
    ) -> LuaNativeFunctionBox {
        LuaNativeFunctionBox({ _ in
            if let line = try file.readLine() { return [.string(LuaString(bytes: line))] }
            if closeOnEOF { try? file.close() }
            return []
        }, debugName: "file:lines iterator", gcReferences: { [retainedValue] })
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
            case "*l", "*line":
                if let line = try file.readLine() { results.append(.string(LuaString(bytes: line))) }
                else { results.append(.nilValue) }
            case "*a", "*all":
                results.append(.string(LuaString(bytes: try file.readAll())))
            case "*n", "*number":
                if let number = try file.readNumber() { results.append(.number(number)) }
                else { results.append(.nilValue) }
            default: throw LuaError.runtime("invalid format")
            }
        }
        return results
    }

    func luaFileFailure(_ error: Error) -> [LuaValue] {
        let message: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
        let errorCode = luaFileErrorCode(error)
        return [.nilValue, .string(LuaString(message)), .number(Double(errorCode))]
    }

    private func luaFileErrorCode(_ error: Error) -> Int {
        if let operationError = error as? LuaFileOperationError {
            return operationError.errorCode
        }
        if let virtualError = error as? LuaVirtualFileSystemError {
            switch virtualError {
            case .fileNotFound: return Int(POSIXErrorCode.ENOENT.rawValue)
            case .invalidPath: return Int(POSIXErrorCode.EINVAL.rawValue)
            case .notDirectory: return Int(POSIXErrorCode.ENOTDIR.rawValue)
            case .directoryNotEmpty: return Int(POSIXErrorCode.ENOTEMPTY.rawValue)
            }
        }

        // FileHandle and Data errors preserve the native errno as an
        // NSPOSIXErrorDomain error, normally beneath one Cocoa wrapper.
        // Prefer that value so host-backed files expose the same contract as
        // C stdio instead of inventing a platform-independent placeholder.
        var nsError = error as NSError
        for _ in 0..<4 {
            if nsError.domain == NSPOSIXErrorDomain, nsError.code > 0 {
                return nsError.code
            }
            guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying !== nsError else { break }
            nsError = underlying
        }

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 4, 260:
                return Int(POSIXErrorCode.ENOENT.rawValue)
            case 257, 513:
                return Int(POSIXErrorCode.EACCES.rawValue)
            case 258, 514:
                return Int(POSIXErrorCode.EINVAL.rawValue)
            case 516:
                return Int(POSIXErrorCode.EEXIST.rawValue)
            case 640:
                return Int(POSIXErrorCode.ENOSPC.rawValue)
            case 642:
                return Int(POSIXErrorCode.EROFS.rawValue)
            default: break
            }
        }
        return Int(POSIXErrorCode.EIO.rawValue)
    }
}

// MARK: - Lua file object

enum LuaFileOperationError: Error, LocalizedError {
    case closed
    case notReadable
    case notWritable
    case invalidFileMode
    case invalidSeekOption(String)
    case negativeSeek
    case invalidReadCount

    var errorDescription: String? {
        switch self {
        case .closed: return "attempt to use a closed file"
        case .notReadable: return "file is not readable"
        case .notWritable: return "file is not writable"
        case .invalidFileMode: return "invalid file mode"
        case let .invalidSeekOption(option): return "invalid seek option '\(option)'"
        case .negativeSeek: return "invalid seek position"
        case .invalidReadCount: return "invalid read count"
        }
    }

    var errorCode: Int {
        switch self {
        case .closed, .notReadable, .notWritable:
            return Int(POSIXErrorCode.EBADF.rawValue)
        case .invalidFileMode, .invalidSeekOption, .negativeSeek, .invalidReadCount:
            return Int(POSIXErrorCode.EINVAL.rawValue)
        }
    }

    var isRecoverableIOFailure: Bool {
        switch self {
        case .notReadable, .notWritable, .negativeSeek: return true
        case .closed, .invalidFileMode, .invalidSeekOption, .invalidReadCount: return false
        }
    }
}

final class LuaFile: @unchecked Sendable {
    private enum BufferMode {
        case none
        case full
        case line
    }

    private let handle: FileHandle?
    private let hostPath: String?
    private let virtualFileSystem: LuaVirtualFileSystem?
    private let virtualPath: String?
    private var virtualBytes: [UInt8]
    private var virtualOffset: Int
    private var virtualDirty = false
    private var hostBufferingActive = false
    private let appendMode: Bool
    private var bufferMode: BufferMode = .none
    let readable: Bool
    let writable: Bool
    var closed = false
    private var pushback: [UInt8] = []

    private init(handle: FileHandle, hostPath: String, readable: Bool, writable: Bool, appendMode: Bool) {
        self.handle = handle
        self.hostPath = hostPath
        self.virtualFileSystem = nil
        self.virtualPath = nil
        self.virtualBytes = []
        self.virtualOffset = 0
        self.appendMode = appendMode
        self.readable = readable
        self.writable = writable
    }

    private init(
        virtualFileSystem: LuaVirtualFileSystem,
        path: String,
        bytes: [UInt8],
        offset: Int,
        readable: Bool,
        writable: Bool,
        appendMode: Bool
    ) {
        self.handle = nil
        self.hostPath = nil
        self.virtualFileSystem = virtualFileSystem
        self.virtualPath = path
        self.virtualBytes = bytes
        self.virtualOffset = offset
        self.appendMode = appendMode
        self.readable = readable
        self.writable = writable
    }

    static func open(
        path: String,
        mode rawMode: String,
        virtualFileSystem: LuaVirtualFileSystem? = nil
    ) throws -> LuaFile {
        let mode = rawMode.replacingOccurrences(of: "b", with: "")
        guard ["r", "w", "a", "r+", "w+", "a+"].contains(mode) else {
            throw LuaFileOperationError.invalidFileMode
        }
        let readable = mode.hasPrefix("r") || mode.contains("+")
        let writable = mode.hasPrefix("w") || mode.hasPrefix("a") || mode.contains("+")
        let appendMode = mode.hasPrefix("a")

        if let virtualFileSystem {
            let exists = virtualFileSystem.fileExists(at: path)
            if mode.hasPrefix("r"), !exists {
                throw LuaVirtualFileSystemError.fileNotFound(path)
            }
            var bytes = exists ? Array(try virtualFileSystem.readFile(at: path)) : []
            if mode.hasPrefix("w") { bytes.removeAll() }
            if mode.hasPrefix("w") || mode.hasPrefix("a") {
                try virtualFileSystem.writeFile(Data(bytes), at: path)
            }
            let file = LuaFile(
                virtualFileSystem: virtualFileSystem,
                path: path,
                bytes: bytes,
                offset: appendMode ? bytes.count : 0,
                readable: readable,
                writable: writable,
                appendMode: appendMode
            )
            // Regular C stdio streams are buffered by default. Besides matching
            // Lua 5.1, this prevents a VFS-backed write from copying the entire
            // file after every small io.write argument.
            try file.setBuffer(mode: "full", size: nil)
            return file
        }

        let fm = FileManager.default
        if mode.contains("w") {
            _ = fm.createFile(atPath: path, contents: Data())
        } else if mode.contains("a"), !fm.fileExists(atPath: path) {
            _ = fm.createFile(atPath: path, contents: Data())
        }
        let url = URL(fileURLWithPath: path)
        let handle = writable ? try FileHandle(forUpdating: url) : try FileHandle(forReadingFrom: url)
        if mode.contains("w") { try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0) }
        if mode.contains("a") { try handle.seekToEnd() }
        let file = LuaFile(
            handle: handle,
            hostPath: path,
            readable: readable,
            writable: writable,
            appendMode: appendMode
        )
        if writable {
            try file.setBuffer(mode: "full", size: nil)
        } else {
            // Foundation's Windows FileHandle can retain an EOF view even
            // after another handle flushes the same file. Read through a
            // path-refreshed snapshot so seek()+read observes that flush,
            // matching C stdio and the Lua 5.1 files.lua contract.
            try file.activateHostBufferIfNeeded()
        }
        return file
    }

    func close() throws {
        guard !closed else { throw LuaFileOperationError.closed }
        try flush()
        if let handle { try handle.close() }
        closed = true
    }

    func flush() throws {
        try ensureOpen()
        if let virtualFileSystem, let virtualPath, writable, virtualDirty {
            try virtualFileSystem.writeFile(Data(virtualBytes), at: virtualPath)
            virtualDirty = false
        } else if hostBufferingActive, let handle, writable, virtualDirty {
            let position = UInt64(max(0, virtualOffset))
            try handle.seek(toOffset: 0)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(virtualBytes))
            try handle.seek(toOffset: position)
            try handle.synchronize()
            virtualDirty = false
        } else if let handle, writable {
            try handle.synchronize()
        }
    }

    func write(_ bytes: [UInt8]) throws {
        try validateWritable()
        if usesMemoryBuffer {
            try refreshVirtualBytesIfClean()
            if appendMode { virtualOffset = virtualBytes.count }
            if virtualOffset > virtualBytes.count {
                virtualBytes += Array(repeating: 0, count: virtualOffset - virtualBytes.count)
            }
            let overwriteCount = min(bytes.count, virtualBytes.count - virtualOffset)
            if overwriteCount > 0 {
                virtualBytes.replaceSubrange(
                    virtualOffset..<(virtualOffset + overwriteCount),
                    with: bytes.prefix(overwriteCount)
                )
            }
            if overwriteCount < bytes.count {
                virtualBytes.append(contentsOf: bytes.dropFirst(overwriteCount))
            }
            virtualOffset += bytes.count
            virtualDirty = true
            switch bufferMode {
            case .none:
                try flush()
            case .line where bytes.contains(10):
                try flush()
            case .line, .full:
                break
            }
        } else if let handle {
            if appendMode { try handle.seekToEnd() }
            try handle.write(contentsOf: Data(bytes))
        }
    }

    func validateWritable() throws {
        try ensureOpen()
        guard writable else { throw LuaFileOperationError.notWritable }
    }

    func read(count: Int) throws -> [UInt8]? {
        try ensureOpen()
        guard readable else { throw LuaFileOperationError.notReadable }
        guard count >= 0 else { throw LuaFileOperationError.invalidReadCount }
        try refreshVirtualBytesIfClean()
        if count == 0 { return try isAtEndOfFile() ? nil : [] }
        var result: [UInt8] = []
        while !pushback.isEmpty && result.count < count { result.append(pushback.removeFirst()) }
        if result.count < count {
            if usesMemoryBuffer {
                let amount = min(count - result.count, virtualBytes.count - virtualOffset)
                if amount > 0 {
                    result += virtualBytes[virtualOffset..<(virtualOffset + amount)]
                    virtualOffset += amount
                }
            } else if let handle, let data = try handle.read(upToCount: count - result.count), !data.isEmpty {
                result += data
            }
        }
        return result.isEmpty ? nil : result
    }

    func readAll() throws -> [UInt8] {
        try ensureOpen()
        guard readable else { throw LuaFileOperationError.notReadable }
        try refreshVirtualBytesIfClean()
        var result = pushback; pushback.removeAll()
        if usesMemoryBuffer {
            if virtualOffset < virtualBytes.count { result += virtualBytes[virtualOffset...] }
            virtualOffset = virtualBytes.count
        } else if let handle, let data = try handle.readToEnd() {
            result += data
        }
        return result
    }

    func readLine() throws -> [UInt8]? {
        var bytes: [UInt8] = []
        var consumed = false
        while let next = try read(count: 1)?.first {
            consumed = true
            if next == 10 { break }
            bytes.append(next)
        }
        return consumed ? bytes : nil
    }

    func readNumber() throws -> Double? {
        try ensureOpen()
        guard readable else { throw LuaFileOperationError.notReadable }

        // Lua's *n reader skips leading whitespace, consumes one numeric token,
        // and leaves the first non-number byte for the next read.
        var candidate: [UInt8] = []
        var terminator: UInt8?
        let potentialNumberBytes = Set("+-.0123456789eExXaAbBcCdDeEfF".utf8)

        while let byte = try read(count: 1)?.first {
            if candidate.isEmpty && [9, 10, 11, 12, 13, 32].contains(byte) { continue }
            guard potentialNumberBytes.contains(byte) else {
                terminator = byte
                break
            }
            candidate.append(byte)
        }

        for prefixLength in stride(from: candidate.count, through: 1, by: -1) {
            let prefix = Array(candidate.prefix(prefixLength))
            if let value = Self.parseNumber(prefix) {
                var unread = Array(candidate.dropFirst(prefixLength))
                if let terminator { unread.append(terminator) }
                pushback.insert(contentsOf: unread, at: 0)
                return value
            }
        }

        var unread = candidate
        if let terminator { unread.append(terminator) }
        pushback.insert(contentsOf: unread, at: 0)
        return nil
    }

    func seek(whence: String, offset: Int64) throws -> UInt64 {
        try ensureOpen()
        if virtualDirty { try flush() }
        try refreshVirtualBytesIfClean()
        let base: Int64
        switch whence {
        case "set": base = 0
        case "cur":
            let physical = usesMemoryBuffer ? Int64(virtualOffset) : Int64(try handle?.offset() ?? 0)
            base = physical - Int64(pushback.count)
        case "end":
            base = usesMemoryBuffer ? Int64(virtualBytes.count) : Int64(try handle?.seekToEnd() ?? 0)
        default: throw LuaFileOperationError.invalidSeekOption(whence)
        }
        let target = base + offset
        guard target >= 0 else { throw LuaFileOperationError.negativeSeek }
        pushback.removeAll()
        if usesMemoryBuffer { virtualOffset = Int(target) }
        else { try handle?.seek(toOffset: UInt64(target)) }
        return UInt64(target)
    }

    func setBuffer(mode: String, size: Int?) throws {
        try ensureOpen()
        if let size, size <= 0 { throw LuaFileOperationError.invalidReadCount }
        if virtualDirty { try flush() }
        switch mode {
        case "no":
            bufferMode = .none
            if hostBufferingActive {
                try handle?.seek(toOffset: UInt64(max(0, virtualOffset)))
                hostBufferingActive = false
            }
        case "full":
            bufferMode = .full
            try activateHostBufferIfNeeded()
        case "line":
            bufferMode = .line
            try activateHostBufferIfNeeded()
        default: throw LuaError.runtime("invalid option '\(mode)' to 'setvbuf'")
        }
    }

    private var usesMemoryBuffer: Bool {
        virtualFileSystem != nil || hostBufferingActive
    }

    private func activateHostBufferIfNeeded() throws {
        guard virtualFileSystem == nil, !hostBufferingActive, let handle else { return }
        let current = try handle.offset()
        try handle.seek(toOffset: 0)
        virtualBytes = Array(try handle.readToEnd() ?? Data())
        virtualOffset = Int(current)
        try handle.seek(toOffset: current)
        hostBufferingActive = true
    }

    private func refreshVirtualBytesIfClean() throws {
        guard !virtualDirty else { return }
        if let virtualFileSystem, let virtualPath {
            virtualBytes = Array(try virtualFileSystem.readFile(at: virtualPath))
        } else if hostBufferingActive, !writable, let hostPath {
            virtualBytes = Array(try Data(contentsOf: URL(fileURLWithPath: hostPath)))
        }
    }

    private func isAtEndOfFile() throws -> Bool {
        if !pushback.isEmpty { return false }
        if usesMemoryBuffer { return virtualOffset >= virtualBytes.count }
        guard let handle else { return true }
        let current = try handle.offset()
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: current)
        return current >= end
    }

    private static func parseNumber(_ bytes: [UInt8]) -> Double? {
        var text = String(decoding: bytes, as: UTF8.self)
        var sign = 1.0
        if text.first == "-" {
            sign = -1
            text.removeFirst()
        } else if text.first == "+" {
            text.removeFirst()
        }
        if text.lowercased().hasPrefix("0x") {
            let digits = String(text.dropFirst(2))
            guard !digits.isEmpty, let value = UInt64(digits, radix: 16) else { return nil }
            return sign * Double(value)
        }
        return Double(String(decoding: bytes, as: UTF8.self))
    }

    private func ensureOpen() throws {
        if closed { throw LuaFileOperationError.closed }
    }
}

private extension LuaValue {
    static func == (lhs: LuaValue, rhs: Bool) -> Bool {
        if case let .boolean(value) = lhs { return value == rhs }
        return false
    }
}
