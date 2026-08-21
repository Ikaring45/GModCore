import Foundation
import GModEngine

/// Bounded Studio-file access over the mounted Playgrounds content pack.
///
/// `SourceStudioModelAssetLoader` supplies a per-file/remaining-total cap for
/// every read. The content-pack source checks the ZIP/VPK entry size before it
/// constructs `Data`, so an oversized model companion never becomes an
/// unbounded allocation on iPad.
extension GModContentPackAssetSource: SourceStudioBoundedAssetReading {
    public func read(
        path: String,
        pathID: String?,
        maximumBytes: Int
    ) -> SourceStudioBoundedAssetReadOutcome {
        guard maximumBytes > 0 else {
            return .failed("Studio asset read requires a positive byte cap")
        }
        if let pathID,
           pathID.caseInsensitiveCompare("GAME") != .orderedSame {
            return .failed("unsupported Studio asset path ID: \(pathID)")
        }

        do {
            guard let data = try data(
                for: path,
                maximumByteCount: UInt64(maximumBytes)
            ) else {
                return .missing
            }
            return .data(data)
        } catch let error as GModContentPackAssetSourceError {
            switch error {
            case let .assetTooLarge(_, byteCount, _):
                return .exceeded(actual: Int(clamping: byteCount))
            }
        } catch {
            return .failed(String(describing: error))
        }
    }
}
