import HaishinKit
import SwiftUI

enum ViewType: String, CaseIterable, Identifiable {
    case metal
    case pip

    var id: Self { self }
}

@MainActor
final class PreferenceViewModel: ObservableObject {
    @Published var showPublishSheet: Bool = false

    var uri = Preference.default.uri
    var streamName = Preference.default.streamName

    private(set) var bitRateModes: [VideoCodecSettings.BitRateMode] = [.average]

    // MARK: - AudioCodecSettings.
    @Published var audioFormat: AudioCodecSettings.Format = .aac

    // MARK: - VideoCodecSettings.
    @Published var bitRateMode: VideoCodecSettings.BitRateMode = .average
    var isLowLatencyRateControlEnabled: Bool = false

    // MARK: - Others
    @Published var viewType: ViewType = .metal
    var isGPURendererEnabled: Bool = true

    init() {
        if #available(iOS 16.0, *) {
            bitRateModes.append(.constant)
        }
    }

    func makeVideoCodecSettings(_ settings: VideoCodecSettings) -> VideoCodecSettings {
        // Use Full HD 60fps balanced preset (3.5 Mbps) for best quality
        // Can change to fullHD60fps (5 Mbps) for higher quality on powerful devices
        // Or fullHD60fpsPerformance (2.5 Mbps) for lower bitrate
        var newSettings = VideoCodecSettings.fullHD60fpsBalanced
        newSettings.bitRateMode = bitRateMode
        newSettings.isLowLatencyRateControlEnabled = isLowLatencyRateControlEnabled
        return newSettings
    }

    func makeAudioCodecSettings(_ settings: AudioCodecSettings) -> AudioCodecSettings {
        var newSettings = settings
        newSettings.format = audioFormat
        return newSettings
    }

    func makeURL() -> URL? {
        if uri.contains("rtmp://") {
            return URL(string: uri + "/" + streamName)
        }
        return URL(string: uri)
    }
}
