import Combine
import Foundation
import GModGameAssets

@MainActor
final class GModPlaygroundContentModel: ObservableObject {
    enum State {
        case loading
        case missing
        case ready(GarrysPADContentPack, backgroundJPEG: Data, logoPNG: Data?)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

    init(bundle: Bundle = .main) {
        reload(bundle: bundle)
    }

    func reload(bundle: Bundle = .main) {
        state = .loading
        let resourceRootURL = bundle.resourceURL
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    guard let resourceRootURL,
                          let pack = try GarrysPADContentPack.discover(
                              resourceRootURL: resourceRootURL
                          ) else {
                        return Optional<(GarrysPADContentPack, Data, Data?)>.none
                    }
                    let background = try pack.data(
                        for: "garrysmod/html/img/bg.jpg",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    let logo = try? pack.data(
                        for: "garrysmod/html/img/gmod_logo_brave.png",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    return (pack, background, logo)
                }.value
                guard let self else { return }
                if let result {
                    state = .ready(
                        result.0,
                        backgroundJPEG: result.1,
                        logoPNG: result.2
                    )
                } else {
                    state = .missing
                }
            } catch {
                guard let self else { return }
                state = .failed(String(describing: error))
            }
        }
    }
}
