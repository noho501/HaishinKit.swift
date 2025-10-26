import AVFoundation
import CoreImage

final class VideoCaptureUnit: CaptureUnit {
    enum Error: Swift.Error {
        case multiCamNotSupported
    }

    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.VideoCaptureUnit.lock")

    var mixerSettings: VideoMixerSettings {
        get {
            return videoMixer.settings
        }
        set {
            videoMixer.settings = newValue
        }
    }
    var inputFormats: [UInt8: CMFormatDescription] {
        return videoMixer.inputFormats
    }
    #if os(iOS) || os(tvOS) || os(macOS)
    var isTorchEnabled = false {
        didSet {
            guard #available(tvOS 17.0, *) else {
                return
            }
            setTorchMode(isTorchEnabled ? .on : .off)
        }
    }
    #endif

    @available(tvOS 17.0, *)
    var hasDevice: Bool {
        !devices.lazy.filter { $0.value.device != nil }.isEmpty
    }

    #if os(iOS) || os(macOS)
    var videoOrientation: AVCaptureVideoOrientation = .portrait {
        didSet {
            guard videoOrientation != oldValue else {
                return
            }
            session.configuration { _ in
                for capture in devices.values {
                    capture.videoOrientation = videoOrientation
                }
            }
        }
    }
    #endif

    var inputs: AsyncStream<(UInt8, CMSampleBuffer)> {
        AsyncStream<(UInt8, CMSampleBuffer)> { continutation in
            self.inputsContinuation = continutation
        }
    }

    var output: AsyncStream<CMSampleBuffer> {
        AsyncStream<CMSampleBuffer> { continutation in
            self.outputContinuation = continutation
        }
    }

    private lazy var videoMixer = {
        var videoMixer = VideoMixer<VideoCaptureUnit>()
        videoMixer.delegate = self
        return videoMixer
    }()

    private var outputContinuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var inputsContinuation: AsyncStream<(UInt8, CMSampleBuffer)>.Continuation?

    #if os(tvOS)
    private var _devices: [UInt8: Any] = [:]
    @available(tvOS 17.0, *)
    var devices: [UInt8: VideoDeviceUnit] {
        return _devices as! [UInt8: VideoDeviceUnit]
    }
    #elseif os(iOS) || os(macOS) || os(visionOS)
    var devices: [UInt8: VideoDeviceUnit] = [:]
    #endif

    private let session: (any CaptureSessionConvertible)

    init(_ session: (some CaptureSessionConvertible)) {
        self.session = session
    }

    func append(_ track: UInt8, buffer: CMSampleBuffer) {
        videoMixer.append(track, sampleBuffer: buffer)
    }

    @available(tvOS 17.0, *)
    func attachVideo(_ track: UInt8, device: AVCaptureDevice?, configuration: VideoDeviceConfigurationBlock?) throws {
        if hasDevice && device != nil && session.isMultiCamSessionEnabled == false {
            throw Error.multiCamNotSupported
        }
        try session.configuration { _ in
            session.detachCapture(self.devices[track])
            videoMixer.reset(track)
            if let device {
                let capture = try VideoDeviceUnit(track, device: device)
                capture.videoOrientation = videoOrientation
                capture.setSampleBufferDelegate(self)
                try? configuration?(capture)
                session.attachCapture(capture)
                capture.apply()
                self.devices[track] = capture
            }
        }
    }

    #if os(iOS) || os(tvOS) || os(macOS)
    @available(tvOS 17.0, *)
    func setTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        for capture in devices.values {
            capture.setTorchMode(torchMode)
        }
    }
    #endif

    @available(tvOS 17.0, *)
    func setBackgroundMode(_ background: Bool) {
        guard !session.isMultitaskingCameraAccessEnabled else {
            return
        }
        if background {
            for capture in devices.values {
                session.detachCapture(capture)
            }
        } else {
            for capture in devices.values {
                session.attachCapture(capture)
            }
        }
    }

    @available(tvOS 17.0, *)
    func makeDataOutput(_ track: UInt8) -> VideoCaptureUnitDataOutput {
        return .init(track: track, videoMixer: videoMixer)
    }

    func finish() {
        inputsContinuation?.finish()
        outputContinuation?.finish()
    }
}

extension VideoCaptureUnit: VideoMixerDelegate {
    // MARK: VideoMixerDelegate
    func videoMixer(_ videoMixer: VideoMixer<VideoCaptureUnit>, track: UInt8, didInput sampleBuffer: CMSampleBuffer) {
        inputsContinuation?.yield((track, sampleBuffer))
    }

    func videoMixer(_ videoMixer: VideoMixer<VideoCaptureUnit>, didOutput sampleBuffer: CMSampleBuffer) {
        outputContinuation?.yield(sampleBuffer)
    }
}
