import AVFoundation

protocol CaptureSessionConvertible: Runner {
    #if !os(visionOS)
    @available(tvOS 17.0, *)
    var sessionPreset: AVCaptureSession.Preset { get set }
    #endif

    var isInturreped: AsyncStream<Bool> { get }
    var runtimeError: AsyncStream<AVError> { get }
    var synchronizationClock: CMClock? { get }
    var isMultiCamSessionEnabled: Bool { get set }

    @available(tvOS 17.0, *)
    var isMultitaskingCameraAccessEnabled: Bool { get }

    @available(tvOS 17.0, *)
    func attachCapture(_ capture: (any DeviceUnit)?)
    @available(tvOS 17.0, *)
    func detachCapture(_ capture: (any DeviceUnit)?)
    @available(tvOS 17.0, *)
    func configuration(_ lambda: (_ session: AVCaptureSession) throws -> Void) rethrows
    @available(tvOS 17.0, *)
    func startRunningIfNeeded()
}

#if os(macOS) || os(iOS) || os(visionOS)
final class CaptureSession {
    var isMultiCamSessionEnabled: Bool {
        get {
            capabilities.isMultiCamSessionEnabled
        }
        set {
            capabilities.isMultiCamSessionEnabled = newValue
        }
    }

    private(set) var isRunning = false

    var isMultitaskingCameraAccessEnabled: Bool {
        capabilities.isMultitaskingCameraAccessEnabled(session)
    }

    var isInturreped: AsyncStream<Bool> {
        AsyncStream { continuation in
            isInturrepedContinutation = continuation
        }
    }

    var runtimeError: AsyncStream<AVError> {
        AsyncStream { continutation in
            runtimeErrorContinutation = continutation
        }
    }

    var synchronizationClock: CMClock? {
        capabilities.synchronizationClock(session)
    }

    #if !os(visionOS)
    var sessionPreset: AVCaptureSession.Preset = .default {
        didSet {
            guard sessionPreset != oldValue, session.canSetSessionPreset(sessionPreset) else {
                return
            }
            session.beginConfiguration()
            session.sessionPreset = sessionPreset
            session.commitConfiguration()
        }
    }
    private(set) lazy var session: AVCaptureSession = capabilities.makeSession(sessionPreset)
    #else
    private(set) lazy var session = AVCaptureSession()
    #endif

    private lazy var capabilities = Capabilities()

    private var isInturrepedContinutation: AsyncStream<Bool>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }

    private var runtimeErrorContinutation: AsyncStream<AVError>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }

    deinit {
        if session.isRunning {
            session.stopRunning()
        }
    }
}
#elseif os(tvOS)
final class CaptureSession {
    var isMultiCamSessionEnabled: Bool {
        get {
            capabilities.isMultiCamSessionEnabled
        }
        set {
            capabilities.isMultiCamSessionEnabled = newValue
        }
    }

    private(set) var isRunning = false

    var isMultitaskingCameraAccessEnabled: Bool {
        if #available(tvOS 17.0, *) {
            capabilities.isMultitaskingCameraAccessEnabled(session)
        } else {
            false
        }
    }

    var isInturreped: AsyncStream<Bool> {
        AsyncStream { continuation in
            isInturrepedContinutation = continuation
        }
    }

    var runtimeError: AsyncStream<AVError> {
        AsyncStream { continutation in
            runtimeErrorContinutation = continutation
        }
    }

    var synchronizationClock: CMClock? {
        if #available(tvOS 17.0, *) {
            return session.synchronizationClock
        } else {
            return nil
        }
    }

    private var _session: Any?
    /// The capture session instance.
    @available(tvOS 17.0, *)
    var session: AVCaptureSession {
        if _session == nil {
            _session = capabilities.makeSession(sessionPreset)
        }
        return _session as! AVCaptureSession
    }

    private var _sessionPreset: Any?
    @available(tvOS 17.0, *)
    var sessionPreset: AVCaptureSession.Preset {
        get {
            if _sessionPreset == nil {
                _sessionPreset = AVCaptureSession.Preset.default
            }
            return _sessionPreset as! AVCaptureSession.Preset
        }
        set {
            guard sessionPreset != newValue, session.canSetSessionPreset(newValue) else {
                return
            }
            session.beginConfiguration()
            session.sessionPreset = newValue
            session.commitConfiguration()
        }
    }

    private var isInturrepedContinutation: AsyncStream<Bool>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }

    private var runtimeErrorContinutation: AsyncStream<AVError>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }

    private lazy var capabilities = Capabilities()

    deinit {
        guard #available(tvOS 17.0, *) else {
            return
        }
        if session.isRunning {
            session.stopRunning()
        }
    }
}
#endif

extension CaptureSession: CaptureSessionConvertible {
    // MARK: CaptureSessionConvertible
    @available(tvOS 17.0, *)
    func configuration(_ lambda: (_ session: AVCaptureSession) throws -> Void ) rethrows {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        try lambda(session)
    }

    @available(tvOS 17.0, *)
    func attachCapture(_ capture: (any DeviceUnit)?) {
        guard let capture else {
            return
        }
        #if !os(visionOS)
        if let connection = capture.connection {
            if let input = capture.input, session.canAddInput(input) {
                session.addInputWithNoConnections(input)
            }
            if let output = capture.output, session.canAddOutput(output) {
                session.addOutputWithNoConnections(output)
            }
            if session.canAddConnection(connection) {
                session.addConnection(connection)
            }
            return
        }
        #endif
        if let input = capture.input, session.canAddInput(input) {
            session.addInput(input)
        }
        if let output = capture.output, session.canAddOutput(output) {
            session.addOutput(output)
        }
    }

    @available(tvOS 17.0, *)
    func detachCapture(_ capture: (any DeviceUnit)?) {
        guard let capture else {
            return
        }
        #if !os(visionOS)
        if let connection = capture.connection {
            if capture.output?.connections.contains(connection) == true {
                session.removeConnection(connection)
            }
        }
        #endif
        if let input = capture.input, session.inputs.contains(input) {
            session.removeInput(input)
        }
        if let output = capture.output, session.outputs.contains(output) {
            session.removeOutput(output)
        }
    }

    @available(tvOS 17.0, *)
    func startRunningIfNeeded() {
        guard isRunning && !session.isRunning else {
            return
        }
        session.startRunning()
        isRunning = session.isRunning
    }

    @available(tvOS 17.0, *)
    private func addSessionObservers(_ session: AVCaptureSession) {
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)), name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
        #endif
    }

    @available(tvOS 17.0, *)
    private func removeSessionObservers(_ session: AVCaptureSession) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
        #endif
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
        runtimeErrorContinutation = nil
    }

    @available(tvOS 17.0, *)
    @objc
    private func sessionRuntimeError(_ notification: NSNotification) {
        guard
            let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        runtimeErrorContinutation?.yield(AVError(_nsError: errorValue))
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @available(tvOS 17.0, *)
    @objc
    private func sessionWasInterrupted(_ notification: Notification) {
        isInturrepedContinutation?.yield(true)
    }

    @available(tvOS 17.0, *)
    @objc
    private func sessionInterruptionEnded(_ notification: Notification) {
        isInturrepedContinutation?.yield(false)
    }
    #endif
}

extension CaptureSession: Runner {
    // MARK: Runner
    func startRunning() {
        guard !isRunning else {
            return
        }
        if #available(tvOS 17.0, *) {
            addSessionObservers(session)
            session.startRunning()
            isRunning = session.isRunning
        } else {
            isRunning = true
        }
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        if #available(tvOS 17.0, *) {
            removeSessionObservers(session)
            session.stopRunning()
            isRunning = session.isRunning
        } else {
            isRunning = false
        }
    }
}

final class NullCaptureSession: CaptureSessionConvertible {
    #if !os(visionOS)
    @available(tvOS 17.0, *)
    var sessionPreset: AVCaptureSession.Preset {
        get {
            return .default
        }
        set {
        }
    }
    #endif

    var isMultiCamSessionEnabled = false
    let isMultitaskingCameraAccessEnabled = false
    let synchronizationClock: CMClock? = nil

    @AsyncStreamed(false)
    var isInturreped: AsyncStream<Bool>

    @AsyncStreamedFlow
    var runtimeError: AsyncStream<AVError>

    private(set) var isRunning = false

    @available(tvOS 17.0, *)
    func attachCapture(_ capture: (any DeviceUnit)?) {
    }

    @available(tvOS 17.0, *)
    func detachCapture(_ capture: (any DeviceUnit)?) {
    }

    @available(tvOS 17.0, *)
    func configuration(_ lambda: (AVCaptureSession) throws -> Void) rethrows {
    }

    func startRunningIfNeeded() {
    }
}

extension NullCaptureSession: Runner {
    // MARK: Runner
    func startRunning() {
    }

    func stopRunning() {
    }
}
