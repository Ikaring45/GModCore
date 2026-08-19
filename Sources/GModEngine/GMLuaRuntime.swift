import GModLua

public enum GMLuaRealm: String {
    case server = "SERVER"
    case client = "CLIENT"
    case menu = "MENU"
}

public final class GMLuaRuntime {
    public let realm: GMLuaRealm
    private let state: LuaState

    public init(
        realm: GMLuaRealm,
        logger: @escaping (String) -> Void,
        fileLoader: ((String) throws -> String)? = nil
    ) {
        self.realm = realm
        self.state = LuaState(
            output: { message in logger("[\(realm.rawValue)][Lua] \(message)") },
            fileLoader: fileLoader
        )
    }

    public func execute(_ source: String, sourceName: String = "=(gmod)") throws {
        try state.execute(source, sourceName: sourceName)
    }

    /// Broad runtime smoke test. This is intentionally much wider than the old
    /// phase-by-phase tests and exercises the Lua 5.1 runtime as one subsystem.
    public static func lua51ComprehensiveSmokeTest() -> String {
        var lines: [String] = []
        let files: [String: String] = [
            "gmod_test_module.lua": "return { value = 77 }"
        ]

        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { lines.append($0) },
            fileLoader: { path in
                if let source = files[path] { return source }
                throw LuaError.runtime("file not found: \(path)")
            }
        )

        do {
            try runtime.execute(
                #"""
                print("Lua", _VERSION)

                -- arithmetic / control flow / GLua aliases
                local total = 0
                for i = 1, 10 do
                    if i % 2 == 0 && !false then
                        total = total + i
                    end
                end
                print("control", total, 2 + 3 * 4, 2^3^2)

                local i, acc = 0, 0
                while i < 5 do
                    i = i + 1
                    if i == 3 then continue end
                    acc = acc + i
                end
                repeat acc = acc - 1 until acc <= 10
                print("loops", acc)

                -- multiple return / vararg / pcall
                local function vararg(...)
                    return select("#", ...), ...
                end
                local ok, n, a, b, c = pcall(vararg, 10, 20, 30)
                print("vararg", ok, n, a, b, c)

                -- table / closure / method
                local object = { value = 40 }
                function object:Add(x) return self.value + x end
                local function counter()
                    local n = 0
                    return function() n = n + 1; return n end
                end
                local nextCount = counter()
                print("object", object:Add(2), nextCount(), nextCount())

                -- metatables
                local mt = {}
                mt.__add = function(a,b) return a.v + b.v end
                mt.__lt = function(a,b) return a.v < b.v end
                mt.__concat = function(a,b) return a.v .. b.v end
                mt.__call = function(a,x) return a.v + x end
                mt.__tostring = function(a) return "OBJ:" .. a.v end
                local ma = setmetatable({v=3}, mt)
                local mb = setmetatable({v=4}, mt)
                print("meta", ma+mb, ma<mb, ma..mb, ma(9), tostring(ma))

                -- environments
                local function envtest() return X end
                local env = { X = 55 }
                setmetatable(env, { __index = _G })
                setfenv(envtest, env)
                print("env", envtest(), getfenv(envtest) == env)

                -- load / dump round trip in this runtime
                local loaded = assert(loadstring("return 20+22"))
                print("load", loaded())
                local function twice(x) return x*2 end
                local dumped = string.dump(twice)
                print("dump", assert(loadstring(dumped))(21))

                -- coroutine with nested yield
                local function foo(a) return coroutine.yield(2*a) end
                local co = coroutine.create(function(a,b)
                    local r = foo(a+1)
                    local r2,s2 = coroutine.yield(a+b, a-b)
                    return b, "end", r, r2, s2
                end)
                print("co1", coroutine.resume(co, 1, 10))
                print("co2", coroutine.resume(co, "r"))
                print("co3", coroutine.resume(co, "x", "y"))
                print("co4", coroutine.resume(co))

                -- Lua patterns
                local s = "abc 123 def 456"
                print("pattern-find", string.find(s, "%d+"))
                print("pattern-match", string.match(s, "(%a+)%s+(%d+)"))
                local g = string.gmatch("a1 b22", "(%a)(%d+)")
                print("pattern-g1", g())
                print("pattern-g2", g())
                print("pattern-sub", string.gsub("hello 123", "%d", "X"))
                print("pattern-bal", string.match("x(a(b)c)y", "%b()"))

                -- package / require
                package.path = "?.lua"
                local mod = require("gmod_test_module")
                print("require", mod.value, require("gmod_test_module") == mod)

                package.preload["inline_module"] = function(name)
                    module(name, package.seeall)
                    VALUE = 88
                    TYPE_OF_PRINT = type(print)
                end
                local inline = require("inline_module")
                print("module", inline.VALUE, inline.TYPE_OF_PRINT)

                -- standard libraries
                print("math", math.floor(3.9), math.fmod(7,4), math.max(2,9,4))
                local t={3,1,2}; table.sort(t)
                print("table", table.concat(t,","), table.maxn(t))
                print("string", ("AbC"):lower(), string.reverse("abc"), string.format("%04d %.1f",7,2.25))
                print("bytes", string.byte(string.char(65,0,66),1,3))

                -- userdata proxy / debug surface
                local u = newproxy(true)
                print("userdata", type(u), type(getmetatable(u)))
                local info = debug.getinfo(function() return 1 end)
                print("debug", type(info), type(debug.traceback()))

                -- protected errors
                local ok2, err2 = xpcall(function() error("boom") end, function(e) return "handled:" .. e end)
                print("error", ok2, err2)

                // GLua comment syntax is deliberately accepted by GModLua.
                /* GLua block comments are accepted too. */
                """#,
                sourceName: "@lua51-comprehensive-smoke.lua"
            )
        } catch {
            lines.append("[SERVER][Lua][FATAL] \(error)")
        }

        return lines.joined(separator: "\n")
    }
}
