@preconcurrency import AVFoundation

// MARK: -
/// An actor represents video and audio recorder.
///
/// This actor is compatible with both StreamOutput and MediaMixerOutput. This means it can record the output from MediaMixer in addition to StreamConvertible.
///
/// ```swift
///  // An example of recording MediaMixer.
///  let recorder = StreamRecorder()
///  let mixer = MediaMixer()
///  mixer.addOutput(recorder)
/// ```
/// ```swift
///  // An example of recording streaming.
///  let recorder = StreamRecorder()
///  let mixer = MediaMixer()
///  let stream = RTMPStream()
///  mixer.addOutput(stream)
///  stream.addOutput(recorder)
/// ```
public actor StreamRecorder {
    static let defaultPathExtension = "mp4"

    // MARK: - Internal State Machine

    private enum RecorderState {
        /// Ready to start a new recording.
        case idle
        /// `startRecording` is setting up the writer but has not yet received samples.
        case starting
        /// Actively receiving and writing samples.
        case writing
        /// `stopRecording` has been called; draining queued samples before finishing.
        case stopping
        /// Writing finished successfully.
        case finished
        /// An unrecoverable error occurred.
        case failed
    }

    // MARK: - Sample Queue

    /// Thread-safe FIFO channel that bridges nonisolated callbacks into the actor's
    /// sequential processing loop.
    ///
    /// `@unchecked Sendable` is used here because `continuation` is mutable, but all
    /// accesses are protected by `NSLock`, making concurrent reads and writes safe.
    /// `AsyncStream.Continuation` is itself `Sendable`, so calling `yield`/`finish`
    /// from any thread is safe once the lock is held.
    private final class SampleQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<CMSampleBuffer>.Continuation?

        /// Enqueue a sample.  Returns silently if the stream has already been finished.
        func send(_ sample: CMSampleBuffer) {
            lock.withLock { _ = continuation?.yield(sample) }
        }

        /// Finish the stream and clear the reference.
        func finish() {
            lock.withLock {
                continuation?.finish()
                continuation = nil
            }
        }

        /// Store the continuation created alongside a new `AsyncStream`.
        func set(_ continuation: AsyncStream<CMSampleBuffer>.Continuation) {
            lock.withLock { self.continuation = continuation }
        }
    }

    // MARK: - Statistics

    /// Counters collected during a single recording session.
    public struct Statistics: Sendable {
        /// Total video frames successfully written.
        public internal(set) var totalVideoFrames: Int = 0
        /// Total audio sample buffers successfully written.
        public internal(set) var totalAudioBuffers: Int = 0
        /// Number of append calls that returned `false`.
        public internal(set) var appendFailures: Int = 0
        /// Frames/buffers dropped due to back-pressure or non-monotonic timestamps.
        public internal(set) var droppedFrames: Int = 0
        /// Number of writer-level errors encountered.
        public internal(set) var writerFailures: Int = 0
        /// Wall-clock duration of the recording in seconds (set on finish).
        public internal(set) var recordingDuration: Double = 0

        var description: String {
            "video=\(totalVideoFrames) audio=\(totalAudioBuffers) dropped=\(droppedFrames) "
                + "appendFailures=\(appendFailures) writerFailures=\(writerFailures) "
                + "duration=\(String(format: "%.2f", recordingDuration))s"
        }
    }

    // MARK: - Error

    /// The error domain codes.
    public enum Error: Swift.Error {
        /// An invalid internal state.
        case invalidState
        /// The specified file already exists.
        case fileAlreadyExists(outputURL: URL)
        /// The specifiled file type is not supported.
        case notSupportedFileType(pathExtension: String)
        /// Failed to create the AVAssetWriter.
        case failedToCreateAssetWriter(error: any Swift.Error)
        /// Failed to create the AVAssetWriterInput.
        case failedToCreateAssetWriterInput(error: any Swift.Error)
        /// Failed to append the PixelBuffer or SampleBuffer.
        case failedToAppend(error: (any Swift.Error)?)
        /// Failed to finish writing the AVAssetWriter.
        case failedToFinishWriting(error: (any Swift.Error)?)
    }

    // MARK: - SupportedFileType

    enum SupportedFileType: String {
        case mp4
        case mov

        var fileType: AVFileType {
            switch self {
            case .mp4:
                return .mp4
            case .mov:
                return .mov
            }
        }
    }

    // MARK: - Default Settings

    /// The default recording settings.
    public static let defaultSettings: [AVMediaType: [String: any Sendable]] = [
        .audio: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 0,
            AVNumberOfChannelsKey: 0
        ],
        .video: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoHeightKey: 0,
            AVVideoWidthKey: 0
        ]
    ]

    // MARK: - Public Properties

    /// The recorder settings.
    public private(set) var settings: [AVMediaType: [String: any Sendable]] = StreamRecorder.defaultSettings
    /// The recording output url.
    public var outputURL: URL? {
        return writer?.outputURL
    }
    /// The current error.
    public var error: AsyncStream<StreamRecorder.Error> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    /// Whether a recording is currently in progress.
    public private(set) var isRecording = false
    /// The movie fragment interval in seconds.
    public private(set) var movieFragmentInterval: Double?
    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max
    /// Statistics for the most recent (or current) recording session.
    public private(set) var statistics: Statistics = Statistics()

    #if os(macOS) && !targetEnvironment(macCatalyst)
    /// The default file save location.
    public private(set) var moviesDirectory: URL = {
        URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.moviesDirectory, .userDomainMask, true)[0])
    }()
    #else
    /// The default file save location.
    public private(set) lazy var moviesDirectory: URL = {
        URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0])
    }()
    #endif

    // MARK: - Private Properties

    private var isReadyForStartWriting: Bool {
        guard let writer else {
            return false
        }
        return settings.count == writer.inputs.count
    }

    private var state: RecorderState = .idle
    private var writer: AVAssetWriter?
    private var continuation: AsyncStream<Error>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var writerInputs: [AVMediaType: AVAssetWriterInput] = [:]
    private var audioPresentationTime: CMTime = .invalid  // .invalid means "no buffer received yet"
    private var videoPresentationTime: CMTime = .invalid  // .invalid means "no buffer received yet"
    private var sessionStartTime: CMTime = .invalid
    private var dimensions: CMVideoDimensions = .init(width: 0, height: 0)

    /// Immutable reference to the FIFO sample channel; accessible from nonisolated callbacks.
    nonisolated private let sampleQueue = SampleQueue()
    private var processingTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a new recorder.
    public init() {
    }

    // MARK: - Public Methods

    /// Sets the movie fragment interval in sec.
    ///
    /// This value allows the file to be written continuously, so the file will remain even if the app crashes or is forcefully terminated. A value of 10 seconds or more is recommended.
    /// - seealso: https://developer.apple.com/documentation/avfoundation/avassetwriter/1387469-moviefragmentinterval
    public func setMovieFragmentInterval(_ movieFragmentInterval: Double?) {
        if let movieFragmentInterval {
            self.movieFragmentInterval = max(10.0, movieFragmentInterval)
        } else {
            self.movieFragmentInterval = nil
        }
    }

    /// Starts recording.
    ///
    /// For iOS, if the URL is unspecified, the file will be saved in .documentDirectory. You can specify a folder of your choice, but please use an absolute path.
    ///
    /// ```
    /// try? await recorder.startRecording(nil)
    /// // -> $documentDirectory/B644F60F-0959-4F54-9D14-7F9949E02AD8.mp4
    ///
    /// try? await recorder.startRecording(URL(string: "dir/sample.mp4"))
    /// // -> $documentDirectory/dir/sample.mp4
    ///
    /// try? await recorder.startRecording(await recorder.moviesDirectory.appendingPathComponent("sample.mp4"))
    /// // -> $documentDirectory/sample.mp4
    ///
    /// try? await recorder.startRecording(URL(string: "dir"))
    /// // -> $documentDirectory/dir/33FA7D32-E0A8-4E2C-9980-B54B60654044.mp4
    /// ```
    ///
    /// - Note: Folders are not created automatically, so it's expected that the target directory is created in advance.
    /// - Parameters:
    ///   - url: The file path for recording. If nil is specified, a unique file path will be returned automatically.
    ///   - settings: Settings for recording.
    /// - Throws: `Error.fileAlreadyExists` when case file already exists.
    /// - Throws: `Error.notSupportedFileType` when case specifies not supported format.
    public func startRecording(_ url: URL? = nil, settings: [AVMediaType: [String: any Sendable]] = StreamRecorder.defaultSettings) async throws {
        switch state {
        case .idle, .finished, .failed:
            break
        default:
            throw Error.invalidState
        }

        state = .starting

        let outputURL = makeOutputURL(url)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            state = .idle
            throw Error.fileAlreadyExists(outputURL: outputURL)
        }

        var fileType: AVFileType = .mp4
        if let supportedFileType = SupportedFileType(rawValue: outputURL.pathExtension) {
            fileType = supportedFileType.fileType
        } else {
            state = .idle
            throw Error.notSupportedFileType(pathExtension: outputURL.pathExtension)
        }

        do {
            let newWriter = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
            if let movieFragmentInterval {
                newWriter.movieFragmentInterval = CMTime(seconds: movieFragmentInterval, preferredTimescale: 1)
            }
            writer = newWriter
        } catch {
            state = .idle
            throw Error.failedToCreateAssetWriter(error: error)
        }

        videoPresentationTime = .invalid
        audioPresentationTime = .invalid
        sessionStartTime = .invalid
        statistics = Statistics()
        self.settings = settings

        // Create the FIFO sample stream and start the sequential processing loop.
        let (stream, continuation) = AsyncStream.makeStream(of: CMSampleBuffer.self)
        sampleQueue.set(continuation)

        state = .writing
        isRecording = true

        // Strong capture is intentional: the actor must stay alive while samples are being
        // processed.  The cycle is broken when `processingTask = nil` in `stopRecording()`.
        processingTask = Task {
            for await sample in stream {
                await self.processBuffer(sample)
            }
        }
    }

    /// Stops recording.
    ///
    /// ## Example of saving to the Photos app.
    /// ```
    ///  do {
    ///    let outputURL = try await recorder.stopRecording()
    ///    PHPhotoLibrary.shared().performChanges({() -> Void in
    ///      PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
    ///    }, completionHandler: { _, error -> Void in
    ///      try? FileManager.default.removeItem(at: outputURL)
    ///    }
    ///  } catch {
    ///     print(error)
    ///  }
    /// ```
    public func stopRecording() async throws -> URL {
        guard case .writing = state else {
            throw Error.invalidState
        }

        state = .stopping
        isRecording = false

        // Stop accepting new samples.  Any yield after finish() is a no-op.
        sampleQueue.finish()

        // Wait for all samples already in the FIFO to be processed.
        // processBuffer checks state == .writing and returns early while stopping,
        // so this drains quickly without writing anything further.
        await processingTask?.value
        processingTask = nil

        return try await finishWriting()
    }

    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    // MARK: - Private Helpers

    private func makeOutputURL(_ url: URL?) -> URL {
        guard let url else {
            return moviesDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(Self.defaultPathExtension)
        }
        // AVAssetWriter requires a isFileURL condition.
        guard url.isFileURL else {
            return url.pathExtension.isEmpty ?
                moviesDirectory.appendingPathComponent(url.path).appendingPathComponent(UUID().uuidString).appendingPathExtension(Self.defaultPathExtension) :
                moviesDirectory.appendingPathComponent(url.path)
        }
        return url.pathExtension.isEmpty ? url.appendingPathComponent(UUID().uuidString).appendingPathExtension(Self.defaultPathExtension) : url
    }

    private static func isZero(_ value: any Sendable) -> Bool {
        switch value {
        case let value as Int:
            return value == 0
        case let value as Double:
            return value == 0
        default:
            return false
        }
    }

    // MARK: - Sequential Sample Processing

    /// Called serially for every sample that was enqueued before `stopRecording()`.
    private func processBuffer(_ sampleBuffer: CMSampleBuffer) async {
        guard case .writing = state else {
            return
        }

        let mediaType: AVMediaType = sampleBuffer.formatDescription?.mediaType == .video ? .video : .audio

        guard let writer else { return }
        guard let input = makeWriterInput(mediaType, sourceFormatHint: sampleBuffer.formatDescription) else { return }
        guard isReadyForStartWriting else { return }

        // Start the AVAssetWriter session on the very first sample.
        if writer.status == .unknown {
            guard writer.startWriting() else {
                handleUnexpectedWriterStatus(writer: writer, mediaType: mediaType, pts: sampleBuffer.presentationTimeStamp)
                return
            }
            let pts = sampleBuffer.presentationTimeStamp
            writer.startSession(atSourceTime: pts)
            sessionStartTime = pts
        }

        // Only write when the writer is healthy.
        guard writer.status == .writing else {
            handleUnexpectedWriterStatus(writer: writer, mediaType: mediaType, pts: sampleBuffer.presentationTimeStamp)
            return
        }

        let pts = sampleBuffer.presentationTimeStamp

        // Validate monotonically increasing timestamps to avoid corrupted output.
        if mediaType == .video, videoPresentationTime.isValid, pts <= videoPresentationTime {
            statistics.droppedFrames += 1
            logger.warn(
                "StreamRecorder: non-monotonic video PTS \(pts.seconds) <= \(videoPresentationTime.seconds), "
                    + "dropping (total dropped=\(statistics.droppedFrames))"
            )
            return
        }
        if mediaType == .audio, audioPresentationTime.isValid, pts <= audioPresentationTime {
            statistics.droppedFrames += 1
            logger.warn(
                "StreamRecorder: non-monotonic audio PTS \(pts.seconds) <= \(audioPresentationTime.seconds), "
                    + "dropping (total dropped=\(statistics.droppedFrames))"
            )
            return
        }

        // Handle back-pressure: log and count but do not silently discard.
        guard input.isReadyForMoreMediaData else {
            statistics.droppedFrames += 1
            logger.warn(
                "StreamRecorder: \(mediaType.rawValue) input not ready (back-pressure), "
                    + "total dropped=\(statistics.droppedFrames)"
            )
            return
        }

        if input.append(sampleBuffer) {
            switch mediaType {
            case .video:
                videoPresentationTime = pts
                statistics.totalVideoFrames += 1
            case .audio:
                audioPresentationTime = pts
                statistics.totalAudioBuffers += 1
            default:
                break
            }
        } else {
            statistics.appendFailures += 1
            logger.error(
                "StreamRecorder: failedToAppend mediaType=\(mediaType.rawValue) "
                    + "pts=\(pts.seconds) duration=\(sessionDuration()) "
                    + "writerStatus=\(writer.status.rawValue) writerError=\(String(describing: writer.error)) "
                    + "dropped=\(statistics.droppedFrames) failures=\(statistics.appendFailures)"
            )
            continuation?.yield(.failedToAppend(error: writer.error))
        }
    }

    private func handleUnexpectedWriterStatus(
        writer: AVAssetWriter,
        mediaType: AVMediaType,
        pts: CMTime
    ) {
        statistics.writerFailures += 1
        switch writer.status {
        case .unknown:
            logger.warn("StreamRecorder: writer still unknown for \(mediaType.rawValue) pts=\(pts.seconds)")
        case .writing:
            break
        case .completed:
            logger.info("StreamRecorder: writer already completed, skipping \(mediaType.rawValue)")
        case .failed:
            logger.error(
                "StreamRecorder: writer failed error=\(String(describing: writer.error)) "
                    + "mediaType=\(mediaType.rawValue) pts=\(pts.seconds)"
            )
            continuation?.yield(.failedToAppend(error: writer.error))
        case .cancelled:
            logger.warn("StreamRecorder: writer cancelled, skipping \(mediaType.rawValue)")
        @unknown default:
            logger.warn("StreamRecorder: writer unknown status=\(writer.status.rawValue) mediaType=\(mediaType.rawValue)")
        }
    }

    // MARK: - Finish Writing

    private func finishWriting() async throws -> URL {
        defer {
            continuation = nil
            self.writer = nil
            writerInputs.removeAll()
        }

        guard let writer else {
            state = .failed
            throw Error.failedToFinishWriting(error: nil)
        }

        // Mark every input finished before calling finishWriting().
        for (_, input) in writerInputs {
            input.markAsFinished()
        }

        switch writer.status {
        case .writing:
            await writer.finishWriting()
            if writer.status == .completed {
                statistics.recordingDuration = sessionDuration()
                logger.info("StreamRecorder: recording finished. \(statistics.description)")
                state = .finished
                return writer.outputURL
            } else {
                statistics.writerFailures += 1
                logger.error(
                    "StreamRecorder: finishWriting failed status=\(writer.status.rawValue) "
                        + "error=\(String(describing: writer.error)) \(statistics.description)"
                )
                state = .failed
                throw Error.failedToFinishWriting(error: writer.error)
            }

        case .completed:
            state = .finished
            return writer.outputURL

        case .unknown:
            // No samples were ever written; writer was never started.
            logger.warn("StreamRecorder: writer was never started (no samples received)")
            state = .failed
            throw Error.failedToFinishWriting(error: nil)

        case .failed:
            statistics.writerFailures += 1
            logger.error(
                "StreamRecorder: writer already failed error=\(String(describing: writer.error)) "
                    + "\(statistics.description)"
            )
            state = .failed
            throw Error.failedToFinishWriting(error: writer.error)

        case .cancelled:
            logger.warn("StreamRecorder: writer was cancelled")
            state = .failed
            throw Error.failedToFinishWriting(error: nil)

        @unknown default:
            state = .failed
            throw Error.failedToFinishWriting(error: writer.error)
        }
    }

    private func sessionDuration() -> Double {
        guard sessionStartTime.isValid else { return 0 }
        var lastPTS: CMTime = .invalid
        if videoPresentationTime.isValid {
            lastPTS = lastPTS.isValid ? CMTimeMaximum(lastPTS, videoPresentationTime) : videoPresentationTime
        }
        if audioPresentationTime.isValid {
            lastPTS = lastPTS.isValid ? CMTimeMaximum(lastPTS, audioPresentationTime) : audioPresentationTime
        }
        guard lastPTS.isValid, CMTimeCompare(lastPTS, sessionStartTime) > 0 else { return 0 }
        return CMTimeSubtract(lastPTS, sessionStartTime).seconds
    }

    // MARK: - Writer Input Creation

    private func makeWriterInput(
        _ mediaType: AVMediaType,
        sourceFormatHint: CMFormatDescription?
    ) -> AVAssetWriterInput? {
        if let existing = writerInputs[mediaType] {
            return existing
        }

        var outputSettings: [String: Any] = [:]
        if let settings = self.settings[mediaType] {
            switch mediaType {
            case .audio:
                guard
                    let format = sourceFormatHint,
                    let inSourceFormat = format.audioStreamBasicDescription else {
                    logger.error("StreamRecorder: cannot create audio input — missing audioStreamBasicDescription")
                    continuation?.yield(.failedToCreateAssetWriterInput(
                        error: makeDescriptiveError("missing audioStreamBasicDescription for audio input")
                    ))
                    return nil
                }
                guard inSourceFormat.mSampleRate > 0 else {
                    logger.error("StreamRecorder: invalid audio sample rate \(inSourceFormat.mSampleRate)")
                    continuation?.yield(.failedToCreateAssetWriterInput(
                        error: makeDescriptiveError("invalid audio sample rate \(inSourceFormat.mSampleRate)")
                    ))
                    return nil
                }
                guard inSourceFormat.mChannelsPerFrame > 0 else {
                    logger.error("StreamRecorder: invalid audio channel count \(inSourceFormat.mChannelsPerFrame)")
                    continuation?.yield(.failedToCreateAssetWriterInput(
                        error: makeDescriptiveError("invalid audio channel count \(inSourceFormat.mChannelsPerFrame)")
                    ))
                    return nil
                }
                for (key, value) in settings {
                    switch key {
                    case AVSampleRateKey:
                        outputSettings[key] = Self.isZero(value) ? inSourceFormat.mSampleRate : value
                    case AVNumberOfChannelsKey:
                        outputSettings[key] = Self.isZero(value) ? Int(inSourceFormat.mChannelsPerFrame) : value
                    default:
                        outputSettings[key] = value
                    }
                }

            case .video:
                dimensions = sourceFormatHint?.dimensions ?? .init(width: 0, height: 0)
                guard dimensions.width > 0, dimensions.height > 0 else {
                    logger.error("StreamRecorder: invalid video dimensions \(dimensions.width)x\(dimensions.height)")
                    continuation?.yield(.failedToCreateAssetWriterInput(
                        error: makeDescriptiveError("invalid video dimensions \(dimensions.width)x\(dimensions.height)")
                    ))
                    return nil
                }
                for (key, value) in settings {
                    switch key {
                    case AVVideoHeightKey:
                        outputSettings[key] = Self.isZero(value) ? Int(dimensions.height) : value
                    case AVVideoWidthKey:
                        outputSettings[key] = Self.isZero(value) ? Int(dimensions.width) : value
                    default:
                        outputSettings[key] = value
                    }
                }

            default:
                break
            }
        }

        guard writer?.canApply(outputSettings: outputSettings, forMediaType: mediaType) == true else {
            logger.error(
                "StreamRecorder: canApply returned false for mediaType=\(mediaType.rawValue) "
                    + "settings=\(outputSettings)"
            )
            continuation?.yield(.failedToCreateAssetWriterInput(
                error: makeDescriptiveError("canApply returned false for \(mediaType.rawValue)")
            ))
            return nil
        }

        let input = AVAssetWriterInput(
            mediaType: mediaType,
            outputSettings: outputSettings,
            sourceFormatHint: sourceFormatHint
        )
        input.expectsMediaDataInRealTime = true
        guard writer?.canAdd(input) == true else {
            logger.error("StreamRecorder: canAdd returned false for mediaType=\(mediaType.rawValue)")
            continuation?.yield(.failedToCreateAssetWriterInput(
                error: makeDescriptiveError("canAdd returned false for \(mediaType.rawValue)")
            ))
            return nil
        }
        writerInputs[mediaType] = input
        writer?.add(input)
        return input
    }

    private func makeDescriptiveError(_ message: String) -> NSError {
        NSError(
            domain: kHaishinKitIdentifier,
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

extension StreamRecorder: StreamOutput {
    // MARK: HKStreamOutput
    nonisolated public func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) {
        sampleQueue.send(video)
    }

    nonisolated public func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        guard let sampleBuffer = (audio as? AVAudioPCMBuffer)?.makeSampleBuffer(when) else {
            return
        }
        sampleQueue.send(sampleBuffer)
    }
}

extension StreamRecorder: MediaMixerOutput {
    // MARK: MediaMixerOutput
    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        sampleQueue.send(sampleBuffer)
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let sampleBuffer = buffer.makeSampleBuffer(when) else {
            return
        }
        sampleQueue.send(sampleBuffer)
    }
}
