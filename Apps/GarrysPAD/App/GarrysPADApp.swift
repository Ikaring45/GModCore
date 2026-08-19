import GModApp
import SwiftUI

@main
struct GarrysPADHostApp: App {
    static let rootAccessibilityIdentifier = "garrys-pad-root"

    var body: some Scene {
        WindowGroup {
            GModMainView()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(Self.rootAccessibilityIdentifier)
                .accessibilityLabel("Garry's PAD")
        }
    }
}
