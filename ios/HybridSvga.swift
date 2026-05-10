import Foundation
import NitroModules
import UIKit

final class HybridSvga: HybridSvgaSpec {

    private let playerView = SvgaPlayerView()
    private let audio = SvgaAudioEngine()
    private var entityRef: SvgaEntity?
    private var pendingPlayOnLoad = false
    private var loadToken = 0
    private var activeSource: String?
    private var activeCacheKey: String?
    private var activeLoadId: SvgaSourceLoader.LoadCallbackId = 0
    private var wasPlayingBeforeWindowGone = false
    private var userPaused = false
    private var disposed = false
    private let defaultFps = 15
    private let minSpeed: Double = 0.05
    /// Bumped on every `source`/`cacheKey` change. The main-hop reload
    /// closure captures the generation it was scheduled under and bails if a
    /// later change has superseded it — so a single React commit that sets
    /// `source` AND `cacheKey` triggers exactly one reload (the second one),
    /// not two with the first cancelled mid-flight. Guarded by a tiny
    /// unfair-lock so setters from any Nitro thread can bump it without
    /// tearing on 32-bit reads — `os_unfair_lock` is the cheapest cross-
    /// platform primitive that doesn't require iOS 16's `OSAllocatedUnfairLock`.
    private var reloadGeneration: UInt64 = 0
    private let reloadGenerationLock = os_unfair_lock_t.allocate(capacity: 1)

    var view: UIView { playerView }

    /// Run `work` on the main queue. Nitro can dispatch property setters and
    /// methods from any thread (the JS thread, in particular). UIKit access
    /// off-main asserts on iOS 16+, and the player view + audio engine both
    /// expect main-thread invariants — so we hop here once at every public
    /// entry point. If we're already on main, run synchronously to keep
    /// ordering with prior calls.
    private func runOnMain(_ work: @escaping () -> Void) {
        if disposed { return }
        if Thread.isMainThread {
            // Re-check disposed inside main as well — disposed could flip
            // between our outer check and the closure body if something else
            // disposed us via main-thread re-entry.
            if disposed { return }
            work()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.disposed else { return }
                work()
            }
        }
    }

    var source: String = "" {
        didSet {
            if source == oldValue { return }
            scheduleReload()
        }
    }

    /// Empty string ≡ "no override" — falls back to `source`. When this
    /// changes (with the same source), we also re-fetch because the cache
    /// identity is what determines disk/memory hits.
    var cacheKey: String = "" {
        didSet {
            if cacheKey == oldValue { return }
            scheduleReload()
        }
    }

    /// Coalescing reload scheduler. React typically commits `source` and
    /// `cacheKey` as two consecutive Nitro property writes; without this,
    /// the first setter would dispatch a reload that the second immediately
    /// cancels and replaces. Each setter bumps `reloadGeneration` and
    /// schedules a main-hop carrying the generation it observed. On main,
    /// the hop only fires `handleSource` if its generation is still current.
    ///
    /// CRITICAL: we snapshot `source`/`cacheKey` INSIDE the lock when bumping
    /// the generation — Swift `String` is a multi-word value type and is
    /// NOT safe to read across threads while another thread is writing it.
    /// Reading these on main without a fence (as a previous version did)
    /// could yield a torn String and crash on retain. The snapshot pinned
    /// inside the lock travels into the runOnMain closure as a captured
    /// constant, which is safe — the surviving hop's snapshot reflects the
    /// LATEST `(source, cacheKey)` pair because each setter runs the lock
    /// after its own `field = value` assignment, and the highest-generation
    /// winner captured under the same lock observes both writes.
    private func scheduleReload() {
        os_unfair_lock_lock(reloadGenerationLock)
        reloadGeneration &+= 1
        let myGeneration = reloadGeneration
        let snapshotSource = source
        let snapshotKey = cacheKey
        os_unfair_lock_unlock(reloadGenerationLock)
        runOnMain { [weak self] in
            guard let self = self else { return }
            os_unfair_lock_lock(self.reloadGenerationLock)
            let current = self.reloadGeneration
            os_unfair_lock_unlock(self.reloadGenerationLock)
            if myGeneration != current { return }
            self.handleSource(snapshotSource, cacheKey: snapshotKey)
        }
    }

    var loops: Double = 0 {
        didSet {
            let value = loops
            runOnMain { [weak self] in self?.playerView.maxLoops = max(0, Int(value)) }
        }
    }

    var autoPlay: Bool = true

    var speed: Double = 1 {
        didSet {
            let value = speed
            runOnMain { [weak self] in
                guard let self = self else { return }
                self.applySpeed()
                self.audio.setRate(Float(value))
            }
        }
    }

    var muteBuiltInAudio: Bool = false {
        didSet {
            let value = muteBuiltInAudio
            runOnMain { [weak self] in self?.audio.setMuted(value) }
        }
    }

    var builtInAudioVolume: Double = 1 {
        didSet {
            let value = builtInAudioVolume
            runOnMain { [weak self] in self?.audio.setVolume(Float(value)) }
        }
    }

    var playInBackground: Bool = false

    var scaleMode: ScaleMode = .aspectfit {
        didSet {
            let value = scaleMode
            runOnMain { [weak self] in self?.playerView.scaleMode = value }
        }
    }

    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?
    var onLoop: ((_ count: Double) -> Void)?
    var onError: ((_ message: String) -> Void)?

    override init() {
        reloadGenerationLock.initialize(to: os_unfair_lock())
        super.init()
        // Every listener gates on `disposed` because they can fire after the
        // user-side `dispose()` has been issued but before the async cleanup
        // closure runs on main — we must not poke UIKit/audio in that window.
        playerView.onFrame = { [weak self] frame, _ in
            guard let self = self, !self.disposed else { return }
            self.audio.onFrame(frame)
        }
        playerView.onLoop = { [weak self] count in
            guard let self = self, !self.disposed else { return }
            self.onLoop?(Double(count))
        }
        playerView.onFinish = { [weak self] in
            guard let self = self, !self.disposed else { return }
            self.audio.stopAll()
            self.onFinish?()
        }
        playerView.onWindowVisibilityChange = { [weak self] visible in
            guard let self = self, !self.disposed else { return }
            if self.playInBackground { return }
            if visible { self.handleWindowReturned() } else { self.handleWindowGone() }
        }
        audio.onAudioError = { [weak self] message in
            guard let self = self, !self.disposed else { return }
            self.onError?(message)
        }
    }

    private func handleWindowGone() {
        wasPlayingBeforeWindowGone = playerView.isPlaying
        playerView.pause()
        audio.pauseAll()
    }

    private func handleWindowReturned() {
        if !wasPlayingBeforeWindowGone { return }
        wasPlayingBeforeWindowGone = false
        playerView.start()
        audio.resumeAll()
    }

    func play() throws {
        runOnMain { [weak self] in
            guard let self = self else { return }
            self.userPaused = false
            if self.entityRef == nil {
                self.pendingPlayOnLoad = true
                return
            }
            let wasIdle = !self.playerView.isPlaying
            self.playerView.start()
            self.audio.resumeAll()
            if wasIdle { self.onStart?() }
        }
    }

    func pause() throws {
        runOnMain { [weak self] in
            guard let self = self else { return }
            self.userPaused = true
            self.pendingPlayOnLoad = false
            self.wasPlayingBeforeWindowGone = false
            self.playerView.pause()
            self.audio.pauseAll()
        }
    }

    func stop() throws {
        runOnMain { [weak self] in
            guard let self = self else { return }
            self.pendingPlayOnLoad = false
            self.wasPlayingBeforeWindowGone = false
            self.userPaused = false
            self.playerView.stop()
            self.audio.stopAll()
        }
    }

    func seekToFrame(frame: Double) throws {
        runOnMain { [weak self] in self?.playerView.seekToFrame(Int(frame)) }
    }

    func seekToProgress(progress: Double) throws {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let total = self.entityRef?.movie.frames else { return }
            let clamped = max(0, min(1, progress))
            self.playerView.seekToFrame(Int(clamped * Double(total)))
        }
    }

    func isPlaying() throws -> Bool {
        // Synchronous return is required by the spec. UIView property reads
        // from off-main are tolerated by AppKit/UIKit for trivial-getter
        // properties (Bool/Int) and the alternative is blocking the JS
        // thread on a dispatch — accept the read race.
        if disposed { return false }
        return playerView.isPlaying
    }

    func dispose() {
        // JS-side eager cleanup. SvgaPlayer.tsx unmount calls this so we
        // don't wait for JS GC to reclaim the handle. Idempotent — also
        // safe to call from deinit if dispose was never invoked.
        //
        // Critical: do NOT use `DispatchQueue.main.sync` here. Nitro can
        // call dispose() on the JS thread while main is mid-bridge into JS
        // (e.g. invoking onError/onFinish), which would deadlock. Capture
        // local copies of the state we need so the async cleanup closure
        // doesn't depend on `self` being alive — that lets dispose() be
        // called safely from `deinit` too.
        if disposed { return }
        disposed = true
        let pv = playerView
        let au = audio
        let capturedSource = activeSource
        let capturedKey = activeCacheKey
        let capturedLoadId = activeLoadId
        activeSource = nil
        activeCacheKey = nil
        activeLoadId = 0
        // Bump loadToken so a load completion that lands between here and
        // cleanup running on main is dropped by its token check.
        loadToken &+= 1
        let cleanup: () -> Void = {
            if let active = capturedSource, capturedLoadId != 0 {
                SvgaSourceLoader.cancelLoad(active, cacheKey: capturedKey, callbackId: capturedLoadId)
            }
            pv.release()
            au.release()
        }
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async(execute: cleanup)
        }
    }

    deinit {
        dispose()
        reloadGenerationLock.deinitialize(count: 1)
        reloadGenerationLock.deallocate()
    }

    private func handleSource(_ value: String, cacheKey rawKey: String) {
        // Empty cacheKey means "no override" → fall back to the source URL.
        let resolvedKey: String? = rawKey.isEmpty ? nil : rawKey
        // Cancel any in-flight load for the previous identity. Either source
        // or cacheKey may have changed — both semantically mean "the prior
        // fetch is stale" — so we don't gate on which one moved.
        if let priorSource = activeSource, activeLoadId != 0 {
            SvgaSourceLoader.cancelLoad(priorSource, cacheKey: activeCacheKey, callbackId: activeLoadId)
        }
        activeLoadId = 0
        loadToken &+= 1
        let token = loadToken
        pendingPlayOnLoad = false
        wasPlayingBeforeWindowGone = false
        userPaused = false
        if value.isEmpty {
            activeSource = nil
            activeCacheKey = nil
            entityRef = nil
            playerView.stop()
            playerView.entity = nil
            // Tear down the prior load's audio tracks too. Without this
            // the previous SVGA's AVAudioPlayers stay in memory until the
            // next non-empty source loads (or dispose).
            audio.unloadAll()
            return
        }
        activeSource = value
        activeCacheKey = resolvedKey
        activeLoadId = SvgaSourceLoader.loadEntity(value, cacheKey: resolvedKey) { [weak self] result in
            // The loader fires this callback off-main (parse queue or URL
            // session). Decode audio here, BEFORE the main hop, so by the
            // time `applyEntity` runs and `play()` triggers `onFrame(0)`,
            // the AVAudioPlayer instances are prepared and play immediately
            // — without this the prior path used `decodeQueue.async` +
            // a separate main hop, leaving a 10-50ms window where video had
            // started but audio had not.
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    guard let self = self, !self.disposed else { return }
                    if token != self.loadToken { return }
                    self.activeLoadId = 0
                    self.onError?(error.localizedDescription)
                }
            case .success(let entity):
                let preparedAudio = SvgaAudioEngine.prepareTracks(entity)
                DispatchQueue.main.async {
                    guard let self = self, !self.disposed else { return }
                    if token != self.loadToken { return }
                    self.activeLoadId = 0
                    self.applyEntity(entity, preparedAudio: preparedAudio)
                }
            }
        }
    }

    private func applyEntity(_ entity: SvgaEntity, preparedAudio: [SvgaAudioEngine.PreparedTrack]) {
        entityRef = entity
        playerView.entity = entity
        playerView.scaleMode = scaleMode
        applySpeed()
        audio.setMuted(muteBuiltInAudio)
        audio.setVolume(Float(builtInAudioVolume))
        audio.setRate(Float(speed))
        audio.installTracks(preparedAudio)
        if userPaused {
            pendingPlayOnLoad = false
            return
        }
        if autoPlay || pendingPlayOnLoad {
            pendingPlayOnLoad = false
            try? play()
        }
    }

    private func applySpeed() {
        let fps = entityRef?.movie.fps ?? defaultFps
        let rate = max(minSpeed, speed)
        playerView.frameInterval = 1.0 / (Double(fps) * rate)
    }
}
