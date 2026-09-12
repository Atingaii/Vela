import Foundation
import Darwin

enum BoundedInputLine {
    case data(Data)
    case tooLong
}

/// JSONL framing with a fixed read buffer and at most one bounded pending line.
/// An oversized line reports once, immediately, then drains through its newline.
final class BoundedInputReader {
    private let descriptor: Int32
    private let maximumBytes: Int
    private var chunk = [UInt8](repeating:0,count:64 * 1024)
    private var cursor = 0
    private var count = 0
    private var frame = Data()
    private var discarding = false
    private var ended = false

    init(descriptor: Int32 = STDIN_FILENO, maximumBytes: Int = 2_000_000) {
        precondition(maximumBytes > 0 && maximumBytes < Int.max)
        self.descriptor = descriptor
        self.maximumBytes = maximumBytes
    }

    func next() throws -> BoundedInputLine? {
        while true {
            if cursor == count {
                if ended { return nil }
                var bytesRead: Int
                repeat {
                    bytesRead = chunk.withUnsafeMutableBytes { buffer in
                        Darwin.read(descriptor,buffer.baseAddress!,buffer.count)
                    }
                } while bytesRead < 0 && errno == EINTR
                guard bytesRead >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
                }
                if bytesRead == 0 {
                    ended = true
                    guard !discarding, !frame.isEmpty else { return nil }
                    return finishLine()
                }
                cursor = 0
                count = bytesRead
            }

            let newline = chunk[cursor..<count].firstIndex(of:0x0A)
            let end = newline ?? count
            let length = end - cursor
            var exceeded = false
            if !discarding {
                // One additional byte permits CRLF at the exact payload limit.
                let remaining = maximumBytes + 1 - frame.count
                if length > remaining {
                    exceeded = true
                } else {
                    frame.append(contentsOf:chunk[cursor..<end])
                    exceeded = frame.count > maximumBytes && frame.last != 0x0D
                }
                if exceeded {
                    frame.removeAll(keepingCapacity:false)
                    discarding = true
                }
            }
            cursor = end

            if newline != nil {
                cursor += 1
                if discarding {
                    discarding = false
                } else {
                    return finishLine()
                }
            }
            if exceeded { return .tooLong }
        }
    }

    private func finishLine() -> BoundedInputLine {
        if frame.last == 0x0D { frame.removeLast() }
        let complete = frame
        frame = Data()
        return .data(complete)
    }
}
