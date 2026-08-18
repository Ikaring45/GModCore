import SwiftUI

public struct GModMainView: View {

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            Text("GMod iPad")
                .font(.largeTitle)
                .bold()

            Text("GModApp package loaded")
                .monospaced()
        }
        .padding()
    }
}
