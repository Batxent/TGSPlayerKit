import Foundation

/// Background-side helper that turns a `.tgs` blob into a `.tgsc` cache file on disk.
///
/// This is the engine behind the "first play in `.cached` mode" path: when the player
/// view discovers no cache exists for `(stickerCacheKey, width, height)`, it falls back
/// to direct rlottie rendering for immediate playback AND fires off a generator job
/// that produces the cache file in the background. Once that job completes, every
/// subsequent play of the same sticker at the same size hits the fast (`~50 µs / frame`)
/// `TGSAnimatedStickerCachedFrameSource` path.
///
/// The generator is a process-wide singleton (via `.shared`) because the work it does
/// is shared across views: two cells in a list scrolling past the same sticker should
/// not each spawn their own rlottie render + LZFSE write of the same file. The
/// in-flight map deduplicates concurrent requests for the same destination path,
/// fanning the single generation result out to every waiting completion.
///
/// Cancellation removes a handler. If every handler cancels before the queued task
/// starts, that task is dropped so invisible/reused cells cannot build a long backlog
/// that competes with foreground first-frame rendering. Once generation has started we
/// still let it finish, because aborting halfway would waste work and leave no cache
/// file for the next play.
public final class TGSCachedFrameGenerator {
    /// Process-wide singleton. Sticker rendering is intrinsically a process-level
    /// concern — there's only one rlottie, one CPU pool, one filesystem cache dir.
    public static let shared = TGSCachedFrameGenerator()

    /// Generation runs serially. Cache writes are CPU + memory bandwidth heavy (a full
    /// frame-by-frame rlottie rasterization + LZFSE encode), and the foreground render
    /// pool needs that CPU for visible playback. Telegram iOS makes the same choice —
    /// a single background queue for cache generation is plenty given that each file
    /// finishes in ~100-500 ms for typical sticker counts.
    private let workQueue: DispatchQueue

    private let lock = NSLock()
    private var inFlight: [String: PendingTask] = [:]

    public init(
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.tgsplayerkit.cache-generator",
            qos: .utility
        )
    ) {
        self.workQueue = workQueue
    }

    /// Asynchronously produce a `.tgsc` cache file for `(cacheKey, width, height)`
    /// at `cachePath`, given the raw `.tgs` bytes and the loader to use.
    ///
    /// - If the file at `cachePath` already exists, `completion` fires immediately on
    ///   `completionQueue` with `.success(URL)` and no work is scheduled.
    /// - If another generation for the same `cachePath` is already in flight,
    ///   this call attaches to it; both completions fire with the same result.
    /// - Otherwise a new generation is enqueued on the shared background queue.
    ///
    /// The returned `TGSCancellable` unsubscribes this handler. If all handlers
    /// unsubscribe before this task starts, the queued generation is skipped.
    @discardableResult
    public func generate(
        tgsData: Data,
        cachePath: String,
        cacheKey: String,
        width: Int,
        height: Int,
        loader: TGSLottieAnimationLoading,
        completionQueue: DispatchQueue = .main,
        completion: @escaping (Result<URL, TGSPlayerError>) -> Void
    ) -> TGSCancellable {
        // Fast path: file already on disk. Don't bother locking or dispatching.
        if FileManager.default.fileExists(atPath: cachePath) {
            TGSDebugLog("cache-hit path=\(TGSDebugFileName(cachePath)) size=\(width)x\(height)")
            completionQueue.async {
                completion(.success(URL(fileURLWithPath: cachePath)))
            }
            return TGSNoopCancellable()
        }

        let handler = Handler(
            completionQueue: completionQueue,
            completion: completion
        )

        lock.lock()
        if let existing = inFlight[cachePath] {
            existing.attach(handler)
            let handlerCount = existing.handlerCount
            lock.unlock()
            TGSDebugLog("cache-attach path=\(TGSDebugFileName(cachePath)) size=\(width)x\(height) handlers=\(handlerCount)")
            return Token { [weak self] in
                self?.detach(handler, from: cachePath)
            }
        }
        let task = PendingTask()
        task.attach(handler)
        inFlight[cachePath] = task
        lock.unlock()
        TGSDebugLog("cache-enqueue path=\(TGSDebugFileName(cachePath)) size=\(width)x\(height) bytes=\(tgsData.count)")

        // Capture only POD + protocol values into the closure (no `self`-mutating
        // state) so cancellation of the originating call can't accidentally abort
        // the work mid-stream.
        workQueue.async { [weak self, weak task] in
            guard let self else { return }
            guard let task, self.markTaskStarted(task, cachePath: cachePath) else {
                TGSDebugLog("cache-start-skipped path=\(TGSDebugFileName(cachePath)) size=\(width)x\(height)")
                return
            }
            self.runGeneration(
                tgsData: tgsData,
                cachePath: cachePath,
                cacheKey: cacheKey,
                width: width,
                height: height,
                loader: loader
            )
        }
        return Token { [weak self] in
            self?.detach(handler, from: cachePath)
        }
    }

    // MARK: - Internals

    private func detach(_ handler: Handler, from cachePath: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let task = inFlight[cachePath] else { return }
        task.detach(handler)
        let handlerCount = task.handlerCount
        let shouldDrop = task.shouldDropBeforeStart
        TGSDebugLog("cache-cancel-handler path=\(TGSDebugFileName(cachePath)) handlers=\(handlerCount) dropBeforeStart=\(shouldDrop)")
        if shouldDrop {
            inFlight.removeValue(forKey: cachePath)
            TGSDebugLog("cache-drop-before-start path=\(TGSDebugFileName(cachePath))")
        }
    }

    private func markTaskStarted(_ task: PendingTask, cachePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight[cachePath] === task else { return false }
        guard task.markStartedIfObserved() else {
            inFlight.removeValue(forKey: cachePath)
            return false
        }
        TGSDebugLog("cache-start path=\(TGSDebugFileName(cachePath)) handlers=\(task.handlerCount)")
        return true
    }

    private func runGeneration(
        tgsData: Data,
        cachePath: String,
        cacheKey: String,
        width: Int,
        height: Int,
        loader: TGSLottieAnimationLoading
    ) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let result: Result<URL, TGSPlayerError>
        // The destination's parent dir might not exist yet on first run.
        let destURL = URL(fileURLWithPath: cachePath)
        _ = TGSCachedFramesPath.ensureDirectoryExists(destURL.deletingLastPathComponent())

        // Re-check existence under the lock-free fast path: another generator (or even
        // a previous run of *this* process before a crash) might have finished writing
        // between the entry to `generate` and now. Cheap to check; saves a redundant render.
        if FileManager.default.fileExists(atPath: cachePath) {
            result = .success(destURL)
        } else if let direct = TGSAnimatedStickerDirectFrameSource(
            data: tgsData,
            width: width,
            height: height,
            cacheKey: cacheKey,
            loader: loader
        ) {
            do {
                try TGSAnimatedStickerCacheWriter.write(source: direct, to: destURL)
                result = .success(destURL)
            } catch let error as TGSPlayerError {
                result = .failure(error)
            } catch {
                result = .failure(.cachedWriteFailed)
            }
        } else {
            result = .failure(.animationLoadFailed)
        }

        lock.lock()
        let task = inFlight.removeValue(forKey: cachePath)
        lock.unlock()
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        switch result {
        case .success:
            TGSDebugLog("cache-finish-success path=\(TGSDebugFileName(cachePath)) size=\(width)x\(height) elapsedMs=\(elapsedMs)")
        case let .failure(error):
            TGSDebugLog("cache-finish-failure path=\(TGSDebugFileName(cachePath)) size=\(width)x\(height) elapsedMs=\(elapsedMs) error=\(error)")
        }
        task?.fireAll(result)
    }
}

// MARK: - Private cooperative cancellation primitives

private final class Handler {
    let completionQueue: DispatchQueue
    let completion: (Result<URL, TGSPlayerError>) -> Void
    init(
        completionQueue: DispatchQueue,
        completion: @escaping (Result<URL, TGSPlayerError>) -> Void
    ) {
        self.completionQueue = completionQueue
        self.completion = completion
    }
}

private final class PendingTask {
    private let lock = NSLock()
    private var handlers: [Handler] = []
    private var started = false

    func attach(_ handler: Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers.append(handler)
    }

    func detach(_ handler: Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeAll { $0 === handler }
    }

    var shouldDropBeforeStart: Bool {
        lock.lock(); defer { lock.unlock() }
        return !started && handlers.isEmpty
    }

    var handlerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return handlers.count
    }

    func markStartedIfObserved() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !handlers.isEmpty else { return false }
        started = true
        return true
    }

    func fireAll(_ result: Result<URL, TGSPlayerError>) {
        lock.lock()
        let toFire = handlers
        handlers.removeAll()
        lock.unlock()
        for handler in toFire {
            handler.completionQueue.async {
                handler.completion(result)
            }
        }
    }
}

private final class Token: TGSCancellable {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var fired = false
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() {
        lock.lock()
        let shouldFire = !fired
        fired = true
        lock.unlock()
        if shouldFire { onCancel() }
    }
}
