import GModLua

public enum GMLuaRealm:
    String
{
    case server = "SERVER"
    case client = "CLIENT"
    case menu = "MENU"
}

public final class GMLuaRuntime {

    public let realm:
        GMLuaRealm

    private let state:
        LuaState

    public init(
        realm:
            GMLuaRealm,

        logger:
            @escaping (String) -> Void
    ) {

        self.realm =
            realm

        self.state =
            LuaState {
                message in

                logger(
                    "[\(realm.rawValue)][Lua] \(message)"
                )
            }
    }

    public func execute(
        _ source: String
    ) throws {

        try state.execute(
            source
        )
    }

    public static func phase3SmokeTest()
        -> String
    {

        var lines:
            [String] = []

        let runtime =
            GMLuaRuntime(
                realm:
                    .server
            ) {

                lines.append(
                    $0
                )
            }

        do {

            try runtime.execute(
                """
                local defaults = {
                    answer = 42
                }

                local object = {}

                setmetatable(
                    object,
                    {
                        __index = defaults
                    }
                )

                print(object.answer)

                local proxy = {}

                setmetatable(
                    proxy,
                    {
                        __index = function(self, key)
                            return 99
                        end,

                        __newindex = function(self, key, value)
                            print("__newindex", key, value)
                            rawset(self, key, value)
                        end
                    }
                )

                print(proxy.missing)

                proxy.bonus = 7

                print(proxy.bonus)

                print(getmetatable(proxy))
                """
            )

        } catch {

            lines.append(
                "[SERVER][Lua][ERROR] \(error)"
            )
        }

        return lines.joined(
            separator:
                "\n"
        )
    }
}
