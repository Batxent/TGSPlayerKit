import CoreGraphics
import Foundation

public final class TGSFrameCache {
    public struct Key: Hashable {
        public let cacheKey: String
        public let frameIndex: Int
        public let pixelSize: CGSize

        public init(cacheKey: String, frameIndex: Int, pixelSize: CGSize) {
            self.cacheKey = cacheKey
            self.frameIndex = frameIndex
            self.pixelSize = pixelSize
        }

        public static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.cacheKey == rhs.cacheKey
                && lhs.frameIndex == rhs.frameIndex
                && lhs.pixelSize.width == rhs.pixelSize.width
                && lhs.pixelSize.height == rhs.pixelSize.height
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(cacheKey)
            hasher.combine(frameIndex)
            hasher.combine(pixelSize.width)
            hasher.combine(pixelSize.height)
        }
    }

    private let byteLimit: Int
    private var storage: [Key: Data] = [:]
    private var recency: [Key] = []
    private var totalBytes: Int = 0

    public init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    public func insert(_ data: Data, for key: Key) {
        removeValue(for: key)

        guard data.count <= byteLimit else {
            return
        }

        storage[key] = data
        recency.append(key)
        totalBytes += data.count
        evictIfNeeded()
    }

    public func value(for key: Key) -> Data? {
        guard let data = storage[key] else {
            return nil
        }
        markRecentlyUsed(key)
        return data
    }

    public func removeAll() {
        storage.removeAll()
        recency.removeAll()
        totalBytes = 0
    }

    private func removeValue(for key: Key) {
        guard let existing = storage.removeValue(forKey: key) else {
            return
        }
        totalBytes -= existing.count
        recency.removeAll { $0 == key }
    }

    private func markRecentlyUsed(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while totalBytes > byteLimit, let oldest = recency.first {
            removeValue(for: oldest)
        }
    }
}
