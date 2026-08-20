import Combine
import Foundation
import GModGameAssets
import GModGameSession

@MainActor
final class GModPlaygroundContentModel: ObservableObject {
    enum State {
        case loading
        case missing
        case ready(GarrysPADContentPack, backgroundJPEG: Data, logoPNG: Data?)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var assetSource: GModContentPackAssetSource?
    private let runtimeFactory: GModAppRuntimeFactory

    init(
        runtimeFactory: GModAppRuntimeFactory,
        bundle: Bundle = .main
    ) {
        self.runtimeFactory = runtimeFactory
        reload(bundle: bundle)
    }

    func reload(bundle: Bundle = .main) {
        state = .loading
        assetSource = nil
        let resourceRootURL = bundle.resourceURL
        Task { [weak self] in
            do {
                let runtimeFactory = self.runtimeFactory
                let result = try await Task.detached(priority: .userInitiated) {
                    guard let resourceRootURL,
                          let pack = try GarrysPADContentPack.discover(
                              resourceRootURL: resourceRootURL
                          ) else {
                        return Optional<(
                            GarrysPADContentPack,
                            Data,
                            Data?,
                            GModContentPackAssetSource
                        )>.none
                    }
                    let background = try pack.data(
                        for: "garrysmod/html/img/bg.jpg",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    let logo = try? pack.data(
                        for: "garrysmod/html/img/gmod_logo_brave.png",
                        maximumByteCount: 4 * 1_024 * 1_024
                    )
                    let source = try runtimeFactory.mountContentPack(pack)
                    return (pack, background, logo, source)
                }.value
                guard let self else { return }
                if let result {
                    assetSource = result.3
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
