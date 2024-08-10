import Foundation
import XCTest

@testable import HaishinKit

final class RTMPChunkBufferTests: XCTestCase {
    static let readData = Data([2, 0, 0, 0, 0, 0, 4, 5, 0, 0, 0, 0, 0, 76, 75, 64, 2, 0, 0, 0, 0, 0, 5, 6, 0, 0, 0, 0, 0, 76, 75, 64, 2, 2, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0, 0, 0, 0, 32, 0, 3, 0, 0, 0, 0, 0, 190, 20, 0, 0, 0, 0, 2, 0, 7, 95, 114, 101, 115, 117, 108, 116, 0, 63, 240, 0, 0, 0, 0, 0, 0, 3, 0, 6, 102, 109, 115, 86, 101, 114, 2, 0, 13, 70, 77, 83, 47, 51, 44, 48, 44, 49, 44, 49, 50, 51, 0, 12, 99, 97, 112, 97, 98, 105, 108, 105, 116, 105, 101, 115, 0, 64, 63, 0, 0, 0, 0, 0, 0, 0, 0, 9, 3, 0, 5, 108, 101, 118, 101, 108, 2, 0, 6, 115, 116, 97, 116, 117, 115, 0, 4, 99, 111, 100, 101, 2, 0, 29, 78, 101, 116, 67, 111, 110, 110, 101, 99, 116, 105, 111, 110, 46, 67, 111, 110, 110, 101, 99, 116, 46, 83, 117, 99, 99, 101, 115, 115, 0, 11, 100, 101, 115, 99, 114, 105, 112, 116, 105, 111, 110, 2, 0, 21, 67, 111, 110, 110, 101, 99, 116, 105, 111, 110, 32, 115, 117, 99, 99, 101, 101, 100, 101, 100, 46, 0, 14, 111, 98, 106, 101, 99, 116, 69, 110, 99, 111, 100, 105, 110, 103, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9])
    static let readDataBufferUnderflow = Data([2, 0, 0, 0, 0, 0, 4, 5, 0, 0, 0, 0, 0, 76, 75, 64, 2, 0, 0, 0, 0, 0, 5, 6, 0, 0, 0, 0, 0, 76, 75, 64, 2, 2, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0, 0, 0, 0, 32, 0, 3, 0, 0, 0, 0, 0, 190, 20, 0, 0, 0, 0, 2, 0, 7, 95, 114, 101, 115, 117, 108, 116, 0, 63, 240, 0, 0, 0, 0, 0, 0, 3, 0, 6, 102, 109, 115, 86, 101, 114, 2, 0, 13, 70, 77, 83, 47, 51, 44, 48, 44, 49, 44, 49, 50, 51, 0, 12, 99, 97, 112, 97, 98, 105, 108, 105, 116, 105, 101, 115, 0, 64, 63, 0, 0, 0, 0, 0, 0, 0, 0, 9, 3, 0, 5, 108, 101, 118, 101, 108, 2, 0, 6, 115, 116, 97, 116, 117, 115, 0, 4, 99, 111, 100, 101, 2, 0, 29, 78, 101, 116, 67, 111, 110, 110, 101, 99, 116, 105, 111, 110, 46, 67, 111, 110, 110, 101, 99, 116, 46, 83, 117, 99, 99, 101, 115, 115, 0, 11, 100, 101, 115, 99, 114, 105, 112, 116, 105, 111, 110, 2, 0, 21, 67, 111, 110, 110, 101, 99, 116, 105, 111, 110, 32, 115, 117, 99, 99, 101, 101, 100, 101, 100, 46, 0, 14, 111, 98, 106, 101, 99, 116, 69, 110, 99, 111, 100, 105, 110, 103, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

    func testRead() {
        let buffer = RTMPChunkBuffer(.init(count: 1024))
        buffer.put(Self.readData)

        do {
            let (chunkType, chunkStreamId) = try buffer.getBasicHeader()
            XCTAssertEqual(chunkType, .zero)
            XCTAssertEqual(chunkStreamId, 2)
            let header = RTMPChunkMessageHeader()
            try buffer.getMessageHeader(chunkType, messageHeader: header)
            let message = header.makeMessage() as? RTMPWindowAcknowledgementSizeMessage
            XCTAssertEqual(message?.size, 5000000)
        } catch {
        }

        do {
            let (chunkType, chunkStreamId) = try buffer.getBasicHeader()
            XCTAssertEqual(chunkType, .zero)
            XCTAssertEqual(chunkStreamId, 2)
            let header = RTMPChunkMessageHeader()
            try buffer.getMessageHeader(chunkType, messageHeader: header)
            let message = header.makeMessage() as? RTMPSetPeerBandwidthMessage
            XCTAssertEqual(message?.size, 5000000)
        } catch {
        }

        do {
            let (chunkType, chunkStreamId) = try buffer.getBasicHeader()
            XCTAssertEqual(chunkType, .zero)
            XCTAssertEqual(chunkStreamId, 2)
            let header = RTMPChunkMessageHeader()
            try buffer.getMessageHeader(chunkType, messageHeader: header)
            let message = header.makeMessage() as? RTMPSetChunkSizeMessage
            XCTAssertEqual(message?.size, 8192)
            buffer.chunkSize = 8192
        } catch {
        }

        do {
            let (chunkType, chunkStreamId) = try buffer.getBasicHeader()
            XCTAssertEqual(chunkType, .zero)
            XCTAssertEqual(chunkStreamId, 3)
            let header = RTMPChunkMessageHeader()
            try buffer.getMessageHeader(chunkType, messageHeader: header)
            let message = header.makeMessage() as? RTMPCommandMessage
            XCTAssertEqual(message?.commandName, "_result")
        } catch {
        }
    }

    func testRead_BufferUnderflow() {
        let buffer = RTMPChunkBuffer(.init(count: 1024))
        buffer.chunkSize = 8192
        buffer.put(Self.readDataBufferUnderflow)

        var rollbackPosition = buffer.position
        var count = 0
        do {
            while buffer.hasRemaining {
                rollbackPosition = buffer.position
                let (chunkType, _) = try buffer.getBasicHeader()
                let header = RTMPChunkMessageHeader()
                try buffer.getMessageHeader(chunkType, messageHeader: header)
                count += 1
            }
        } catch RTMPChunkError.bufferUnderflow {
            buffer.position = rollbackPosition
        } catch {
        }
        XCTAssertEqual(rollbackPosition, 49)
        XCTAssertEqual(count, 3)
        buffer.put(Data([0, 9]))
        do {
            let (chunkType, _) = try buffer.getBasicHeader()
            let header = RTMPChunkMessageHeader()
            try buffer.getMessageHeader(chunkType, messageHeader: header)
            let message = header.makeMessage() as? RTMPCommandMessage
            XCTAssertEqual(message?.commandName, "_result")
        } catch {
        }
    }

    /*
    func testWrite() {
        let buffer = RTMPChunkBuffer(.init(count: 1024))
        _ = buffer.putBasicHeader(.zero, chunkStreamId: RTMPChunk.StreamID.command.rawValue)
        let connection = RTMPCommandMessage(
            streamId: 0,
            transactionId: 0,
            objectEncoding: .amf0,
            commandName: "hello",
            commandObject: nil,
            arguments: []
        )
        _ = buffer.putMessage(.zero, chunkStreamId: RTMPChunk.StreamID.command.rawValue, message: connection)
    }
     */
}