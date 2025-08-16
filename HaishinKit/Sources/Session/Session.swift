import Foundation

package let kSession_maxRetryCount: Int = 3

public enum SessionMethod: Sendable {
    case ingest
    case playback
}

/// Represents the current connection state of a session.
public enum SessionReadyState: Int, Sendable {
    /// The session is currently attempting to establish a connection.
    case connecting
    /// The session has been successfully established and is ready for communication.
    case open
    /// The session is in the process of closing the connection.
    case closing
    /// The session has been closed or could not be established.
    case closed
}

/// A type that represents a foundation of streaming session.
///
/// It is designed so that various streaming services can be used through a common API.
/// While coding with the conventional Connection offered flexibility,
/// it also required a certain level of maturity in properly handling network communication.
public protocol Session: NetworkConnection {
    /// The current ready state.
    var readyState: AsyncStream<SessionReadyState> { get }

    /// The stream instance.
    var stream: any StreamConvertible { get }

    /// Creates a new session with uri.
    init(uri: URL, method: SessionMethod)

    /// Sets a max retry count.
    func setMaxRetryCount(_ maxRetryCount: Int)

    /// Creates a connection to the server.
    func connect(_ disconnected: @Sendable @escaping () -> Void) async throws
}
