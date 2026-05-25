import Compression
import CoreGraphics
import Foundation

// MARK: - File format
//
// A `.tgsc` cached frame file is laid out as:
//
//   [Header — 32 bytes, all multi-byte values little-endian]
//     0–3:   magic bytes 'T', 'G', 'S', 'C'
//     4–7:   version          UInt32  (currently 1)
//     8–11:  width            UInt32
//     12–15: height           UInt32
//     16–19: bytesPerRow      UInt32
//     20–23: frameRate        UInt32
//     24–27: frameCount       UInt32
//     28–31: reserved         UInt32  (always 0)
//
//   [Frame index table — frameCount × 8 bytes, starting at offset 32]
//     for each frame i in 0..<frameCount:
//       offset 32 + i*8:     compressedOffset UInt32   (byte offset in file)
//       offset 32 + i*8 + 4: compressedSize   UInt32   (LZFSE blob length)
//
//   [Frame data — starts at offset 32 + frameCount*8]
//     for each frame i: LZFSE-compressed XOR-delta bytes.
//       delta_i = frame_i XOR frame_{i-1}, with frame_{-1} treated as all zeros.
//
// On the read side, a running `previousFrameBuffer` is XOR'd with each newly
// decompressed delta to reconstruct the real frame. When playback wraps from
// the last frame back to frame 0 (looping animation), `previousFrameBuffer`
// is zeroed so frame 0's delta XOR'd against zero yields the raw RGBA again.
//
// This is the same compression strategy Telegram iOS uses in its
// `AnimatedStickerCachedFrameSource`: XOR-delta exposes large flat / unchanged
// regions as runs of zero bytes that LZFSE compresses extremely tightly.
// Typical 96x96 30-frame stickers come out around 5–15 KB per frame on disk
// while decoding in ~50 µs (vs. ~2–5 ms for `rlottie::Animation::renderSync`).

internal enum TGSCachedFrameFormat {
    static let magicBytes: [UInt8] = [
        UInt8(ascii: "T"), UInt8(ascii: "G"),
        UInt8(ascii: "S"), UInt8(ascii: "C")
    ]
    static let currentVersion: UInt32 = 1
    static let headerSize: Int = 32
    static let indexEntrySize: Int = 8
}

// MARK: - Reader

/// Sequentially decodes frames from a `.tgsc` cache file produced by
/// `TGSAnimatedStickerCacheWriter`. Conforms to `TGSAnimatedStickerFrameSource` so
/// it can drop into the existing `TGSPlayerView` pipeline without any other change.
///
/// Threading: a single instance is not thread-safe (it owns a mutable
/// `previousFrameBuffer` that every `takeFrame` mutates). Callers must serialize
/// access — exactly the contract `TGSPlayerView`'s per-view `workQueue` already
/// provides, identical to how `TGSAnimatedStickerDirectFrameSource` is used.
public final class TGSAnimatedStickerCachedFrameSource: TGSAnimatedStickerFrameSource {
    public let frameRate: Int
    public let frameCount: Int
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    /// mmap'd cache file. Holding the `Data` keeps the mapping alive for the lifetime
    /// of the source; LZFSE reads pointers directly out of this memory.
    private let mappedFile: Data
    private let frameOffsets: [(offset: Int, compressedSize: Int)]
    private let byteCount: Int

    /// The most recently decoded frame, kept around so the next frame's XOR delta
    /// can be applied on top of it. Owned by the source, freed in `deinit`.
    private let previousFrameBuffer: UnsafeMutableRawPointer

    private var currentFrame: Int = 0

    public var frameIndex: Int {
        currentFrame % frameCount
    }

    public init(cachePath: String) throws {
        let url = URL(fileURLWithPath: cachePath)
        guard let mapped = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw TGSPlayerError.cachedSourceInvalid
        }
        self.mappedFile = mapped

        // -- Header --
        guard mapped.count >= TGSCachedFrameFormat.headerSize else {
            throw TGSPlayerError.cachedSourceInvalid
        }
        let prefix = mapped.prefix(4)
        guard [UInt8](prefix) == TGSCachedFrameFormat.magicBytes else {
            throw TGSPlayerError.cachedSourceInvalid
        }
        let version = readU32LE(from: mapped, at: 4)
        guard version == TGSCachedFrameFormat.currentVersion else {
            throw TGSPlayerError.cachedSourceInvalid
        }
        let width = Int(readU32LE(from: mapped, at: 8))
        let height = Int(readU32LE(from: mapped, at: 12))
        let bytesPerRow = Int(readU32LE(from: mapped, at: 16))
        let frameRate = Int(readU32LE(from: mapped, at: 20))
        let frameCount = Int(readU32LE(from: mapped, at: 24))

        // Bounds sanity. These are the same constraints the rest of the player
        // assumes (positive dims, row stride wide enough for RGBA, at least 1 frame
        // at >= 1 fps). Tighter caps live in the native bridge.
        guard width > 0, height > 0,
              bytesPerRow >= width * 4,
              frameRate > 0, frameCount > 0 else {
            throw TGSPlayerError.cachedSourceInvalid
        }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.byteCount = bytesPerRow * height

        // -- Index table --
        let indexTableSize = frameCount * TGSCachedFrameFormat.indexEntrySize
        let dataAreaStart = TGSCachedFrameFormat.headerSize + indexTableSize
        guard mapped.count >= dataAreaStart else {
            throw TGSPlayerError.cachedSourceInvalid
        }
        var offsets: [(offset: Int, compressedSize: Int)] = []
        offsets.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let entryBase = TGSCachedFrameFormat.headerSize + i * TGSCachedFrameFormat.indexEntrySize
            let offset = Int(readU32LE(from: mapped, at: entryBase))
            let size = Int(readU32LE(from: mapped, at: entryBase + 4))
            // Each frame must point inside the file's data region.
            guard offset >= dataAreaStart,
                  size > 0,
                  offset.addingReportingOverflow(size).overflow == false,
                  offset + size <= mapped.count else {
                throw TGSPlayerError.cachedSourceInvalid
            }
            offsets.append((offset: offset, compressedSize: size))
        }
        self.frameOffsets = offsets

        // -- Frame buffer --
        // 16-byte alignment matches what we ask of `rlottie` and lets the compiler
        // generate aligned NEON loads/stores for the XOR loop.
        self.previousFrameBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 16
        )
        memset(previousFrameBuffer, 0, byteCount)
    }

    deinit {
        previousFrameBuffer.deallocate()
    }

    public func takeFrame(draw: Bool) -> TGSAnimatedStickerFrame? {
        let index = currentFrame % frameCount
        currentFrame += 1

        // When we wrap (or start fresh), the XOR base is zeros so frame 0's
        // delta against zero is the raw frame.
        if index == 0 {
            memset(previousFrameBuffer, 0, byteCount)
        }

        // Even when the caller asks `draw: false` (missed-tick skip path) we still
        // need to decode, because `previousFrameBuffer` must be kept in sync — the
        // next real draw's delta will XOR against it. The decode is ~50 µs vs.
        // ~3 ms for a rlottie render, so skipping in this mode is still cheap.
        guard let frameBuffer = decodeFrameApplyingDelta(at: index) else {
            return nil
        }

        if !draw {
            frameBuffer.deallocate()
            return nil
        }

        let data = Data(
            bytesNoCopy: frameBuffer,
            count: byteCount,
            deallocator: .custom { pointer, _ in
                pointer.deallocate()
            }
        )
        return TGSAnimatedStickerFrame(
            data: data,
            type: .argb,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            index: index,
            isLastFrame: index == frameCount - 1,
            totalFrames: frameCount
        )
    }

    public func skipToEnd() {
        skipToFrameIndex(frameCount - 1)
    }

    /// Replays decoding from frame 0 (or from the current cursor when seeking forward)
    /// up to the frame *before* `index`, so the next `takeFrame` lands exactly on
    /// `index` with a correct `previousFrameBuffer`.
    ///
    /// This is O(distance) in LZFSE decompresses. For typical TGS stickers (≤ 90 frames)
    /// a full replay is sub-millisecond, and the operation is rare (manual seek; loop
    /// wrap is handled cheaply by the `index == 0` zero-reset above without needing
    /// a replay).
    public func skipToFrameIndex(_ index: Int) {
        guard frameCount > 0 else { return }
        let target = ((index % frameCount) + frameCount) % frameCount

        let cursor = currentFrame % frameCount
        if cursor == target {
            return
        }

        // For backward seek (or wrap-around), restart state from zeros and replay
        // from 0. For forward seek inside the current loop, only replay the gap.
        if target < cursor {
            memset(previousFrameBuffer, 0, byteCount)
            currentFrame = 0
        }
        // Sequentially apply deltas without producing output, just to update state.
        while currentFrame % frameCount != target {
            let idx = currentFrame % frameCount
            currentFrame += 1
            if idx == 0 {
                memset(previousFrameBuffer, 0, byteCount)
            }
            guard let buffer = decodeFrameApplyingDelta(at: idx) else {
                // Corrupt frame mid-replay: stop here. The next real draw will likely
                // also fail and the caller can decide how to recover.
                return
            }
            buffer.deallocate()
        }
    }

    // MARK: - Private

    /// LZFSE-decompresses the delta blob at `index`, XOR's it into
    /// `previousFrameBuffer`, and returns a freshly allocated buffer holding the
    /// reconstructed frame. The caller owns and must `.deallocate()` the result
    /// (or wrap it in a `Data(bytesNoCopy:)` with a deallocator that does).
    ///
    /// `previousFrameBuffer` is updated in-place to hold the same bytes as the
    /// returned buffer, ready for the next frame's delta to XOR against.
    private func decodeFrameApplyingDelta(at index: Int) -> UnsafeMutableRawPointer? {
        let entry = frameOffsets[index]
        let outBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: 16
        )

        let decompressedSize = mappedFile.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            let src = base.advanced(by: entry.offset).assumingMemoryBound(to: UInt8.self)
            return compression_decode_buffer(
                outBuffer.assumingMemoryBound(to: UInt8.self), byteCount,
                src, entry.compressedSize,
                nil,
                COMPRESSION_LZFSE
            )
        }
        guard decompressedSize == byteCount else {
            outBuffer.deallocate()
            return nil
        }

        // Combined "compute current frame + update previousFrameBuffer" loop.
        // Reading both inputs and writing both outputs in the same iteration keeps
        // the working set in cache and lets the compiler vectorize the XOR over
        // 8-byte chunks (`byteCount = bytesPerRow * height` is RGBA so it's
        // always divisible by 4, and any reasonable sticker size by 8).
        let outU64 = outBuffer.assumingMemoryBound(to: UInt64.self)
        let prevU64 = previousFrameBuffer.assumingMemoryBound(to: UInt64.self)
        let u64Count = byteCount / 8
        for i in 0..<u64Count {
            let reconstructed = outU64[i] ^ prevU64[i]
            outU64[i] = reconstructed
            prevU64[i] = reconstructed
        }
        let tailStart = u64Count * 8
        if tailStart < byteCount {
            let outU8 = outBuffer.assumingMemoryBound(to: UInt8.self)
            let prevU8 = previousFrameBuffer.assumingMemoryBound(to: UInt8.self)
            for i in tailStart..<byteCount {
                let reconstructed = outU8[i] ^ prevU8[i]
                outU8[i] = reconstructed
                prevU8[i] = reconstructed
            }
        }

        return outBuffer
    }
}

// MARK: - Writer

/// Renders every frame from `source`, XOR-delta-encodes them against the previous
/// frame, LZFSE-compresses each delta, and writes the result to disk in the format
/// described at the top of this file.
///
/// The writer is single-shot and stateless; it is safe to call from any background
/// thread (typically a one-off setup step before the first time a sticker is played).
public struct TGSAnimatedStickerCacheWriter {
    public init() {}

    /// Writes a `.tgsc` cache file at `url`. Atomic via `Data.write(to:options:.atomic)` —
    /// the system performs a tmp-write + rename under the hood, so a partial write
    /// can never be picked up by the reader.
    ///
    /// The whole encoded cache is assembled in memory first. Sticker caches are small
    /// (typical 96x96 30-frame sticker is well under 1 MB on disk), so the savings
    /// from streaming directly to a `FileHandle` aren't worth the iOS-13.0 API gymnastics
    /// `FileHandle.write(contentsOf:)` would require (only available iOS 13.4+).
    ///
    /// Pass a *fresh* source (one that has not yet emitted any frames). The writer
    /// rewinds it to frame 0 before reading, so a source mid-playback will work but
    /// has its playback cursor reset as a side effect.
    public static func write(
        source: TGSAnimatedStickerFrameSource,
        to url: URL
    ) throws {
        let frameCount = source.frameCount
        let frameRate = source.frameRate
        guard frameCount > 0, frameRate > 0 else {
            throw TGSPlayerError.cachedSourceProducedNoFrames
        }

        source.skipToFrameIndex(0)

        // We need the first frame to learn dimensions. The writer accepts any
        // `TGSAnimatedStickerFrameSource`, so we can't query dimensions up front
        // from the protocol — we discover them from the first emitted frame.
        guard let firstFrame = source.takeFrame(draw: true), firstFrame.type == .argb else {
            throw TGSPlayerError.cachedSourceProducedNoFrames
        }
        let width = firstFrame.width
        let height = firstFrame.height
        let bytesPerRow = firstFrame.bytesPerRow
        let byteCount = bytesPerRow * height
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            throw TGSPlayerError.cachedSourceProducedNoFrames
        }

        let previousBuffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        memset(previousBuffer, 0, byteCount)
        let deltaBuffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        // LZFSE worst-case for incompressible data is ~src_size + a few hundred bytes.
        // Our deltas are extremely compressible (mostly zeros), so this is plenty.
        let compressedCapacity = byteCount + 1024
        let compressedBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: compressedCapacity)
        defer {
            previousBuffer.deallocate()
            deltaBuffer.deallocate()
            compressedBuffer.deallocate()
        }

        // Pre-size the output buffer. Header + index table sizes are exact; for the
        // payload we estimate ~1/3 of raw frame bytes (XOR delta + LZFSE typically
        // compresses to that). Worst case we just resize on the fly — Data grows
        // amortized.
        let indexTableSize = frameCount * TGSCachedFrameFormat.indexEntrySize
        let prefixSize = TGSCachedFrameFormat.headerSize + indexTableSize
        var payload = Data()
        payload.reserveCapacity(prefixSize + (byteCount * frameCount) / 3)

        var offsets: [(offset: UInt32, size: UInt32)] = []
        offsets.reserveCapacity(frameCount)
        var cursor: UInt32 = UInt32(prefixSize)

        let encodeFrame: (TGSAnimatedStickerFrame) throws -> Void = { frame in
            guard frame.type == .argb,
                  frame.width == width,
                  frame.height == height,
                  frame.bytesPerRow == bytesPerRow,
                  frame.data.count >= byteCount else {
                throw TGSPlayerError.cachedSourceProducedNoFrames
            }

            // Compute delta = frame XOR previous, and update previous = frame in
            // the same pass. Same vectorized layout as the reader's XOR loop.
            frame.data.withUnsafeBytes { rawBuffer in
                guard let framePtr = rawBuffer.baseAddress else { return }
                let frameU64 = framePtr.assumingMemoryBound(to: UInt64.self)
                let prevU64 = previousBuffer.assumingMemoryBound(to: UInt64.self)
                let deltaU64 = deltaBuffer.assumingMemoryBound(to: UInt64.self)
                let u64Count = byteCount / 8
                for i in 0..<u64Count {
                    let f = frameU64[i]
                    deltaU64[i] = f ^ prevU64[i]
                    prevU64[i] = f
                }
                let tailStart = u64Count * 8
                if tailStart < byteCount {
                    let frameU8 = framePtr.assumingMemoryBound(to: UInt8.self)
                    let prevU8 = previousBuffer.assumingMemoryBound(to: UInt8.self)
                    let deltaU8 = deltaBuffer.assumingMemoryBound(to: UInt8.self)
                    for i in tailStart..<byteCount {
                        let f = frameU8[i]
                        deltaU8[i] = f ^ prevU8[i]
                        prevU8[i] = f
                    }
                }
            }

            let written = compression_encode_buffer(
                compressedBuffer, compressedCapacity,
                deltaBuffer.assumingMemoryBound(to: UInt8.self), byteCount,
                nil,
                COMPRESSION_LZFSE
            )
            guard written > 0 else {
                throw TGSPlayerError.cachedWriteFailed
            }
            payload.append(compressedBuffer, count: written)
            offsets.append((offset: cursor, size: UInt32(written)))
            cursor = cursor &+ UInt32(written)
        }

        try encodeFrame(firstFrame)
        for _ in 1..<frameCount {
            guard let frame = source.takeFrame(draw: true) else {
                throw TGSPlayerError.cachedSourceProducedNoFrames
            }
            try encodeFrame(frame)
        }

        // -- Header + index table --
        var prefix = Data()
        prefix.reserveCapacity(prefixSize)
        prefix.append(contentsOf: TGSCachedFrameFormat.magicBytes)
        appendU32LE(TGSCachedFrameFormat.currentVersion, to: &prefix)
        appendU32LE(UInt32(width), to: &prefix)
        appendU32LE(UInt32(height), to: &prefix)
        appendU32LE(UInt32(bytesPerRow), to: &prefix)
        appendU32LE(UInt32(frameRate), to: &prefix)
        appendU32LE(UInt32(frameCount), to: &prefix)
        appendU32LE(0, to: &prefix)
        for entry in offsets {
            appendU32LE(entry.offset, to: &prefix)
            appendU32LE(entry.size, to: &prefix)
        }
        prefix.append(payload)

        do {
            try prefix.write(to: url, options: [.atomic])
        } catch {
            throw TGSPlayerError.cachedWriteFailed
        }
    }
}

// MARK: - Endian helpers

@inline(__always)
private func appendU32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

@inline(__always)
private func readU32LE(from data: Data, at offset: Int) -> UInt32 {
    return data.withUnsafeBytes { rawBuffer -> UInt32 in
        let base = rawBuffer.baseAddress!.advanced(by: offset)
        // The cache file may be unaligned for UInt32; `load(fromByteOffset:as:)`
        // requires alignment, so do an explicit byte-by-byte load.
        let b0 = UInt32(base.load(fromByteOffset: 0, as: UInt8.self))
        let b1 = UInt32(base.load(fromByteOffset: 1, as: UInt8.self))
        let b2 = UInt32(base.load(fromByteOffset: 2, as: UInt8.self))
        let b3 = UInt32(base.load(fromByteOffset: 3, as: UInt8.self))
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
