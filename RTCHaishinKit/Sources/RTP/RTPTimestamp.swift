import CoreMedia
import Foundation

struct RTPTimestamp {
    static let startedAt: Double = -1

    private let rate: Double
    private var startedAt = Self.startedAt

    init(_ rate: Double) {
        self.rate = rate
    }

    func convert(_ timestamp: UInt32) -> CMTime {
        return CMTime(value: CMTimeValue(timestamp), timescale: CMTimeScale(rate))
    }

    mutating func convert(_ time: CMTime) -> UInt32 {
        let seconds = time.seconds
        if startedAt == Self.startedAt {
            startedAt = seconds
        }
        let timestamp = UInt64((seconds - startedAt) * rate)
        return UInt32(timestamp & 0xFFFFFFFF)
    }

    mutating func reset() {
        startedAt = Self.startedAt
    }
}
