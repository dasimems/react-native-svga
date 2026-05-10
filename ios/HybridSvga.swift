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
    private var activeLoadId: SvgaSourceLoader.LoadCallbackId = 0
    private var wasPlayingBeforeWindowGone = false
    private var userPaused = false
    private var disposed = false
    private let defaultFps = 15
    private let minSpeed: Double = 0.05

    var view: UIView { playerView }

    /// Run `work` on the main queue. Nitro can dispatch property setters and
    /// methods from any thread (the JS thread, in particular). UIKit access
    /// off-main asserts on iOS 16+, and the player view + audio engine both
    /// expect main-thread invariants — so we hop here once at every public
    /// entry point. If we're already on main, run synchronously to keep
    /// ordering with prior calls.
    private func runOnMain(_ work: @escaping () -> Void) {
        if disposed { return }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    var source: String = "" {
        didSet {
            if source == oldValue { return }
            let value = source
            runOnMain { [weak self] in self?.handleSource(value) }
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
        super.init()
        playerView.onFrame = { [weak self] frame, _ in
            self?.audio.onFrame(frame)
        }
        playerView.onLoop = { [weak self] count in
            self?.onLoop?(Double(count))
        }
        playerView.onFinish = { [weak self] in
            self?.audio.stopAll()
            self?.onFinish?()
        }
        playerView.onWindowVisibilityChange = { [weak self] visible in
            guard let self = self else { return }
            if self.playInBackground { return }
            if visible { self.handleWindowReturned() } else { self.handleWindowGone() }
        }
        audio.onAudioError = { [weak self] message in
            self?.onError?(message)
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
        if disposed { return }
        disposed = true
        let cleanup = { [self] in
            if let active = self.activeSource, self.activeLoadId != 0 {
                SvgaSourceLoader.cancelLoad(active, callbackId: self.activeLoadId)
                self.activeLoadId = 0
            }
            self.activeSource = nil
            self.playerView.release()
            self.audio.release()
        }
        if Thread.isMainThread { cleanup() } else { DispatchQueue.main.sync(execute: cleanup) }
    }

    deinit {
        dispose()
    }

    private func handleSource(_ value: String) {
        if let previous = activeSource, previous != value, activeLoadId != 0 {
            SvgaSourceLoader.cancelLoad(previous, callbackId: activeLoadId)
        }
        activeLoadId = 0
        loadToken += 1
        let token = loadToken
        pendingPlayOnLoad = false
        wasPlayingBeforeWindowGone = false
        userPaused = false
        if value.isEmpty {
            activeSource = nil
            entityRef = nil
            playerView.stop()
            playerView.entity = nil
            audio.stopAll()
            return
        }
        activeSource = value
        activeLoadId = SvgaSourceLoader.loadEntity(value) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if token != self.loadToken { return }
                self.activeLoadId = 0
                switch result {
                case .failure(let error):
                    self.onError?(error.localizedDescription)
                case .success(let entity):
                    self.applyEntity(entity)
                }
            }
        }
    }

    private func applyEntity(_ entity: SvgaEntity) {
        entityRef = entity
        playerView.entity = entity
        playerView.scaleMode = scaleMode
        applySpeed()
        audio.setMuted(muteBuiltInAudio)
        audio.setVolume(Float(builtInAudioVolume))
        audio.setRate(Float(speed))
        audio.load(entity)
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
