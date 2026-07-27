import CoreMedia
import os
import QuartzCore

/// Thread-safe diagnostic logger for investigating video stuttering in ``VideoMixerSettings.Mode.offscreen`` mode.
///
/// Enable before starting the mixer:
/// ```swift
/// OffscreenDiagnostics.shared.isEnabled = true
/// await mixer.startRunning()
/// ```
///
/// Every second a compact summary is written to the `Summary` category:
/// ```
/// Display FPS / Camera FPS / Render FPS
/// Average intervals, render times, queue depth, skipped frames, timestamp drift, dropped frames
/// ```
///
/// Per-frame events are written at the `.debug` level to the following `os.Logger` categories
/// under the `com.haishinkit.HaishinKit` subsystem:
/// - `DisplayLink` – CADisplayLink / CVDisplayLink timing
/// - `Camera`      – incoming camera frame enqueueing
/// - `Queue`       – TypedBlockQueue dequeue details
/// - `Renderer`    – GPU render duration and timestamp drift
/// - `MediaMixer`  – full render-loop breakdown
final class OffscreenDiagnostics: @unchecked Sendable {
    // MARK: - Singleton

    static let shared = OffscreenDiagnostics()

    /// Set to `true` to enable per-frame and periodic summary logging.
    var isEnabled = false

    // MARK: - os.Logger instances

    private let displayLinkLog = Logger(subsystem: kHaishinKitIdentifier, category: "DisplayLink")
    private let cameraLog = Logger(subsystem: kHaishinKitIdentifier, category: "Camera")
    private let queueLog = Logger(subsystem: kHaishinKitIdentifier, category: "Queue")
    private let rendererLog = Logger(subsystem: kHaishinKitIdentifier, category: "Renderer")
    private let mediaMixerLog = Logger(subsystem: kHaishinKitIdentifier, category: "MediaMixer")
    private let summaryLog = Logger(subsystem: kHaishinKitIdentifier, category: "Summary")

    // MARK: - Thread safety

    private let lock = NSLock()

    // MARK: - Summary window

    private var summaryWindowStart: Double = 0

    // MARK: - DisplayLink stats

    private var displayFrameCount: Int = 0
    private var lastDisplayTimestamp: Double = 0
    private var displayIntervalSum: Double = 0
    private var droppedRenderFrameCount: Int = 0

    // MARK: - Camera stats

    private var cameraFrameCount: Int = 0
    private var lastCameraPTS: Double = 0
    private var cameraIntervalSum: Double = 0

    // MARK: - GPU render stats

    private var gpuRenderFrameCount: Int = 0
    private var gpuRenderTimeSum: Double = 0
    private var gpuRenderTimeMax: Double = 0

    // MARK: - Queue stats

    private var queueMaxDepth: Int = 0
    private var queueOverflowCount: Int = 0

    // MARK: - Skipped-frames stats

    private var skippedFramesSum: Int = 0
    private var skippedFramesMax: Int = 0
    private var skippedFramesSampleCount: Int = 0

    // MARK: - Timestamp drift stats

    private var driftAbsSum: Double = 0
    private var driftAbsMax: Double = 0
    private var driftSampleCount: Int = 0

    // MARK: - MediaMixer render-loop stats

    private var renderLoopSampleCount: Int = 0
    private var renderLoopTimeSum: Double = 0
    private var renderLoopTimeMax: Double = 0

    private init() {}

    // MARK: - DisplayLink instrumentation

    /// Call once per DisplayLink callback.
    ///
    /// - Parameters:
    ///   - timestamp: `displayLink.timestamp` (seconds since boot).
    ///   - targetTimestamp: `displayLink.targetTimestamp` (seconds since boot).
    func recordDisplayLinkUpdate(timestamp: Double, targetTimestamp: Double) {
        guard isEnabled else { return }

        lock.lock()
        let prevTimestamp = lastDisplayTimestamp
        lastDisplayTimestamp = timestamp
        displayFrameCount += 1
        let delta = prevTimestamp > 0 ? timestamp - prevTimestamp : 0
        if prevTimestamp > 0 {
            displayIntervalSum += delta
        }
        let windowStart = summaryWindowStart
        lock.unlock()

        let expectedInterval = targetTimestamp - timestamp
        let jitter = delta > 0 ? abs(delta - expectedInterval) : 0

        displayLinkLog.debug(
            "[DisplayLink] ts=\(timestamp, format: .fixed(precision: 6)) targetTs=\(targetTimestamp, format: .fixed(precision: 6)) delta=\(delta * 1000, format: .fixed(precision: 2))ms expected=\(expectedInterval * 1000, format: .fixed(precision: 2))ms jitter=\(jitter * 1000, format: .fixed(precision: 2))ms"
        )

        if windowStart == 0 {
            lock.lock()
            summaryWindowStart = timestamp
            lock.unlock()
        } else if timestamp - windowStart >= 1.0 {
            printAndResetSummary(now: timestamp)
        }
    }

    /// Call when `screen.makeSampleBuffer()` returns `nil` (a render frame is dropped).
    func recordDroppedRenderFrame() {
        guard isEnabled else { return }
        lock.lock()
        droppedRenderFrameCount += 1
        lock.unlock()
    }

    // MARK: - Camera enqueue instrumentation

    /// Call from `VideoScreenObject.enqueue()`.
    ///
    /// - Parameters:
    ///   - pts: Incoming sample buffer presentation timestamp (seconds).
    ///   - queueCountBefore: Queue depth before the enqueue attempt.
    ///   - queueCountAfter: Queue depth after the enqueue attempt.
    ///   - didFail: `true` if the enqueue threw an error.
    ///   - wasAlreadyFull: `true` if the queue was at capacity before the enqueue.
    func recordCameraEnqueue(
        pts: Double,
        queueCountBefore: Int,
        queueCountAfter: Int,
        didFail: Bool,
        wasAlreadyFull: Bool
    ) {
        guard isEnabled else { return }

        lock.lock()
        let prevPTS = lastCameraPTS
        lastCameraPTS = pts
        cameraFrameCount += 1
        let delta = prevPTS > 0 ? pts - prevPTS : 0
        if prevPTS > 0 {
            cameraIntervalSum += delta
        }
        if queueCountAfter > queueMaxDepth {
            queueMaxDepth = queueCountAfter
        }
        if wasAlreadyFull {
            queueOverflowCount += 1
        }
        lock.unlock()

        cameraLog.debug(
            "[Camera] pts=\(pts, format: .fixed(precision: 6)) delta=\(delta * 1000, format: .fixed(precision: 2))ms qBefore=\(queueCountBefore) qAfter=\(queueCountAfter) fail=\(didFail) full=\(wasAlreadyFull)"
        )
    }

    // MARK: - Queue dequeue per-frame logging

    /// Log a single frame that was pulled from the queue during `dequeue(_:)`.
    ///
    /// - Parameter pts: The presentation timestamp of the dequeued buffer (seconds).
    func logQueueDequeuedFrame(pts: Double) {
        guard isEnabled else { return }
        queueLog.debug("[Queue] dequeued PTS=\(pts, format: .fixed(precision: 6))")
    }

    /// Call after `dequeue(_:)` returns to log the aggregate outcome.
    ///
    /// - Parameters:
    ///   - renderPTS: The `presentationTimeStamp` passed into `dequeue(_:)` (seconds).
    ///   - headPTSBefore: Queue head PTS at the start of the call (seconds), or `nil` if queue was empty.
    ///   - skippedCount: Number of frames consumed but not returned (overwritten by a later frame).
    ///   - returnedPTS: PTS of the returned buffer, or `nil` if nothing was returned.
    ///   - queueCountAfter: Queue depth after the dequeue operation.
    func recordDequeueComplete(
        renderPTS: Double,
        headPTSBefore: Double?,
        skippedCount: Int,
        returnedPTS: Double?,
        queueCountAfter: Int
    ) {
        guard isEnabled else { return }

        lock.lock()
        if skippedCount > skippedFramesMax {
            skippedFramesMax = skippedCount
        }
        skippedFramesSum += skippedCount
        skippedFramesSampleCount += 1
        lock.unlock()

        let headDesc = headPTSBefore.map { String(format: "%.6f", $0) } ?? "nil"
        let returnedDesc = returnedPTS.map { String(format: "%.6f", $0) } ?? "nil"
        queueLog.debug(
            "[Queue] renderPTS=\(renderPTS, format: .fixed(precision: 6)) headPTS=\(headDesc) skipped=\(skippedCount) returned=\(returnedDesc) qAfter=\(queueCountAfter)"
        )
    }

    // MARK: - makeImage instrumentation

    /// Call from `VideoScreenObject.makeImage(_:)` when a frame is successfully selected.
    ///
    /// - Parameters:
    ///   - rendererPTS: `renderer.presentationTimeStamp` in seconds (host clock domain).
    ///   - convertedPTS: `renderer.presentationTimeStamp` converted to the synchronization clock (seconds).
    ///   - sampleBufferPTS: Presentation timestamp of the selected sample buffer (seconds).
    ///   - frameRate: Current frame rate from `FrameTracker`.
    func recordMakeImage(
        rendererPTS: Double,
        convertedPTS: Double,
        sampleBufferPTS: Double,
        frameRate: Int
    ) {
        guard isEnabled else { return }
        let drift = convertedPTS - sampleBufferPTS
        let absDrift = abs(drift)

        lock.lock()
        if absDrift > driftAbsMax {
            driftAbsMax = absDrift
        }
        driftAbsSum += absDrift
        driftSampleCount += 1
        lock.unlock()

        rendererLog.debug(
            "[Renderer] rendererPTS=\(rendererPTS, format: .fixed(precision: 6)) convertedPTS=\(convertedPTS, format: .fixed(precision: 6)) bufferPTS=\(sampleBufferPTS, format: .fixed(precision: 6)) drift=\(drift * 1000, format: .fixed(precision: 2))ms fps=\(frameRate)"
        )
    }

    // MARK: - GPU render instrumentation

    /// Call from `ScreenRendererByGPU.render()` with wall-clock times measured via `CACurrentMediaTime()`.
    ///
    /// - Parameters:
    ///   - beginTime: `CACurrentMediaTime()` just before `CIContext.render(...)`.
    ///   - endTime: `CACurrentMediaTime()` just after `CIContext.render(...)`.
    func recordGPURender(beginTime: Double, endTime: Double) {
        guard isEnabled else { return }
        let duration = endTime - beginTime

        lock.lock()
        gpuRenderFrameCount += 1
        gpuRenderTimeSum += duration
        if duration > gpuRenderTimeMax {
            gpuRenderTimeMax = duration
        }
        lock.unlock()

        rendererLog.debug(
            "[Renderer] GPU begin=\(beginTime, format: .fixed(precision: 6)) end=\(endTime, format: .fixed(precision: 6)) duration=\(duration * 1000, format: .fixed(precision: 2))ms"
        )
    }

    // MARK: - MediaMixer render loop instrumentation

    /// Call once per DisplayLink tick from the MediaMixer offscreen render loop.
    ///
    /// - Parameters:
    ///   - displayLinkCallbackDuration: Time from DisplayLink fire to start of `makeSampleBuffer` (seconds).
    ///   - makeSampleBufferDuration: Duration of `screen.makeSampleBuffer(_:)` (seconds).
    ///   - outputMixerDuration: Duration of sending the buffer to all outputs (seconds).
    ///   - totalDuration: End-to-end render loop time for this tick (seconds).
    func recordRenderLoop(
        displayLinkCallbackDuration: Double,
        makeSampleBufferDuration: Double,
        outputMixerDuration: Double,
        totalDuration: Double
    ) {
        guard isEnabled else { return }

        lock.lock()
        renderLoopSampleCount += 1
        renderLoopTimeSum += totalDuration
        if totalDuration > renderLoopTimeMax {
            renderLoopTimeMax = totalDuration
        }
        lock.unlock()

        mediaMixerLog.debug(
            "[MediaMixer] dlCallback=\(displayLinkCallbackDuration * 1000, format: .fixed(precision: 2))ms makeSampleBuffer=\(makeSampleBufferDuration * 1000, format: .fixed(precision: 2))ms outputMixer=\(outputMixerDuration * 1000, format: .fixed(precision: 2))ms total=\(totalDuration * 1000, format: .fixed(precision: 2))ms"
        )
    }

    // MARK: - Per-second summary

    private func printAndResetSummary(now: Double) {
        lock.lock()
        // Guard against concurrent summary prints.
        guard now - summaryWindowStart >= 1.0 else {
            lock.unlock()
            return
        }

        let elapsed = now - summaryWindowStart

        // Capture
        let dispCount = displayFrameCount
        let camCount = cameraFrameCount
        let renderCount = gpuRenderFrameCount
        let avgCamInterval = cameraFrameCount > 1 ? cameraIntervalSum / Double(cameraFrameCount - 1) : 0
        let avgDispInterval = displayFrameCount > 1 ? displayIntervalSum / Double(displayFrameCount - 1) : 0
        let avgRenderTime = gpuRenderFrameCount > 0 ? gpuRenderTimeSum / Double(gpuRenderFrameCount) : 0
        let maxRenderTime = gpuRenderTimeMax
        let maxDepth = queueMaxDepth
        let overflows = queueOverflowCount
        let avgSkipped = skippedFramesSampleCount > 0 ? Double(skippedFramesSum) / Double(skippedFramesSampleCount) : 0
        let maxSkipped = skippedFramesMax
        let avgDrift = driftSampleCount > 0 ? driftAbsSum / Double(driftSampleCount) : 0
        let maxDrift = driftAbsMax
        let dropped = droppedRenderFrameCount

        // Reset window
        summaryWindowStart = now
        displayFrameCount = 0
        cameraFrameCount = 0
        gpuRenderFrameCount = 0
        displayIntervalSum = 0
        cameraIntervalSum = 0
        gpuRenderTimeSum = 0
        gpuRenderTimeMax = 0
        queueMaxDepth = 0
        queueOverflowCount = 0
        skippedFramesSum = 0
        skippedFramesMax = 0
        skippedFramesSampleCount = 0
        driftAbsSum = 0
        driftAbsMax = 0
        driftSampleCount = 0
        droppedRenderFrameCount = 0
        renderLoopSampleCount = 0
        renderLoopTimeSum = 0
        renderLoopTimeMax = 0

        lock.unlock()

        let displayFPS = elapsed > 0 ? Double(dispCount) / elapsed : 0
        let cameraFPS = elapsed > 0 ? Double(camCount) / elapsed : 0
        let renderFPS = elapsed > 0 ? Double(renderCount) / elapsed : 0

        summaryLog.info("[Summary] ─────────────────────────────────────────────────")
        summaryLog.info("[Summary] Display FPS:           \(displayFPS, format: .fixed(precision: 1))")
        summaryLog.info("[Summary] Camera FPS:            \(cameraFPS, format: .fixed(precision: 1))")
        summaryLog.info("[Summary] Render FPS:            \(renderFPS, format: .fixed(precision: 1))")
        summaryLog.info("[Summary] Avg camera interval:   \(avgCamInterval * 1000, format: .fixed(precision: 2)) ms")
        summaryLog.info("[Summary] Avg display interval:  \(avgDispInterval * 1000, format: .fixed(precision: 2)) ms")
        summaryLog.info("[Summary] Avg render time:       \(avgRenderTime * 1000, format: .fixed(precision: 2)) ms")
        summaryLog.info("[Summary] Max render time:       \(maxRenderTime * 1000, format: .fixed(precision: 2)) ms")
        summaryLog.info("[Summary] Queue max depth:       \(maxDepth)")
        summaryLog.info("[Summary] Queue overflow count:  \(overflows)")
        summaryLog.info("[Summary] Avg skipped frames:    \(avgSkipped, format: .fixed(precision: 2))")
        summaryLog.info("[Summary] Max skipped frames:    \(maxSkipped)")
        summaryLog.info("[Summary] Avg timestamp drift:   \(avgDrift * 1000, format: .fixed(precision: 2)) ms")
        summaryLog.info("[Summary] Max timestamp drift:   \(maxDrift * 1000, format: .fixed(precision: 2)) ms")
        summaryLog.info("[Summary] Dropped render frames: \(dropped)")
        summaryLog.info("[Summary] ─────────────────────────────────────────────────")
    }
}
