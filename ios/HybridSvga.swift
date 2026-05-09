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
    private var wasPlayingBeforeWindowGone = false
    private let defaultFps = 15
    private let minSpeed: Double = 0.05

    var view: UIView { playerView }

    var source: String = "" {
        didSet {
            if source == oldValue { return }
            handleSource(source)
        }
    }

    var loops: Double = 0 {
        didSet { playerView.maxLoops = max(0, Int(loops)) }
    }

    var autoPlay: Bool = true

    var speed: Double = 1 {
        didSet {
            applySpeed()
            audio.setRate(Float(speed))
        }
    }

    var muteBuiltInAudio: Bool = false {
        didSet { audio.setMuted(muteBuiltInAudio) }
    }

    var builtInAudioVolume: Double = 1 {
        didSet { audio.setVolume(Float(builtInAudioVolume)) }
    }

    var playInBackground: Bool = false

    var scaleMode: ScaleMode = .aspectfit {
        didSet { playerView.scaleMode = scaleMode }
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
        if entityRef == nil {
            pendingPlayOnLoad = true
            return
        }
        let wasIdle = !playerView.isPlaying
        playerView.start()
        audio.resumeAll()
        if wasIdle { onStart?() }
    }

    func pause() throws {
        playerView.pause()
        audio.pauseAll()
    }

    func stop() throws {
        playerView.stop()
        audio.stopAll()
    }

    func seekToFrame(frame: Double) throws {
        playerView.seekToFrame(Int(frame))
    }

    func seekToProgress(progress: Double) throws {
        guard let total = entityRef?.movie.frames else { return }
        let clamped = max(0, min(1, progress))
        playerView.seekToFrame(Int(clamped * Double(total)))
    }

    func isPlaying() throws -> Bool { playerView.isPlaying }

    deinit {
        playerView.release()
        audio.release()
    }

    private func handleSource(_ value: String) {
        if let previous = activeSource, previous != value {
            SvgaSourceLoader.cancelLoad(previous)
        }
        loadToken += 1
        let token = loadToken
        if value.isEmpty {
            activeSource = nil
            entityRef = nil
            playerView.stop()
            playerView.entity = nil
            audio.stopAll()
            return
        }
        activeSource = value
        SvgaSourceLoader.loadEntity(value) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if token != self.loadToken { return }
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
