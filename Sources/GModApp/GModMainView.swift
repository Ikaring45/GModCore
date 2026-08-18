import SwiftUI
import GModMetal

public struct GModMainView: View {

    @State private var stats =
        "Starting ARM engine..."

    public init() {}

    public var body: some View {

        VStack(
            spacing: 16
        ) {

            Text("GMod iPad")
                .font(.largeTitle)
                .bold()

            Text(stats)
                .font(
                    .system(
                        .body,
                        design:
                            .monospaced
                    )
                )
                .multilineTextAlignment(
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
                height: 500
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 16
                )
            )
        }
        .padding()
    }
}
