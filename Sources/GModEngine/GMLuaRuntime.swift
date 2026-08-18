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

    public static func phase2SmokeTest()
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
                local t = {
                    value = 42
                }

                function t:GetValue()
                    return self.value
                end

                print(t:GetValue())

                local function makeCounter()
                    local n = 0

                    return function()
                        n = n + 1
                        return n
                    end
                end

                local counter = makeCounter()

                print(counter())
                print(counter())
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
