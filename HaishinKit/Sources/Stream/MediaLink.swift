import CoreMedia
import Foundation

final actor MediaLink {
    static let capacity = 300  // 🎯 OPTIMIZATION: Increased from 90 frames (1.5s) to 300 frames (5s) for smoother playback with better jitter tolerance
    static let duration: TimeInterval = 0.0

    var dequeue: AsyncStream<CMSampleBuffer> {
        AsyncStream { continutation in
            self.continutation = continutation
        }
    }
    private(set) var isRunning = false
    private var storage: TypedBlockQueue<CMSampleBuffer>?
    private var continutation: AsyncStream<CMSampleBuffer>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var duration: TimeInterval = MediaLink.duration
    private var presentationTimeStampOrigin: CMTime = .invalid
    private lazy var displayLink = DisplayLinkChoreographer()
    private weak var audioPlayer: AudioPlayerNode?

    init() {
        do {
            storage = try .init(capacity: Self.capacity, handlers: .outputPTSSortedSampleBuffers)
        } catch {
            logger.error(error)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        if presentationTimeStampOrigin == .invalid {
            presentationTimeStampOrigin = sampleBuffer.presentationTimeStamp
        }
        do {
            try storage?.enqueue(sampleBuffer)
        } catch {
            logger.error(error)
        }
    }

    func setAudioPlayer(_ audioPlayer: AudioPlayerNode?) {
        self.audioPlayer = audioPlayer
    }

    private func getCurrentTime(_ timestamp: TimeInterval) async -> TimeInterval {
        defer {
            duration += timestamp
        }
        return await audioPlayer?.currentTime ?? duration
    }
}

extension MediaLink: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        duration = 0.0
        displayLink.startRunning()
        Task {
            for await currentTime in displayLink.updateFrames {
                guard let storage else {
                    continue
                }
                let currentTime = await getCurrentTime(currentTime.targetTimestamp - currentTime.timestamp)
                var frameCount = 0
                // 🎯 OPTIMIZATION: Smart frame skipping - skip old frames to prevent catch-up stutter
                while !storage.isEmpty {
                    guard let first = storage.head else {
                        break
                    }
                    let frameTimestamp = first.presentationTimeStamp.seconds - presentationTimeStampOrigin.seconds
                    let timeDelta = frameTimestamp - currentTime
                    
                    // If frame is > 50ms in past, skip it (old frame)
                    if timeDelta < -0.050 {
                        _ = storage.dequeue()
                        logger.debug("⏭️  skipped old frame: \(String(format: "%.1f", timeDelta * 1000))ms behind")
                        continue
                    }
                    
                    // If frame is ready (within ±50ms), yield it
                    if timeDelta <= 0.050 {
                        continutation?.yield(first)
                        frameCount += 1
                        _ = storage.dequeue()
                    } else {
                        // Frame is in future, wait for it
                        if 2 < frameCount {
                            logger.info("🎬 rendered \(frameCount) frames to catch up")
                        }
                        break
                    }
                }
            }
        }
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        continutation = nil
        displayLink.stopRunning()
        presentationTimeStampOrigin = .invalid
        try? storage?.reset()
        isRunning = false
    }
}
