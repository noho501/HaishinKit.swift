import HaishinKit
@preconcurrency import Logboard
import MediaPlayer
import ReplayKit
import RTMPHaishinKit
import SRTHaishinKit
import VideoToolbox

nonisolated let logger = LBLogger.with("com.haishinkit.Screencast")

@available(iOS 10.0, *)
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private var slider: UISlider?

    private var _rotator: Any?
    @available(iOS 16.0, tvOS 16.0, macOS 13.0, *)
    private var rotator: VideoRotator? {
        get {
            _rotator as? VideoRotator
        }
        set {
            _rotator = newValue
        }
    }

    private var isVideoRotationEnabled = false {
        didSet {
            if isVideoRotationEnabled, #available(iOS 16.0, tvOS 16.0, macOS 13.0, *) {
                _rotator = VideoRotator()
            } else {
                _rotator = nil
            }
        }
    }
    private var session: Session?
    private var mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
    private var needVideoConfiguration = true

    override init() {
        Task {
            await SessionBuilderFactory.shared.register(RTMPSessionFactory())
            await SessionBuilderFactory.shared.register(SRTSessionFactory())
        }
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        /*
         let socket = SocketAppender()
         socket.connect("192.168.1.9", port: 22222)
         logger.level = .debug
         logger.appender = socket
         logger.level = .debug
         */
        LBLogger.with(kHaishinKitIdentifier).level = .info
        // mixer.audioMixerSettings.tracks[1] = .default
        isVideoRotationEnabled = false
        Task {
            do {
                session = try await SessionBuilderFactory.shared.make(Preference.default.makeURL()).build()
                // ReplayKit is sensitive to memory, so we limit the queue to a maximum of five items.
                var videoSetting = await mixer.videoMixerSettings
                videoSetting.mode = .passthrough
                await session?.stream.setVideoInputBufferCounts(5)
                await mixer.setVideoMixerSettings(videoSetting)
                await mixer.startRunning()
                if let session {
                    await mixer.addOutput(session.stream)
                    try? await session.connect {
                    }
                }
            } catch {
                logger.error(error)
            }
        }
        // The volume of the audioApp can be obtained even when muted. A hack to synchronize with the volume.
        DispatchQueue.main.async {
            let volumeView = MPVolumeView(frame: CGRect.zero)
            if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
                self.slider = slider
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            Task {
                if needVideoConfiguration, let dimensions = sampleBuffer.formatDescription?.dimensions {
                    var videoSettings = await session?.stream.videoSettings
                    videoSettings?.videoSize = .init(
                        width: CGFloat(dimensions.width),
                        height: CGFloat(dimensions.height)
                    )
                    videoSettings?.profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel as String
                    if let videoSettings {
                        try? await session?.stream.setVideoSettings(videoSettings)
                    }
                    needVideoConfiguration = false
                }
            }
            if #available(iOS 16.0, tvOS 16.0, macOS 13.0, *), let rotator {
                switch rotator.rotate(buffer: sampleBuffer) {
                case .success(let rotatedBuffer):
                    Task { await mixer.append(rotatedBuffer) }
                case .failure(let error):
                    logger.error(error)
                }
            } else {
                Task { await mixer.append(sampleBuffer) }
            }
        case .audioMic:
            if sampleBuffer.dataReadiness == .ready {
                Task { await mixer.append(sampleBuffer, track: 0) }
            }
        case .audioApp:
            Task { @MainActor in
                if let volume = slider?.value {
                    var audioMixerSettings = await mixer.audioMixerSettings
                    audioMixerSettings.tracks[1] = .default
                    audioMixerSettings.tracks[1]?.volume = volume * 0.5
                    await mixer.setAudioMixerSettings(audioMixerSettings)
                }
            }
            if sampleBuffer.dataReadiness == .ready {
                Task { await mixer.append(sampleBuffer, track: 1) }
            }
        @unknown default:
            break
        }
    }
}
