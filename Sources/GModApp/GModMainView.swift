import SwiftUI
import GModCore

public struct GModMainView: View {

    @State private var status = "Ready to test GModCore"

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {

            Text("GMod iPad")
                .font(.largeTitle)
                .bold()

            Text(status)
                .multilineTextAlignment(.center)
                .monospaced()

            Button("Test Native Core") {
                testNativeCore()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func testNativeCore() {

        guard let engine = gm_create() else {
            status = "gm_create() failed"
            return
        }

        gm_boot(engine)

        let abi = gm_abi_version()
        let result = gm_test_add(20, 22)

        let version: String

        if let ptr = gm_version() {
            version = String(cString: ptr)
        } else {
            version = "Unknown"
        }

        gm_destroy(engine)

        status = """
        \(version)
        ABI: \(abi)
        C++ result: \(result)
        """

        print("[GModApp] \(version)")
        print("[GModApp] ABI:", abi)
        print("[GModApp] C++ result:", result)
    }
}
