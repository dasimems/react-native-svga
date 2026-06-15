import CoreGraphics
import QuartzCore
import UIKit

/// SVGA renderer.
///
/// Rendering model — GPU compositing via a CALayer tree (NOT `draw(rect:)`):
/// every sprite gets its own `CALayer` whose `contents` is the sprite's
/// pre-decoded `CGImage`, set ONCE when the entity is installed. Per frame we
/// only mutate each sublayer's `transform` / `opacity` / `isHidden` — a handful
/// of float writes that Core Animation composites on the GPU. The expensive
/// part (rasterizing pixels) never touches the CPU or the main thread after the
/// initial texture upload.
///
/// This replaces an earlier `UIView.draw(rect:)` + `UIGraphicsGetCurrentContext`
/// implementation, which was pure Quartz software rasterization on the main
/// thread: every frame it allocated a view-sized (full-screen, at retina scale)
/// bitmap, CPU-drew every sprite into it, and re-uploaded it. For a long-running,
/// full-screen, looping animation that pegged the CPU and heated the SoC until
/// iOS thermally throttled the whole app. Android never had this because
/// `View.onDraw`'s canvas is hardware-accelerated — this brings iOS to parity.
///
/// Geometry: every sprite layer (and the math below) uses `anchorPoint = (0,0)`
/// and `position = (0,0)`. With those, a CALayer's `transform` acts as a pure
/// linear map from the layer's local space to the superlayer's — i.e. it
/// behaves exactly like a `CGContext` CTM concatenation, so the affine math
/// matches the old Core Graphics path 1:1. Image orientation is handled by
/// Core Animation (contents draw upright, top-left origin), so the per-image
/// y-flip the old `draw(rect:)` needed is gone.
internal final class SvgaPlayerView: UIView {

    typealias FrameHandler = (Int, Bool) -> Void
    typealias LoopHandler = (Int) -> Void
    typealias FinishHandler = () -> Void
    typealias WindowVisibilityHandler = (Bool) -> Void

    var entity: SvgaEntity? {
        didSet {
            reset()
            hasRendered = false
            // Always invalidate the prior link on entity assignment. The
            // common path (start → pause/stop → start) already handles this,
            // but a direct entity swap that doesn't go through pause()/start()
            // would otherwise leave the old link ticking against the new
            // entity's state. Subsequent `start()` will create a fresh one.
            // SvgaEntity is a struct so we can't cheaply test identity;
            // unconditionally invalidating is fine — it's idempotent and
            // cheap.
            displayLink?.invalidate()
            displayLink = nil
            isPlaying = false
            // Tear down the old sprite layers and build one per sprite for the
            // new entity (textures uploaded here, once). Then show frame 0 so a
            // freshly-installed-but-not-yet-playing entity is visible, matching
            // the old `setNeedsDisplay()` behaviour.
            rebuildLayers()
            updateOuterTransform()
            applyFrame(currentFrame)
        }
    }

    var scaleMode: ScaleMode = .aspectfit {
        didSet {
            updateOuterTransform()
            applyFrame(currentFrame)
        }
    }
    var maxLoops: Int = 0
    var frameInterval: TimeInterval = 1.0 / 15.0

    var onFrame: FrameHandler?
    var onLoop: LoopHandler?
    var onFinish: FinishHandler?
    var onWindowVisibilityChange: WindowVisibilityHandler?

    private(set) var isPlaying: Bool = false

    private var currentFrame: Int = 0
    private var loopCount: Int = 0
    private var hasRendered: Bool = false
    private var displayLink: CADisplayLink?
    private var lastTickAt: CFTimeInterval = 0

    /// One layer per `movie.sprites` entry, in source (z) order. Parallel to
    /// `entity.movie.sprites` — index i here renders sprite i.
    private var spriteLayers: [CALayer] = []
    /// viewBox → view-space map (the aspect-fit/fill scale + centering). Baked
    /// into each sprite's per-frame transform; recomputed on layout/scaleMode
    /// change, not per frame.
    private var outerTransform: CGAffineTransform = .identity

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.isGeometryFlipped = false
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowVisibilityChange?(window != nil)
    }

    // The outer transform depends on our bounds (aspect-fit/fill centering), so
    // recompute whenever the host resizes us — including the first real layout
    // pass after an entity is installed while bounds were still zero. Re-apply
    // the current frame so the new mapping takes effect even while paused.
    override func layoutSubviews() {
        super.layoutSubviews()
        updateOuterTransform()
        applyFrame(currentFrame)
    }

    func start() {
        if isPlaying { return }
        if entity == nil { return }
        isPlaying = true
        lastTickAt = CACurrentMediaTime()
        if !hasRendered {
            hasRendered = true
            onFrame?(currentFrame, false)
            applyFrame(currentFrame)
        }
        // Defensive: if a previous start() left a link attached (e.g. an
        // entity swap that didn't go through pause()), invalidate it before
        // overwriting the property — otherwise the old link stays on the
        // run loop forever ticking against this view.
        displayLink?.invalidate()
        displayLink = nil
        let link = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.tick))
        let targetFps = max(1, Int(round(1.0 / max(frameInterval, 0.001))))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(min(30, targetFps)),
                maximum: Float(targetFps),
                preferred: Float(targetFps)
            )
        } else {
            link.preferredFramesPerSecond = targetFps
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        if !isPlaying { return }
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
    }

    func stop() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        reset()
        applyFrame(currentFrame)
    }

    func seekToFrame(_ frame: Int) {
        guard let total = entity?.movie.frames, total > 0 else { return }
        currentFrame = max(0, min(total - 1, frame))
        if isPlaying { onFrame?(currentFrame, false) }
        applyFrame(currentFrame)
    }

    func release() {
        displayLink?.invalidate()
        displayLink = nil
        isPlaying = false
    }

    @objc fileprivate func onDisplayTick(_ link: CADisplayLink) {
        let now = link.timestamp
        if now - lastTickAt < frameInterval { return }
        lastTickAt = now
        advance()
    }

    /// Recompute the viewBox → view-space map from the current bounds and
    /// scaleMode. Cheap; safe to call when there's no entity (identity).
    private func updateOuterTransform() {
        guard let movie = entity?.movie else {
            outerTransform = .identity
            return
        }
        let scale = ScaleCalc.compute(
            mode: scaleMode,
            viewWidth: bounds.width,
            viewHeight: bounds.height,
            contentWidth: movie.viewBoxWidth,
            contentHeight: movie.viewBoxHeight
        )
        // Order mirrors the old CTM exactly: a content point is mapped by the
        // sprite's frame transform first, THEN scaled, THEN translated. The
        // (scale → translate) tail is `ScaleResult.transform`; the frame
        // transform is pre-multiplied per sprite in `applyFrame`.
        outerTransform = scale.transform
    }

    /// Discard the current sprite layers and build a fresh one per sprite for
    /// the installed entity. Each layer's `contents` (the decoded CGImage) is
    /// assigned once here — the only texture upload in the whole render loop.
    private func rebuildLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in spriteLayers { l.removeFromSuperlayer() }
        spriteLayers.removeAll(keepingCapacity: true)
        if let e = entity {
            for sprite in e.movie.sprites {
                let l = CALayer()
                l.anchorPoint = .zero
                l.position = .zero
                l.contentsGravity = .resize
                l.allowsEdgeAntialiasing = true
                // Start hidden; applyFrame reveals only the sprites whose
                // current frame has content.
                l.isHidden = true
                if let img = e.images[sprite.imageKey] {
                    l.contents = img
                    // Bounds in the image's pixel units (treated as points in
                    // local space) — the per-frame affine, which already carries
                    // the bitmap→layout scale from `composeTransforms`, sizes it.
                    l.bounds = CGRect(x: 0, y: 0, width: CGFloat(img.width), height: CGFloat(img.height))
                }
                layer.addSublayer(l)
                spriteLayers.append(l)
            }
        }
        CATransaction.commit()
    }

    /// Push frame `index` to the layer tree: for each sprite, set visibility,
    /// opacity, and the composed affine (frame transform → outer transform).
    /// Wrapped in a no-implicit-animation transaction so each frame is a hard
    /// cut, not a quarter-second tween — without this every property change
    /// would animate, smearing frames and adding compositor work.
    private func applyFrame(_ index: Int) {
        guard let movie = entity?.movie, movie.frames > 0 else { return }
        // Defensive: layers and sprites must stay in lockstep. If a rebuild is
        // mid-flight (shouldn't happen on main, but cheap to guard), skip.
        if spriteLayers.count != movie.sprites.count { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, sprite) in movie.sprites.enumerated() {
            let l = spriteLayers[i]
            let frames = sprite.frames
            // Sprite shorter than the timeline, no content this frame, fully
            // transparent, or no image → nothing to show.
            if index < 0 || index >= frames.count || l.contents == nil {
                l.isHidden = true
                continue
            }
            let frame = frames[index]
            if !frame.hasContent || frame.alpha <= 0 {
                l.isHidden = true
                continue
            }
            l.isHidden = false
            l.opacity = Float(frame.alpha)
            // frame.transform first, then the viewBox→view map — matches the
            // old `concatenate(frame.transform)` after the CTM scale/translate.
            l.setAffineTransform(frame.transform.concatenating(outerTransform))
        }
        CATransaction.commit()
    }

    private func reset() {
        currentFrame = 0
        loopCount = 0
        hasRendered = false
    }

    private func advance() {
        guard let movie = entity?.movie else { return }
        let total = movie.frames
        if total <= 0 { return }

        let next = currentFrame + 1
        let isLast = next >= total
        if isLast {
            currentFrame = 0
            if loopCount < Int.max { loopCount += 1 }
            onLoop?(loopCount)
            if maxLoops > 0 && loopCount >= maxLoops {
                isPlaying = false
                displayLink?.invalidate()
                displayLink = nil
                applyFrame(currentFrame)
                onFinish?()
                return
            }
        } else {
            currentFrame = next
        }

        onFrame?(currentFrame, isLast)
        applyFrame(currentFrame)
    }
}

private final class WeakProxy {
    weak var target: SvgaPlayerView?
    init(_ target: SvgaPlayerView) { self.target = target }
    @objc func tick(_ link: CADisplayLink) { target?.onDisplayTick(link) }
}
