import CoreGraphics
import QuartzCore
import UIKit

internal final class SvgaPlayerView: UIView {

    typealias FrameHandler = (Int, Bool) -> Void
    typealias LoopHandler = (Int) -> Void
    typealias FinishHandler = () -> Void
    typealias WindowVisibilityHandler = (Bool) -> Void

    var entity: SvgaEntity? {
        didSet {
            reset()
            hasRendered = false
            setNeedsDisplay()
        }
    }

    var scaleMode: ScaleMode = .aspectfit { didSet { setNeedsDisplay() } }
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        layer.isGeometryFlipped = false
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowVisibilityChange?(window != nil)
    }

    func start() {
        if isPlaying { return }
        if entity == nil { return }
        isPlaying = true
        lastTickAt = CACurrentMediaTime()
        if !hasRendered {
            hasRendered = true
            onFrame?(currentFrame, false)
            setNeedsDisplay()
        }
        let link = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.tick))
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
        setNeedsDisplay()
    }

    func seekToFrame(_ frame: Int) {
        guard let total = entity?.movie.frames, total > 0 else { return }
        currentFrame = max(0, min(total - 1, frame))
        if isPlaying { onFrame?(currentFrame, false) }
        setNeedsDisplay()
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

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard let e = entity else { return }
        let movie = e.movie
        if movie.frames <= 0 { return }

        let scale = ScaleCalc.compute(
            mode: scaleMode,
            viewWidth: bounds.width,
            viewHeight: bounds.height,
            contentWidth: movie.viewBoxWidth,
            contentHeight: movie.viewBoxHeight
        )

        ctx.saveGState()
        ctx.translateBy(x: scale.translateX, y: scale.translateY)
        ctx.scaleBy(x: scale.scaleX, y: scale.scaleY)

        for sprite in movie.sprites {
            drawSprite(ctx: ctx, sprite: sprite, entity: e)
        }
        ctx.restoreGState()
    }

    private func drawSprite(ctx: CGContext, sprite: SpriteEntity, entity: SvgaEntity) {
        let frames = sprite.frames
        if currentFrame >= frames.count { return }
        let frame = frames[currentFrame]
        if !frame.hasContent || frame.alpha <= 0 { return }
        guard let image = entity.images[sprite.imageKey] else { return }
        let bw = CGFloat(image.width)
        let bh = CGFloat(image.height)
        if bw <= 0 || bh <= 0 { return }

        ctx.saveGState()
        ctx.setAlpha(frame.alpha)
        ctx.concatenate(frame.transform)
        ctx.translateBy(x: 0, y: bh)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: bw, height: bh))
        ctx.restoreGState()
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
            loopCount += 1
            onLoop?(loopCount)
            if maxLoops > 0 && loopCount >= maxLoops {
                isPlaying = false
                displayLink?.invalidate()
                displayLink = nil
                setNeedsDisplay()
                onFinish?()
                return
            }
        } else {
            currentFrame = next
        }

        onFrame?(currentFrame, isLast)
        setNeedsDisplay()
    }
}

private final class WeakProxy {
    weak var target: SvgaPlayerView?
    init(_ target: SvgaPlayerView) { self.target = target }
    @objc func tick(_ link: CADisplayLink) { target?.onDisplayTick(link) }
}
