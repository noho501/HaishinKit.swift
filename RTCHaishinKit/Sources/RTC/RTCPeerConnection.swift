import Foundation
import libdatachannel

public protocol RTCPeerConnectionDelegate: AnyObject {
    func peerConnection(_ peerConnection: RTCPeerConnection, connectionStateChanged connectionState: RTCPeerConnection.ConnectionState)
    func peerConnection(_ peerConnection: RTCPeerConnection, iceGatheringStateChanged iceGatheringState: RTCPeerConnection.IceGatheringState)
    func peerConnection(_ peerConnection: RTCPeerConnection, iceConnectionStateChanged iceConnectionState: RTCPeerConnection.IceConnectionState)
    func peerConnection(_ peerConneciton: RTCPeerConnection, didOpen dataChannel: RTCDataChannel)
    func peerConnection(_ peerConnection: RTCPeerConnection, gotIceCandidate candidated: RTCIceCandidate)
}

public final class RTCPeerConnection {
    /// Represents the state of a connection.
    public enum ConnectionState: Sendable {
        /// The connection has been created, but no connection attempt has started yet.
        case new
        /// A connection attempt is currently in progress.
        case connecting
        /// The connection has been successfully established.
        case connected
        /// The connection was previously established but is now temporarily lost.
        case disconnected
        /// The connection has encountered an unrecoverable error.
        case failed
        /// The connection has been closed and will not be used again.
        case closed
    }

    public enum IceGatheringState: Sendable {
        case new
        case inProgress
        case complete
    }

    public enum IceConnectionState: Sendable {
        case new
        case checking
        case connected
        case completed
        case failed
        case disconnected
        case closed
    }

    static let audioMediaDescription = """
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=mid:0
a=recvonly
a=rtpmap:111 opus/48000/2
a=fmtp:111 minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1
"""

    static let videoMediaDescription = """
m=video 9 UDP/TLS/RTP/SAVPF 98
a=mid:1
a=recvonly
a=rtpmap:98 H264/90000
a=rtcp-fb:98 goog-remb
a=rtcp-fb:98 nack
a=rtcp-fb:98 nack pli
a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
"""

    static let bufferSize: Int = 1024 * 16

    public weak var delegate: (any RTCPeerConnectionDelegate)?
    public private(set) var connectionState: ConnectionState = .new {
        didSet {
            delegate?.peerConnection(self, connectionStateChanged: connectionState)
        }
    }
    public private(set) var iceConnectionState: IceConnectionState = .new {
        didSet {
            delegate?.peerConnection(self, iceConnectionStateChanged: iceConnectionState)
        }
    }
    private let connection: Int32
    private(set) var tracks: [RTCTrack] = []
    private(set) var candidates: [RTCIceCandidate] = []
    private(set) var signalingState: RTCSignalingState = .stable
    private(set) var iceGatheringState: IceGatheringState = .new {
        didSet {
            delegate?.peerConnection(self, iceGatheringStateChanged: iceGatheringState)
        }
    }
    private(set) var localDescription: String = ""

    public init(_ config: some RTCConfigurationConvertible) {
        connection = config.createPeerConnection()
        rtcSetUserPointer(connection, Unmanaged.passUnretained(self).toOpaque())
        rtcSetLocalDescriptionCallback(connection) { _, sdp, _, pointer in
            guard let pointer else { return }
            if let sdp {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().localDescription = String(cString: sdp)
            }
        }
        rtcSetLocalCandidateCallback(connection) { _, candidate, mid, pointer in
            guard let pointer else { return }
            Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().didGenerateCandidate(.init(
                candidate: candidate,
                mid: mid
            ))
        }
        rtcSetStateChangeCallback(connection) { _, state, pointer in
            guard let pointer else { return }
            if let state = ConnectionState(cValue: state) {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().connectionState = state
            }
        }
        rtcSetIceStateChangeCallback(connection) { _, state, pointer in
            guard let pointer else { return }
            if let state = IceConnectionState(cValue: state) {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().iceConnectionState = state
            }
        }
        rtcSetGatheringStateChangeCallback(connection) { _, gatheringState, pointer in
            guard let pointer else { return }
            if let gatheringState = IceGatheringState(cValue: gatheringState) {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().iceGatheringState = gatheringState
            }
        }
        rtcSetSignalingStateChangeCallback(connection) { _, signalingState, pointer in
            guard let pointer else { return }
            if let signalingState = RTCSignalingState(cValue: signalingState) {
                Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().signalingState = signalingState
            }
        }
        rtcSetTrackCallback(connection) { _, track, pointer in
            guard let pointer else { return }
            Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().didReceiveTrack(.init(id: track))
        }
        rtcSetDataChannelCallback(connection) { _, dataChannel, pointer in
            guard let pointer else { return }
            Unmanaged<RTCPeerConnection>.fromOpaque(pointer).takeUnretainedValue().didReceiveDataChannel(.init(id: dataChannel))
        }
    }

    deinit {
        close()
        rtcDeletePeerConnection(connection)
    }

    public func addTrack(_ track: MediaStreamTrack) {
        let connection = self.connection
        Task {
            try await track.addTrack(connection, direction: .sendrecv)
        }
    }

    @discardableResult
    func addTrack(_ kind: MediaStreamKind, stream: MediaStream) throws -> RTCTrack {
        let sdp: String
        switch kind {
        case .audio:
            sdp = Self.audioMediaDescription
        case .video:
            sdp = Self.videoMediaDescription
        }
        let result = try RTCError.check(sdp.withCString { cString in
            rtcAddTrack(connection, cString)
        })
        let track = RTCTrack(id: result)
        track.delegate = stream
        tracks.append(track)
        return track
    }

    public func setRemoteDesciption(_ sdp: String, type: SDPSessionDescriptionType) throws {
        logger.debug(sdp, type.rawValue)
        try RTCError.check([sdp, type.rawValue].withCStrings { cStrings in
            rtcSetRemoteDescription(connection, cStrings[0], cStrings[1])
        })
    }

    public func setLocalDesciption(_ type: SDPSessionDescriptionType) throws {
        logger.debug(type.rawValue)
        try RTCError.check([type.rawValue].withCStrings { cStrings in
            rtcSetLocalDescription(connection, cStrings[0])
        })
    }

    public func createOffer() throws -> String {
        return try CUtil.getString { buffer, size in
            rtcCreateOffer(connection, buffer, size)
        }
    }

    public func createAnswer() throws -> String {
        return try CUtil.getString { buffer, size in
            rtcCreateAnswer(connection, buffer, size)
        }
    }

    public func createDataChannel(_ label: String) throws -> RTCDataChannel {
        let result = try RTCError.check([label].withCStrings { cStrings in
            rtcCreateDataChannel(connection, cStrings[0])
        })
        return RTCDataChannel(id: result)
    }

    public func close() {
        do {
            try RTCError.check(rtcClosePeerConnection(connection))
        } catch {
            logger.warn(error)
        }
    }

    private func didGenerateCandidate(_ candidated: RTCIceCandidate) {
        candidates.append(candidated)
        delegate?.peerConnection(self, gotIceCandidate: candidated)
    }

    private func didReceiveTrack(_ track: RTCTrack) {
        logger.info(track)
    }

    private func didReceiveDataChannel(_ dataChannel: RTCDataChannel) {
        delegate?.peerConnection(self, didOpen: dataChannel)
    }
}

extension RTCPeerConnection.ConnectionState {
    init?(cValue: rtcState) {
        switch cValue {
        case RTC_NEW:
            self = .new
        case RTC_CONNECTING:
            self = .connecting
        case RTC_CONNECTED:
            self = .connected
        case RTC_DISCONNECTED:
            self = .disconnected
        case RTC_FAILED:
            self = .failed
        case RTC_CLOSED:
            self = .closed
        default:
            return nil
        }
    }
}

extension RTCPeerConnection.IceGatheringState {
    init?(cValue: rtcGatheringState) {
        switch cValue {
        case RTC_GATHERING_NEW:
            self = .new
        case RTC_GATHERING_INPROGRESS:
            self = .inProgress
        case RTC_GATHERING_COMPLETE:
            self = .complete
        default:
            return nil
        }
    }
}

extension RTCPeerConnection.IceConnectionState {
    init?(cValue: rtcIceState) {
        switch cValue {
        case RTC_ICE_NEW:
            self = .new
        case RTC_ICE_CHECKING:
            self = .checking
        case RTC_ICE_CONNECTED:
            self = .connected
        case RTC_ICE_COMPLETED:
            self = .completed
        case RTC_ICE_FAILED:
            self = .failed
        case RTC_ICE_DISCONNECTED:
            self = .disconnected
        case RTC_ICE_CLOSED:
            self = .closed
        default:
            return nil
        }
    }
}
