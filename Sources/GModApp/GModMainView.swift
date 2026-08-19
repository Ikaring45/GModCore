import SwiftUI
import GModMetal

public struct GModMainView: View {
    @State private var stats = "Starting ARM engine..."
    @State private var conformanceText = "Lua 5.1 official basic suite is ready.\nTap Run Official Lua 5.1 Tests."
    @State private var isRunning = false
    @State private var resultLabel = "READY"

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GMod iPad")
                        .font(.title.bold())
                    Text("Lua 5.1 Official Conformance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(resultLabel)
                    .font(.system(.caption, design: .monospaced).bold())

                Button(isRunning ? "Running…" : "Run Official Lua 5.1 Tests") {
                    runOfficialTests()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(conformanceText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(height: 300)
            .background(.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(stats)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            GModMetalView(stats: $stats)
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding()
    }

    private func runOfficialTests() {
        guard !isRunning else { return }

        isRunning = true
        resultLabel = "RUNNING"
        conformanceText = "Running official Lua 5.1 basic test suite…\nMode: _U=true\n\nThis can take a while."

        Task {
            let report = await Lua51ConformanceRunner.runBasicSuite()
            conformanceText = report.fullText
            resultLabel = report.passed ? "PASS" : "FAIL"
            isRunning = false
        }
    }
}
