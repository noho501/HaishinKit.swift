import Foundation
import HaishinKit

actor HTTPSession: Session {
    var connected: Bool {
        get async {
            peerConnection.connectionState == .connected
        }
    }

    @AsyncStreamed(.closed)
    private(set) var readyState: AsyncStream<SessionReadyState>

    var stream: any StreamConvertible {
        _stream
    }

    private let uri: URL
    private var location: URL?
    private var maxRetryCount: Int = 0
    private var _stream = MediaStream()
    private var mode: SessionMode
    private var configuration: HTTPSessionConfiguration?
    private lazy var peerConnection: RTCPeerConnection = makePeerConnection()

    init(uri: URL, mode: SessionMode, configuration: (any SessionConfiguration)?) {
        logger.level = .debug
        self.uri = uri
        self.mode = mode
        if let configuration = configuration as? HTTPSessionConfiguration {
            self.configuration = configuration
        }
    }

    func setMaxRetryCount(_ maxRetryCount: Int) {
        self.maxRetryCount = maxRetryCount
    }

    func connect(_ disconnected: @Sendable @escaping () -> Void) async throws {
        guard _readyState.value == .closed else {
            return
        }
        _readyState.value = .connecting
        peerConnection = makePeerConnection()
        switch mode {
        case .publish:
            await _stream.tracks.forEach { track in
                peerConnection.addTrack(track)
            }
        case .playback:
            await _stream.setDirection(.recvonly)
            try peerConnection.addTrack(.audio, stream: _stream)
            try peerConnection.addTrack(.video, stream: _stream)
        }
        do {
            try peerConnection.setLocalDesciption(.offer)
            let answer = try await requestOffer(uri, offer: peerConnection.createOffer())
            try peerConnection.setRemoteDesciption(answer, type: .answer)
            _readyState.value = .open
        } catch {
            logger.warn(error)
            await _stream.close()
            peerConnection.close()
            _readyState.value = .closed
            throw error
        }
    }

    func close() async throws {
        guard let location, _readyState.value == .open else {
            return
        }
        _readyState.value = .closing
        var request = URLRequest(url: location)
        request.httpMethod = "DELETE"
        request.addValue("application/sdp", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
        await _stream.close()
        peerConnection.close()
        self.location = nil
        _readyState.value = .closed
    }

    private func requestOffer(_ url: URL, offer: String) async throws -> String {
        logger.debug(offer)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = offer.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse {
            if let location = response.allHeaderFields["Location"] as? String {
                if location.hasSuffix("http") {
                    self.location = URL(string: location)
                } else {
                    var baseURL = "\(url.scheme ?? "http")://\(url.host ?? "")"
                    if let port = url.port {
                        baseURL += ":\(port)"
                    }
                    self.location = URL(string: "\(baseURL)\(location)")
                }
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func makePeerConnection() -> RTCPeerConnection {
        let conneciton = if let configuration {
            RTCPeerConnection(configuration)
        } else {
            RTCPeerConnection(RTCConfiguration())
        }
        conneciton.delegate = self
        return conneciton
    }
}

extension HTTPSession: RTCPeerConnectionDelegate {
    // MARK: RTCPeerConnectionDelegate
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, iceGatheringChanged gatheringState: RTCGatheringState) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, iceConnectionChanged state: RTCPeerConnection.ConnectionState) {
        Task {
            if state == .connected {
                if await mode == .publish {
                    await _stream.setDirection(.sendonly)
                }
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, addedTrack track: RTCTrack) {
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, gotIceCandidate candidated: RTCIceCandidate) {
    }

    nonisolated func peerConnection(_ peerConneciton: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
    }
}
