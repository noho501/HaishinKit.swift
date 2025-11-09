import Foundation
import libdatachannel

public protocol RTCDataChannelDelegate: AnyObject {
    func dataChannelDidOpen(_ dataChannel: RTCDataChannel)
    func dataChannelDidClosed(_ dataChannel: RTCDataChannel)
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessage message: Data)
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessage message: String)
}

public final class RTCDataChannel: RTCChannel {
    public weak var delegate: (any RTCDataChannelDelegate)?

    /// The label.
    public var label: String {
        do {
            return try CUtil.getString { buffer, size in                rtcGetDataChannelLabel(id, buffer, size)
            }
        } catch {
            logger.warn(error)
            return ""
        }
    }

    /// The stream id.
    public var stream: Int {
        Int(rtcGetDataChannelStream(id))
    }

    override var isOpen: Bool {
        didSet {
            delegate?.dataChannelDidOpen(self)
        }
    }

    override var isClosed: Bool {
        didSet {
            delegate?.dataChannelDidClosed(self)
        }
    }

    deinit {
        rtcDeleteDataChannel(id)
    }

    override func errorOccurred(_ error: String) {
        logger.warn(error)
    }

    override func didReceiveMessage(_ message: Data) {
        delegate?.dataChannel(self, didReceiveMessage: message)
    }

    override func didReceiveMessage(_ message: String) {
        delegate?.dataChannel(self, didReceiveMessage: message)
    }
}
