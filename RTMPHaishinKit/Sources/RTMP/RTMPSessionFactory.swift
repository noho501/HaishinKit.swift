import Foundation
import HaishinKit

public struct RTMPSessionFactory: SessionFactory {
    public let supportedProtocols: Set<String> = ["rtmp", "rtmps"]

    public init() {
    }

    public func make(_ uri: URL, method: SessionMethod) -> any Session {
        return RTMPSession(uri: uri, method: method)
    }
}
