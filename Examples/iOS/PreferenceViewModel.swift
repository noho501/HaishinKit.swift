import HaishinKit
import SwiftUI

@MainActor
final class PreferenceViewModel: ObservableObject {
    @Published var showIngestSheet: Bool = false

    var uri = Preference.default.uri
    var streamName = Preference.default.streamName

    private(set) var bitRateModes: [VideoCodecSettings.BitRateMode] = [.average]

    // MARK: - VideoSettings.
    @Published var bitRateMode: VideoCodecSettings.BitRateMode = .average
    var isLowLatencyRateControlEnabled: Bool = false

    init() {
        if #available(iOS 16.0, *) {
            bitRateModes.append(.constant)
        }
    }

    func makeVideoCodecSettings(_ settings: VideoCodecSettings) -> VideoCodecSettings {
        var newSettings = settings
        newSettings.bitRateMode = bitRateMode
        newSettings.isLowLatencyRateControlEnabled = isLowLatencyRateControlEnabled
        return newSettings
    }

    func makeURL() -> URL? {
        if uri.contains("rtmp://") {
            return URL(string: uri + "/" + streamName)
        }
        return URL(string: uri)
    }
}
