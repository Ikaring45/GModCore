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
        realm: GMLuaRealm,
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

    public static func phase1SmokeTest()
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
                print("Hello from SERVER Lua")

                local x = 20
                local y = 22

                print(x + y)
                print(2 + 3 * 4)
                """
            )

        } catch {

            lines.append(
                "[SERVER][Lua][ERROR] \(error)"
            )
        }

        return lines.joined(
            separator: "\n"
        )
    }
}
