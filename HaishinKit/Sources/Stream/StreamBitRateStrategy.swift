import Foundation

/// A type with a network bitrate strategy representation.
public protocol StreamBitRateStrategy: Sendable {
    /// The mamimum video bitRate.
    var mamimumVideoBitRate: Int { get }
    /// The mamimum audio bitRate.
    var mamimumAudioBitRate: Int { get }

    /// Adjust a bitRate.
    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async
}

/// An actor provides an algorithm that focuses on video bitrate control.
public final actor StreamVideoAdaptiveBitRateStrategy: StreamBitRateStrategy {
    /// The status counts threshold for restoring the status
    public static let statusCountsThreshold: Int = 15

    public let mamimumVideoBitRate: Int
    public let mamimumAudioBitRate: Int = 0
    private var sufficientBWCounts: Int = 0
    private var zeroBytesOutPerSecondCounts: Int = 0
    private var lastBitRateAdjustment: Date = Date(timeIntervalSince1970: 0)

    /// Creates a new instance.
    public init(mamimumVideoBitrate: Int) {
        self.mamimumVideoBitRate = mamimumVideoBitrate
    }

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status:
            var videoSettings = await stream.videoSettings
            if videoSettings.bitRate == mamimumVideoBitRate {
                return
            }
            if Self.statusCountsThreshold <= sufficientBWCounts {
                let incremental = mamimumVideoBitRate / 10
                videoSettings.bitRate = min(videoSettings.bitRate + incremental, mamimumVideoBitRate)
                try? await stream.setVideoSettings(videoSettings)
                sufficientBWCounts = 0
            } else {
                sufficientBWCounts += 1
            }
        case .publishInsufficientBWOccured(let report):
            sufficientBWCounts = 0
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings
            
            // Don't adjust too frequently - wait at least 2 seconds between adjustments
            guard Date().timeIntervalSince(lastBitRateAdjustment) > 2.0 else {
                return
            }
            lastBitRateAdjustment = Date()
            
            if 0 < report.currentBytesOutPerSecond {
                // Reduce bitrate gradually (10% reduction) instead of dropping frames
                let currentBitrate = Int(report.currentBytesOutPerSecond * 8)
                let audioBitrate = audioSettings.bitRate
                let videoBitrate = videoSettings.bitRate
                
                // Only reduce if above minimum
                if videoBitrate > mamimumVideoBitRate / 4 {
                    let reduction = videoBitrate / 10  // 10% reduction
                    videoSettings.bitRate = max(
                        videoBitrate - reduction,
                        max(currentBitrate - audioBitrate, mamimumVideoBitRate / 4)
                    )
                }
                
                // Keep frame rate at 60fps, reduce quality
                videoSettings.frameInterval = 0.0
                sufficientBWCounts = 0
                zeroBytesOutPerSecondCounts = 0
            } else {
                // Only reduce FPS if bandwidth completely unavailable (after 5+ seconds)
                if zeroBytesOutPerSecondCounts > 5 {
                    // Gradual FPS reduction: 60 → 48 → 36 → 24fps
                    let currentFPS = 1.0 / max(0.001, 1.0 - videoSettings.frameInterval)
                    let newFPS = max(24.0, currentFPS - 12.0)
                    videoSettings.frameInterval = 1.0 - (1.0 / newFPS)
                }
                try? await stream.setVideoSettings(videoSettings)
                zeroBytesOutPerSecondCounts += 1
            }
        case .reset:
            var videoSettings = await stream.videoSettings
            zeroBytesOutPerSecondCounts = 0
            videoSettings.bitRate = mamimumVideoBitRate
            videoSettings.frameInterval = 0.0
            try? await stream.setVideoSettings(videoSettings)
        }
    }
}
