import SwiftUI
import GModApp

/// Replace the new App Playground's generated ContentView with this file.
/// On first launch GModMainView asks for the content ZIP from Files/iCloud
/// Drive and keeps a security-scoped bookmark for later launches.
struct ContentView: View {
    var body: some View {
        GModMainView()
    }
}
