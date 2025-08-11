import Foundation

/// An actor that provides a factory to create a SessionBuifer.
///
/// ## Prerequisites
/// You need to register the factory in advance as follows.
/// ```swift
/// import RTMPHaishinKit
/// import SRTHaishinKit
///
/// await SessionBuilderFactory.shared.register(RTMPSessionFactory())
/// await SessionBuilderFactory.shared.register(SRTSessionFactory())
/// ```
public actor SessionBuilderFactory {
    /// The shared instance.
    public static let shared = SessionBuilderFactory()

    /// The error domain codes.
    public enum Error: Swift.Error {
        /// An illegal argument.
        case illegalArgument
        /// The factory can't find a SessionBuilder.
        case notFound
    }

    private var factories: [any SessionFactory] = []

    private init() {
    }

    /// Makes a new session builder.
    public func make(_ uri: URL?) throws -> SessionBuilder {
        guard let uri else {
            throw Error.illegalArgument
        }
        return SessionBuilder(manager: self, uri: uri)
    }

    /// Registers a factory.
    public func register(_ factory: some SessionFactory) {
        guard !factories.contains(where: { $0.supportedProtocols == factory.supportedProtocols }) else {
            return
        }
        factories.append(factory)
    }

    func build(_ uri: URL?) throws -> (any Session) {
        guard let uri else {
            throw Error.illegalArgument
        }
        for factory in factories where factory.supportedProtocols.contains(uri.scheme ?? "") {
            return factory.make(uri)
        }
        throw Error.notFound
    }
}
