#if canImport(UIKit)
import QuartzCore
import UIKit
import os

/// A process-wide, vsync-aligned playback scheduler for `TGSPlayerView`.
///
/// Replaces N independent `DispatchSourceTimer`s (one per visible sticker view) with a
/// single `CADisplayLink` that fans render work back out to each view's `workQueue`.
/// The win in a long sticker list is twofold:
///
///   1. **Phase alignment.** Per-view dispatch-source timers drift against the display
///      clock; with 60+ active views their `layer.contents` writes commit at random
///      phases inside the 16.67ms vsync window, occasionally crowding into the same
///      few main-RunLoop iterations and forcing Core Animation to do back-to-back tree
///      commits. A CADisplayLink fires exactly once per vsync, so every view's frame
///      can be applied inside a *single* `CATransaction.setDisableActions(true)` per
///      vsync — one tree commit instead of N.
///
///   2. **Idle cost.** When no view is registered the link auto-pauses, so a screen
///      with no visible stickers spends *zero* main-thread cycles on playback.
///
/// The coordinator never owns rendering itself: each view keeps its own serial
/// `workQueue` (which targets the concurrent `renderPool`), so renders for different
/// views still run in parallel. The coordinator only decides *when* to ask a view for
/// its next frame and *when* to commit the result.
///
/// Threading contract:
///   - All methods on this class are main-thread-only unless documented otherwise.
///   - `ViewEntry.submitPendingCommit(_:)` may be called from any background queue.
///   - The view's worker writes the next frame into its `ViewEntry`'s pending slot;
///     the coordinator drains that slot at the head of the *next* vsync.
internal final class TGSPlaybackCoordinator {
    internal static let shared = TGSPlaybackCoordinator()

    /// One entry per registered view. Lifetime is owned by `entries`; the view also
    /// keeps a strong reference returned from `register(_:frameRate:)` so worker code
    /// can submit pending commits without round-tripping through main-thread lookups.
    internal final class ViewEntry {
        weak var view: TGSPlayerView?
        // Main-thread only.
        var frameInterval: CFTimeInterval
        var nextFireTimestamp: CFTimeInterval
        /// True between the moment we dispatch a render to the view's workQueue and the
        /// vsync at which we apply the resulting commit. Prevents tick pile-up when the
        /// renderer falls behind (long lists, thermal throttling).
        var inFlight: Bool

        // Worker → main handoff. Protected by `pendingLock`.
        private let pendingLock: UnsafeMutablePointer<os_unfair_lock>
        private var pendingCommit: PendingCommit?

        struct PendingCommit {
            let cgImage: CGImage?
            let frameIndex: Int
            let totalFrames: Int
            let isLast: Bool
            let frameRate: Int
            /// Setup generation captured by the view when this commit was rendered.
            /// Lets `applyCoordinatedCommit` drop the frame if the view was reset in
            /// between rendering and vsync.
            let generation: UInt64
        }

        init(view: TGSPlayerView, frameInterval: CFTimeInterval) {
            self.view = view
            self.frameInterval = frameInterval
            self.nextFireTimestamp = 0
            self.inFlight = false
            self.pendingLock = UnsafeMutablePointer.allocate(capacity: 1)
            self.pendingLock.initialize(to: os_unfair_lock())
        }

        deinit {
            pendingLock.deinitialize(count: 1)
            pendingLock.deallocate()
        }

        /// Called from the view's workQueue.
        func submitPendingCommit(_ commit: PendingCommit) {
            os_unfair_lock_lock(pendingLock)
            pendingCommit = commit
            os_unfair_lock_unlock(pendingLock)
        }

        /// Called from main thread inside `handleVsync`.
        fileprivate func takePendingCommit() -> PendingCommit? {
            os_unfair_lock_lock(pendingLock)
            defer { os_unfair_lock_unlock(pendingLock) }
            let snapshot = pendingCommit
            pendingCommit = nil
            return snapshot
        }
    }

    private var entries: [ObjectIdentifier: ViewEntry] = [:]
    private var displayLink: CADisplayLink?

    private init() {}

    // MARK: - Registration (main thread)

    /// Register `view` for vsync-driven playback. Returns the entry to be stored on the view;
    /// the view's worker uses it to publish rendered frames.
    @discardableResult
    func register(_ view: TGSPlayerView, frameRate: Int) -> ViewEntry {
        dispatchPrecondition(condition: .onQueue(.main))
        let id = ObjectIdentifier(view)
        let interval = 1.0 / Double(max(1, frameRate))
        if let entry = entries[id] {
            // A previously paused view re-registering — refresh schedule without
            // creating a new entry so any in-flight worker still references a live entry.
            entry.frameInterval = interval
            entry.nextFireTimestamp = 0
            entry.inFlight = false
            ensureDisplayLinkRunning()
            return entry
        }
        let entry = ViewEntry(view: view, frameInterval: interval)
        entries[id] = entry
        ensureDisplayLinkRunning()
        return entry
    }

    func unregister(_ view: TGSPlayerView) {
        dispatchPrecondition(condition: .onQueue(.main))
        entries.removeValue(forKey: ObjectIdentifier(view))
        if entries.isEmpty {
            displayLink?.isPaused = true
        }
    }

    // MARK: - CADisplayLink

    private func ensureDisplayLinkRunning() {
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(handleVsync(_:)))
            if #available(iOS 15.0, *) {
                // Track the display's preferred refresh range — on a 120Hz ProMotion
                // device we'll tick at 120Hz, on a low-power Mac at 60Hz, and we can
                // gracefully fall back to 30Hz under thermal pressure.
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 30,
                    maximum: 120,
                    preferred: 60
                )
            } else {
                link.preferredFramesPerSecond = 60
            }
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func handleVsync(_ link: CADisplayLink) {
        let now = link.timestamp

        // Phase A — apply: drain every entry's pending commit into a single
        // CATransaction so Core Animation does one tree commit for the whole grid.
        // Touching `entries` returns a dictionary view; capture keys in a snapshot so
        // we can mutate (deadEntries) without invalidating iteration.
        var deadEntries: [ObjectIdentifier] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, entry) in entries {
            guard let view = entry.view else {
                deadEntries.append(id)
                continue
            }
            if let commit = entry.takePendingCommit() {
                view.applyCoordinatedCommit(commit)
                entry.inFlight = false
            }
        }
        CATransaction.commit()

        for id in deadEntries {
            entries.removeValue(forKey: id)
        }

        // Phase B — dispatch: for every entry that's due and not already rendering,
        // kick off the next frame on the view's workQueue. The result lands in the
        // entry's pending slot and is committed at the next vsync (Phase A above).
        for (_, entry) in entries {
            guard let view = entry.view else { continue }
            guard !entry.inFlight else { continue }

            if entry.nextFireTimestamp == 0 {
                entry.nextFireTimestamp = now
            }
            // 0.5ms slop avoids missing a tick when `now` lands a hair before the
            // scheduled fire because of host clock granularity.
            guard now + 0.0005 >= entry.nextFireTimestamp else { continue }

            // Catch up on any whole intervals we missed without re-rendering each one.
            let delta = now - entry.nextFireTimestamp
            let missed = max(0, Int(delta / entry.frameInterval))
            entry.inFlight = true
            view.dispatchCoordinatedTick(skipFrames: missed, entry: entry)
            entry.nextFireTimestamp += entry.frameInterval * Double(missed + 1)
        }

        if entries.isEmpty {
            link.isPaused = true
        }
    }
}
#endif
