import CoreGraphics

internal struct ScaleResult {
    let scaleX: CGFloat
    let scaleY: CGFloat
    let translateX: CGFloat
    let translateY: CGFloat

    /// The viewBox → view-space affine: a content point is scaled, then
    /// translated (centering offset). `a.concatenating(b)` applies `a` then
    /// `b`, so this is scale-then-translate. The renderer pre-multiplies each
    /// sprite's frame transform onto this (`frame.transform.concatenating(.)`),
    /// reproducing the old `draw(rect:)` CTM order exactly. Kept here as the
    /// single source of truth so `SvgaPlayerView` and its tests agree.
    var transform: CGAffineTransform {
        return CGAffineTransform(scaleX: scaleX, y: scaleY)
            .concatenating(CGAffineTransform(translationX: translateX, y: translateY))
    }
}

internal enum ScaleCalc {
    static func compute(
        mode: ScaleMode,
        viewWidth: CGFloat,
        viewHeight: CGFloat,
        contentWidth: CGFloat,
        contentHeight: CGFloat
    ) -> ScaleResult {
        if contentWidth <= 0 || contentHeight <= 0 {
            return ScaleResult(scaleX: 1, scaleY: 1, translateX: 0, translateY: 0)
        }
        if mode == .fill {
            return ScaleResult(
                scaleX: viewWidth / contentWidth,
                scaleY: viewHeight / contentHeight,
                translateX: 0,
                translateY: 0
            )
        }
        let sx = viewWidth / contentWidth
        let sy = viewHeight / contentHeight
        let scale: CGFloat
        switch mode {
        case .aspectfill: scale = max(sx, sy)
        default: scale = min(sx, sy)
        }
        let tx = (viewWidth - contentWidth * scale) / 2
        let ty = (viewHeight - contentHeight * scale) / 2
        return ScaleResult(scaleX: scale, scaleY: scale, translateX: tx, translateY: ty)
    }
}
