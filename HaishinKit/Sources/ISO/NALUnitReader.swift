import CoreMedia
import Foundation

final package class NALUnitReader {
    static package let defaultNALUnitHeaderLength: Int32 = 4
    package var nalUnitHeaderLength: Int32 = NALUnitReader.defaultNALUnitHeaderLength

    package init() {
    }

    package func read<T: NALUnit>(_ data: inout Data, type: T.Type) -> [T] {
        var units: [T] = .init()
        var lastIndexOf = data.count - 1
        for i in (2..<data.count).reversed() {
            guard data[i] == 1 && data[i - 1] == 0 && data[i - 2] == 0 else {
                continue
            }
            let startCodeLength = 0 <= i - 3 && data[i - 3] == 0 ? 4 : 3
            units.append(T.init(data.subdata(in: (i + 1)..<lastIndexOf + 1)))
            lastIndexOf = i - startCodeLength
        }
        return units
    }

    package func read(_ buffer: CMSampleBuffer) -> [Data] {
        var offset = 0
        let header = Int(Self.defaultNALUnitHeaderLength)
        let length = buffer.dataBuffer?.dataLength ?? 0
        var result: [Data] = []
        
        if !buffer.isNotSync {
            result.append(Data([0x09, 0x10]))
            buffer.formatDescription?.parameterSets.forEach {
                result.append($0)
            }
        } else {
            result.append(Data([0x09, 0x30]))
        }
        
        try? buffer.dataBuffer?.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            while offset + header < length {
                var nalUnitLength: UInt32 = 0
                memcpy(&nalUnitLength, baseAddress + offset, header)
                nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)
                let start = offset + header
                let end = start + Int(nalUnitLength)
                if end <= length {
                    result.append(Data(bytes: baseAddress + start, count: Int(nalUnitLength)))
                } else {
                    break
                }
                offset = end
            }
        }
        return result
    }
}
