import Foundation
import zlib

public struct TGSDecoderLimits: Equatable {
    public var maxCompressedBytes: Int
    public var maxDecodedBytes: Int

    public init(
        maxCompressedBytes: Int = 256 * 1024,
        maxDecodedBytes: Int = 2 * 1024 * 1024
    ) {
        self.maxCompressedBytes = maxCompressedBytes
        self.maxDecodedBytes = maxDecodedBytes
    }
}

public struct TGSDecoder {
    public var limits: TGSDecoderLimits

    public init(limits: TGSDecoderLimits = TGSDecoderLimits()) {
        self.limits = limits
    }

    public func decode(_ data: Data) throws -> Data {
        guard data.count <= limits.maxCompressedBytes else {
            throw TGSPlayerError.sourceTooLarge
        }

        if Self.looksLikeJSON(data) {
            guard data.count <= limits.maxDecodedBytes else {
                throw TGSPlayerError.decodedJSONTooLarge
            }
            return data
        }

        guard Self.hasGzipHeader(data) else {
            throw TGSPlayerError.gzipDecodeFailed
        }

        let decoded = try Self.gunzip(data, maxDecodedBytes: limits.maxDecodedBytes)
        guard Self.looksLikeJSON(decoded) else {
            throw TGSPlayerError.invalidLottieJSON
        }
        return decoded
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { !$0.isASCIIWhitespace }) else {
            return false
        }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    private static func hasGzipHeader(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0x1f && data[1] == 0x8b
    }

    private static func gunzip(_ data: Data, maxDecodedBytes: Int) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw TGSPlayerError.gzipDecodeFailed
        }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { rawBuffer in
            guard let input = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw TGSPlayerError.gzipDecodeFailed
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input)
            stream.avail_in = uInt(data.count)

            let chunkSize = 16 * 1024
            let outputBuffer = UnsafeMutablePointer<Bytef>.allocate(capacity: chunkSize)
            defer { outputBuffer.deallocate() }

            var output = Data()
            // gzip-compressed Lottie JSON typically expands ~6–10× (lots of repeated keys
            // and floats). Reserving 4× up front gets us through most stickers in a single
            // allocation instead of the 7+ amortized reallocations Data.append would do.
            let initialCapacity = min(maxDecodedBytes, max(chunkSize, data.count * 4))
            output.reserveCapacity(initialCapacity)

            while true {
                stream.next_out = outputBuffer
                stream.avail_out = uInt(chunkSize)

                let status = inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw TGSPlayerError.gzipDecodeFailed
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    guard output.count + produced <= maxDecodedBytes else {
                        throw TGSPlayerError.decodedJSONTooLarge
                    }
                    output.append(outputBuffer, count: produced)
                }

                if status == Z_STREAM_END {
                    return output
                }

                if produced == 0 && stream.avail_in == 0 {
                    throw TGSPlayerError.gzipDecodeFailed
                }
            }
        }
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool {
        self == UInt8(ascii: " ")
            || self == UInt8(ascii: "\n")
            || self == UInt8(ascii: "\r")
            || self == UInt8(ascii: "\t")
    }
}
