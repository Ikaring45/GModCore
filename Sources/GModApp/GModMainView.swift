import SwiftUI
import GModEngine
import GModMetal

public struct GModMainView: View {

    @State private var stats =
        "Starting ARM engine..."

    @State private var luaLog =
        "Starting Lua 5.1 bootstrap..."

    public init() {}

    public var body: some View {

        VStack(
            spacing: 16
        ) {

            Text("GMod iPad")
                .font(.largeTitle)
                .bold()

            Text(luaLog)
                .font(
                    .system(
                        .body,
                        design:
                            .monospaced
                    )
                )
                .frame(
                    maxWidth:
                        .infinity,
                    alignment:
                        .leading
                )

            Text(stats)
                .font(
                    .system(
                        .body,
                        design:
                            .monospaced
                    )
                )
                .frame(
                    maxWidth:
                        .infinity,
                    alignment:
                        .leading
                )

            GModMetalView(
                stats: $stats
            )
            .frame(
                maxWidth:
                    .infinity
            )
            .frame(
                height: 420
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 16
                )
            )
        }
        .padding()
        .onAppear {

            luaLog =
                GMLuaRuntime
                    .phase1SmokeTest()
        }
    }
}
