import CoreMedia
import Foundation

final class TypedBlockQueue<T: AnyObject> {
    private let queue: CMBufferQueue
    private let capacity: CMItemCount

    @inlinable @inline(__always) var head: T? {
        guard let head = queue.head else {
            return nil
        }
        return (head as! T)
    }

    @inlinable @inline(__always) var isEmpty: Bool {
        queue.isEmpty
    }

    @inlinable @inline(__always) var duration: CMTime {
        queue.duration
    }

    @inlinable @inline(__always) var count: CMItemCount {
        CMBufferQueueGetBufferCount(queue)
    }

    init(capacity: CMItemCount, handlers: CMBufferQueue.Handlers) throws {
        self.capacity = capacity
        self.queue = try CMBufferQueue(capacity: capacity, handlers: handlers)
    }

    @inlinable
    @inline(__always)
    func enqueue(_ buffer: T) throws {
        try queue.enqueue(buffer)
    }

    @inlinable
    @inline(__always)
    func dequeue() -> T? {
        guard let value = queue.dequeue() else {
            return nil
        }
        return (value as! T)
    }

    @inlinable
    @inline(__always)
    func reset() throws {
        try queue.reset()
    }
}

extension TypedBlockQueue where T == CMSampleBuffer {
    func dequeue(_ presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        var result: CMSampleBuffer?
        let diag = OffscreenDiagnostics.shared
        let diagEnabled = diag.isEnabled
        let renderPTS = diagEnabled ? presentationTimeStamp.seconds : 0
        let headPTSBefore: Double? = diagEnabled ? head?.presentationTimeStamp.seconds : nil
        var skippedCount = 0

        defer {
            if diagEnabled {
                let queueCountAfter = Int(count)
                diag.recordDequeueComplete(
                    renderPTS: renderPTS,
                    headPTSBefore: headPTSBefore,
                    skippedCount: skippedCount,
                    returnedPTS: result?.presentationTimeStamp.seconds,
                    queueCountAfter: queueCountAfter
                )
            }
        }

        while !queue.isEmpty {
            guard let head else {
                break
            }
            if head.presentationTimeStamp <= presentationTimeStamp {
                if result != nil {
                    // A previously dequeued frame is being discarded in favour of a later one.
                    skippedCount += 1
                }
                result = dequeue()
                if diagEnabled, let result {
                    diag.logQueueDequeuedFrame(pts: result.presentationTimeStamp.seconds)
                }
            } else {
                return result
            }
        }
        return result
    }
}
