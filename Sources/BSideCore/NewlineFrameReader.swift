// BSideCore — NewlineFrameReader: pure newline-frame demultiplexer for the ADR-007 pipe
// transport (Beta Slice 6).
//
// Both production readers feed raw pipe bytes here and receive complete newline-terminated
// frames back:
//   * ControlApp  -> AgentSupervisor.ingest  (agent stdout  → AgentEvent envelopes)
//   * WallpaperAgent -> readStdinLoop         (ControlApp stdin → AgentCommand envelopes)
//
// Guarantees (transport-pure: this type knows nothing about JSON, versions, or processes):
//   * partial reads/writes: bytes accumulate across feed(_:) calls until a newline;
//   * multiple frames per read: every complete frame in one chunk is returned, in order;
//   * bounded memory: bufferedBytes never exceeds maxFrameSize, even if no newline ever
//     arrives — the frame is dropped at the limit, its bytes are discarded until the
//     terminating newline (oversizeDropped / bytesDropped), then framing recovers cleanly
//     at the next newline and the next valid frame is accepted;
//   * EOF: finish() returns the final unterminated frame if a partial line was in flight
//     (callers may treat it as a complete line, matching readLine semantics); an oversized
//     tail is accounted and dropped.
// A blank line is returned as an empty Data frame; readers choose to skip it (the existing
// production readers do).

import Foundation

public struct NewlineFrameReader {
    /// Documented maximum size of ONE newline-delimited frame (1 MiB).
    /// Includes ADR-007 state and ephemeral directory grants. The hard bound prevents
    /// hostile or garbage input from growing
    /// a pipe reader's memory past this constant. Frames beyond this size are dropped whole
    /// and framing resynchronizes at the next newline.
    public static let maxFrameSize = 1 << 20

    /// Complete frames extracted so far (empty frames included; trailing newline removed).
    public private(set) var framesRead = 0
    /// Number of frames dropped for exceeding `maxFrameSize`.
    public private(set) var oversizeDropped = 0
    /// Total bytes dropped while discarding oversized frames (dropped frame bytes plus the
    /// terminating newline byte).
    public private(set) var bytesDropped = 0
    /// Bytes currently buffered awaiting a newline. Invariant: 0 ... maxFrameSize.
    public private(set) var bufferedBytes = 0

    private var buffer = Data()
    /// True while we are discarding an oversized frame that overflowed without a newline
    /// having been seen yet; discard continues until the terminating newline.
    private var discarding = false

    public init() {}

    /// Feed a raw chunk of pipe bytes. Returns every complete frame contained in it (zero or
    /// more), without trailing newlines. Empty lines are returned as empty Data.
    public mutating func feed(_ chunk: Data) -> [Data] {
        var frames: [Data] = []
        var rest = chunk

        while !rest.isEmpty {
            if discarding {
                // Skip everything until the terminating newline of the oversized frame.
                if let nl = rest.firstIndex(of: 0x0A) {
                    let skip = rest.distance(from: rest.startIndex, to: nl) + 1
                    bytesDropped += skip
                    rest.removeFirst(skip)
                    discarding = false
                    oversizeDropped += 1
                } else {
                    bytesDropped += rest.count
                    rest.removeAll()
                }
                continue
            }

            if let nl = rest.firstIndex(of: 0x0A) {
                let lineLen = rest.distance(from: rest.startIndex, to: nl)
                if buffer.count + lineLen <= Self.maxFrameSize {
                    buffer.append(rest[rest.startIndex..<nl])
                    frames.append(buffer)
                    framesRead += 1
                    buffer.removeAll(keepingCapacity: false)
                } else {
                    // The complete line overflows the bound: drop it whole (buffer prefix +
                    // this line's bytes + its newline), then continue after the newline.
                    bytesDropped += buffer.count + lineLen + 1
                    buffer.removeAll(keepingCapacity: false)
                    oversizeDropped += 1
                }
                rest.removeFirst(lineLen + 1)
                continue
            }

            // No newline anywhere in the remainder. Append only what fits; if the remainder
            // still exceeds the bound, the frame is oversized with no newline in sight —
            // discard the buffered prefix and everything remaining until a newline arrives.
            let capacity = Self.maxFrameSize - buffer.count
            if rest.count <= capacity {
                buffer.append(rest)
                rest.removeAll()
            } else {
                bytesDropped += buffer.count + rest.count
                buffer.removeAll(keepingCapacity: false)
                discarding = true
                rest.removeAll()
            }
        }

        bufferedBytes = buffer.count
        return frames
    }

    /// EOF. If an unterminated partial frame is buffered, return it as a final frame (callers
    /// may decode it; a dying writer's partial JSON will simply fail decode and be skipped, as
    /// with any malformed line). If an oversized tail was being discarded, account it as one
    /// dropped frame. Idempotent; after finish() the reader is ready for a fresh stream.
    public mutating func finish() -> Data? {
        if discarding {
            bytesDropped += buffer.count
            buffer.removeAll(keepingCapacity: false)
            discarding = false
            oversizeDropped += 1
            bufferedBytes = 0
            return nil
        }
        guard !buffer.isEmpty else { return nil }
        let final = buffer
        buffer.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        framesRead += 1
        return final
    }
}
