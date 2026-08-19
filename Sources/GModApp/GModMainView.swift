import SwiftUI
import GModEngine
import GModMetal

public struct GModMainView: View {
    @State private var stats = "Starting ARM engine..."
    @State private var luaLog = "Starting Lua 5.1 comprehensive runtime..."

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Text("GMod iPad")
                .font(.largeTitle)
                .bold()

            ScrollView {
                Text(luaLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 260)

            Text(stats)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            GModMetalView(stats: $stats)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding()
        .onAppear {
            luaLog = GMLuaRuntime.lua51ComprehensiveSmokeTest()
        }
    }
}
