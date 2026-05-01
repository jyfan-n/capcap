import AppKit

// MARK: - Annotation Protocol

protocol Annotation {
    func draw(in context: CGContext, bounds: NSRect)

    /// True when the point is on (or close enough to) this annotation that
    /// the user can grab it for moving. For stroke-based shapes this is the
    /// stroke band only — the interior is intentionally transparent so the
    /// user can click through to whatever is behind.
    func containsPoint(_ point: NSPoint) -> Bool

    /// Returns a copy of this annotation translated by `delta`. Used while
    /// the user drags an existing annotation.
    func translated(by delta: NSPoint) -> Annotation

    /// Axis-aligned bounding box used for selection handles and rotation
    /// pivots. Computed in canvas coordinates.
    var boundingRect: NSRect { get }

    /// Current rotation angle in radians, applied around `boundingRect` mid.
    var rotation: CGFloat { get }

    /// Whether rotating this annotation has a visible effect. Pen / marker /
    /// mosaic strokes opt out — their geometry already encodes their shape.
    var supportsRotation: Bool { get }

    /// Returns a copy with the given rotation. Default impl is a no-op for
    /// types that don't support rotation.
    func withRotation(_ rotation: CGFloat) -> Annotation
}

extension Annotation {
    var rotation: CGFloat { 0 }
    var supportsRotation: Bool { false }
    func withRotation(_ rotation: CGFloat) -> Annotation { self }

    /// Wraps `draw` with the rotation transform if the annotation has any.
    /// All draw methods are written in unrotated coordinates; this helper is
    /// the single place rotation is applied.
    func drawApplyingTransforms(in context: CGContext, bounds: NSRect) {
        guard rotation != 0, supportsRotation else {
            draw(in: context, bounds: bounds)
            return
        }
        let center = NSPoint(x: boundingRect.midX, y: boundingRect.midY)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: rotation)
        context.translateBy(x: -center.x, y: -center.y)
        draw(in: context, bounds: bounds)
        context.restoreGState()
    }

    /// Map a canvas-space point back into the annotation's unrotated frame
    /// so existing hit tests can ignore rotation entirely.
    func unrotate(_ point: NSPoint) -> NSPoint {
        guard rotation != 0, supportsRotation else { return point }
        let c = NSPoint(x: boundingRect.midX, y: boundingRect.midY)
        let dx = point.x - c.x
        let dy = point.y - c.y
        let cosR = cos(-rotation)
        let sinR = sin(-rotation)
        return NSPoint(
            x: c.x + dx * cosR - dy * sinR,
            y: c.y + dx * sinR + dy * cosR
        )
    }
}

private let strokeHitTolerance: CGFloat = 8

private func strokedPathContains(_ path: CGPath, point: NSPoint, lineWidth: CGFloat) -> Bool {
    let width = max(strokeHitTolerance, lineWidth + 4)
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return stroked.contains(point)
}

// MARK: - Pen Annotation

struct PenAnnotation: Annotation {
    let path: NSBezierPath
    let color: NSColor
    let lineWidth: CGFloat
    var rotation: CGFloat = 0

    var boundingRect: NSRect {
        path.bounds.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
    }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        color.setStroke()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        return strokedPathContains(path.cgPath, point: p, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        let copy = path.copy() as! NSBezierPath
        var transform = AffineTransform.identity
        transform.translate(x: delta.x, y: delta.y)
        copy.transform(using: transform)
        return PenAnnotation(path: copy, color: color, lineWidth: lineWidth, rotation: rotation)
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }
}

// MARK: - Marker (Highlighter) Annotation

/// Highlighter — a pen stroke painted with a semi-transparent fat brush so it
/// reads as if drawn over text with a real marker. Unlike the pen, the brush
/// width scales as `lineWidth × 6` and self-overlapping segments are drawn
/// inside a transparency layer so the alpha doesn't compound at junctions.
struct MarkerAnnotation: Annotation {
    let path: NSBezierPath
    /// User-picked color; alpha is applied at draw time.
    let color: NSColor
    /// Base width — multiplied by `MarkerAnnotation.brushScale` when drawn.
    let lineWidth: CGFloat
    var rotation: CGFloat = 0

    static let brushScale: CGFloat = 6
    static let markerAlpha: CGFloat = 0.35

    var boundingRect: NSRect {
        let inset = -lineWidth * MarkerAnnotation.brushScale / 2
        return path.bounds.insetBy(dx: inset, dy: inset)
    }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let stroke = color.withAlphaComponent(1.0)
        stroke.setStroke()
        path.lineWidth = lineWidth * MarkerAnnotation.brushScale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // Paint into a transparency layer at full alpha then flatten the
        // entire layer at marker alpha so overlapping passes don't darken.
        context.setAlpha(MarkerAnnotation.markerAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        path.stroke()
        context.endTransparencyLayer()
        context.setAlpha(1.0)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let effectiveWidth = lineWidth * MarkerAnnotation.brushScale
        return strokedPathContains(path.cgPath, point: p, lineWidth: effectiveWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        let copy = path.copy() as! NSBezierPath
        var transform = AffineTransform.identity
        transform.translate(x: delta.x, y: delta.y)
        copy.transform(using: transform)
        return MarkerAnnotation(path: copy, color: color, lineWidth: lineWidth, rotation: rotation)
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }
}

// MARK: - Mosaic Annotation

struct MosaicAnnotation: Annotation {
    let rect: NSRect
    let pixelatedImage: NSImage

    var boundingRect: NSRect { rect }

    func draw(in context: CGContext, bounds: NSRect) {
        pixelatedImage.draw(in: rect)
    }

    // Mosaic is treated as "pasted on" — once placed it can't be dragged.
    func containsPoint(_ point: NSPoint) -> Bool { false }
    func translated(by delta: NSPoint) -> Annotation { self }
}

// MARK: - Rectangle Annotation

struct RectAnnotation: Annotation {
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat
    var rotation: CGFloat = 0

    var boundingRect: NSRect { rect }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let path = CGPath(rect: rect, transform: nil)
        return strokedPathContains(path, point: p, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        var copy = self
        copy = RectAnnotation(
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            color: color,
            lineWidth: lineWidth,
            rotation: rotation
        )
        return copy
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }
}

// MARK: - Ellipse Annotation

struct EllipseAnnotation: Annotation {
    let rect: NSRect
    let color: NSColor
    let lineWidth: CGFloat
    var rotation: CGFloat = 0

    var boundingRect: NSRect { rect }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        let path = CGPath(ellipseIn: rect, transform: nil)
        return strokedPathContains(path, point: p, lineWidth: lineWidth)
    }

    func translated(by delta: NSPoint) -> Annotation {
        EllipseAnnotation(
            rect: rect.offsetBy(dx: delta.x, dy: delta.y),
            color: color,
            lineWidth: lineWidth,
            rotation: rotation
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }
}

// MARK: - Arrow Annotation

struct ArrowAnnotation: Annotation {
    let startPoint: NSPoint
    let endPoint: NSPoint
    let color: NSColor
    let lineWidth: CGFloat
    /// Optional curve handle. When set, the shaft is drawn as a quadratic
    /// bezier through `controlPoint` and the arrowhead orientation follows
    /// the tangent at the end of the curve. nil = straight arrow.
    var controlPoint: NSPoint? = nil

    var boundingRect: NSRect {
        var minX = min(startPoint.x, endPoint.x)
        var minY = min(startPoint.y, endPoint.y)
        var maxX = max(startPoint.x, endPoint.x)
        var maxY = max(startPoint.y, endPoint.y)
        if let cp = controlPoint {
            minX = min(minX, cp.x); maxX = max(maxX, cp.x)
            minY = min(minY, cp.y); maxY = max(maxY, cp.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Default visual midpoint when no controlPoint is set — the geometric
    /// mid of start/end. Used to anchor the curve handle in adjust mode.
    var defaultCurveMid: NSPoint {
        NSPoint(
            x: (startPoint.x + endPoint.x) / 2,
            y: (startPoint.y + endPoint.y) / 2
        )
    }

    /// Position where the curve handle is rendered: the controlPoint when
    /// set, otherwise the geometric midpoint.
    var curveHandlePoint: NSPoint {
        controlPoint ?? defaultCurveMid
    }

    func draw(in context: CGContext, bounds: NSRect) {
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        let endTangent: (dx: CGFloat, dy: CGFloat)

        if let cp = controlPoint {
            // Quadratic bezier through controlPoint
            context.move(to: startPoint)
            context.addQuadCurve(to: endPoint, control: cp)
            context.strokePath()
            endTangent = (endPoint.x - cp.x, endPoint.y - cp.y)
        } else {
            context.move(to: startPoint)
            context.addLine(to: endPoint)
            context.strokePath()
            endTangent = (endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        }

        // Arrowhead — direction follows the local tangent at the endpoint
        let length = sqrt(endTangent.dx * endTangent.dx + endTangent.dy * endTangent.dy)
        guard length > 0 else { return }

        let headLength: CGFloat = max(12, lineWidth * 4)
        let headWidth: CGFloat = max(8, lineWidth * 3)

        let unitX = endTangent.dx / length
        let unitY = endTangent.dy / length

        let baseX = endPoint.x - unitX * headLength
        let baseY = endPoint.y - unitY * headLength

        let leftX = baseX - unitY * headWidth / 2
        let leftY = baseY + unitX * headWidth / 2
        let rightX = baseX + unitY * headWidth / 2
        let rightY = baseY - unitX * headWidth / 2

        context.move(to: endPoint)
        context.addLine(to: CGPoint(x: leftX, y: leftY))
        context.addLine(to: CGPoint(x: rightX, y: rightY))
        context.closePath()
        context.fillPath()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let line = CGMutablePath()
        if let cp = controlPoint {
            line.move(to: startPoint)
            line.addQuadCurve(to: endPoint, control: cp)
        } else {
            line.move(to: startPoint)
            line.addLine(to: endPoint)
        }
        if strokedPathContains(line, point: point, lineWidth: lineWidth) {
            return true
        }

        // Filled arrowhead — direction follows tangent at endPoint.
        let endTangent: (dx: CGFloat, dy: CGFloat)
        if let cp = controlPoint {
            endTangent = (endPoint.x - cp.x, endPoint.y - cp.y)
        } else {
            endTangent = (endPoint.x - startPoint.x, endPoint.y - startPoint.y)
        }
        let length = sqrt(endTangent.dx * endTangent.dx + endTangent.dy * endTangent.dy)
        guard length > 0 else { return false }

        let headLength: CGFloat = max(12, lineWidth * 4)
        let headWidth: CGFloat = max(8, lineWidth * 3)
        let unitX = endTangent.dx / length
        let unitY = endTangent.dy / length
        let baseX = endPoint.x - unitX * headLength
        let baseY = endPoint.y - unitY * headLength

        let head = CGMutablePath()
        head.move(to: endPoint)
        head.addLine(to: CGPoint(x: baseX - unitY * headWidth / 2, y: baseY + unitX * headWidth / 2))
        head.addLine(to: CGPoint(x: baseX + unitY * headWidth / 2, y: baseY - unitX * headWidth / 2))
        head.closeSubpath()
        return head.contains(point)
    }

    func translated(by delta: NSPoint) -> Annotation {
        let translatedCP: NSPoint? = controlPoint.map {
            NSPoint(x: $0.x + delta.x, y: $0.y + delta.y)
        }
        return ArrowAnnotation(
            startPoint: NSPoint(x: startPoint.x + delta.x, y: startPoint.y + delta.y),
            endPoint: NSPoint(x: endPoint.x + delta.x, y: endPoint.y + delta.y),
            color: color,
            lineWidth: lineWidth,
            controlPoint: translatedCP
        )
    }

    /// Adjust-mode helper: replace (or clear) the curve control point.
    func withControlPoint(_ cp: NSPoint?) -> ArrowAnnotation {
        var copy = self
        copy.controlPoint = cp
        return copy
    }
}

// MARK: - Text Annotation

struct TextAnnotation: Annotation {
    let text: String
    /// Bottom-left of the editing/drawing frame, in canvas coordinates.
    let origin: NSPoint
    let color: NSColor
    let fontSize: CGFloat
    var rotation: CGFloat = 0

    static let trailingCaretPadding: CGFloat = 12
    static let minimumEditorWidth: CGFloat = 32

    static func font(forSize size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .bold)
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func editorSize(for text: String, font: NSFont) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textToMeasure = text.isEmpty ? "M" : text
        let measured = (textToMeasure as NSString).size(withAttributes: attrs)
        return NSSize(
            width: max(ceil(measured.width) + trailingCaretPadding, minimumEditorWidth),
            height: lineHeight(for: font)
        )
    }

    /// Editing-frame bounds of the rendered text, used for hit-testing.
    ///
    /// This intentionally mirrors `EditableTextField.sizeToFitText()` instead
    /// of using only the bare glyph size, so a committed text mark can be
    /// double-clicked anywhere in the same region the user just edited.
    var textBounds: NSRect {
        let size = TextAnnotation.editorSize(for: text, font: TextAnnotation.font(forSize: fontSize))
        return NSRect(origin: origin, size: size)
    }

    var hitBounds: NSRect {
        textBounds.insetBy(dx: -10, dy: -max(10, fontSize * 0.75))
    }

    var boundingRect: NSRect { textBounds }
    var supportsRotation: Bool { true }

    func draw(in context: CGContext, bounds: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: TextAnnotation.font(forSize: fontSize)
        ]
        NSGraphicsContext.saveGraphicsState()
        text.draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        let p = unrotate(point)
        return hitBounds.contains(p)
    }

    func translated(by delta: NSPoint) -> Annotation {
        TextAnnotation(
            text: text,
            origin: NSPoint(x: origin.x + delta.x, y: origin.y + delta.y),
            color: color,
            fontSize: fontSize,
            rotation: rotation
        )
    }

    func withRotation(_ rotation: CGFloat) -> Annotation {
        var copy = self
        copy.rotation = rotation
        return copy
    }
}

// MARK: - Number Annotation

struct NumberAnnotation: Annotation {
    let center: NSPoint
    /// Optional arrow tip pointing away from the badge. `nil` (or a tip
    /// inside the badge) draws the badge alone. Otherwise an arrow is drawn
    /// from the badge's edge out to `tip`. Set during creation by drag, and
    /// adjustable later via the tip handle in adjust mode.
    var tip: NSPoint?
    /// Optional curve handle. When set together with `tip`, the shaft is
    /// drawn as a quadratic bezier through `controlPoint` and the
    /// arrowhead orientation follows the tangent at the tip. nil = straight
    /// shaft.
    var controlPoint: NSPoint? = nil
    let number: Int
    let color: NSColor

    static let radius: CGFloat = 14
    /// Below this distance from `center` we treat the tip as "no arrow" so
    /// the head won't sit on top of the badge glyph.
    static let arrowMinDistance: CGFloat = NumberAnnotation.radius + 6

    var hasArrow: Bool {
        guard let tip else { return false }
        return hypot(tip.x - center.x, tip.y - center.y) >= NumberAnnotation.arrowMinDistance
    }

    var circleRect: NSRect {
        NSRect(
            x: center.x - NumberAnnotation.radius,
            y: center.y - NumberAnnotation.radius,
            width: NumberAnnotation.radius * 2,
            height: NumberAnnotation.radius * 2
        )
    }

    var boundingRect: NSRect {
        guard hasArrow, let tip else { return circleRect }
        var rect = circleRect.union(NSRect(x: tip.x, y: tip.y, width: 0, height: 0))
        if let cp = controlPoint {
            rect = rect.union(NSRect(x: cp.x, y: cp.y, width: 0, height: 0))
        }
        return rect
    }

    /// Default curve handle position when no `controlPoint` is set — the
    /// midpoint of the shaft (badge center to tip) so a fresh straight
    /// arrow still surfaces a grabbable bend point.
    var defaultCurveMid: NSPoint? {
        guard hasArrow, let tip else { return nil }
        return NSPoint(
            x: (center.x + tip.x) / 2,
            y: (center.y + tip.y) / 2
        )
    }

    /// Position where the curve handle is rendered: the controlPoint when
    /// set, otherwise the visual midpoint. nil when there's no arrow.
    var curveHandlePoint: NSPoint? {
        controlPoint ?? defaultCurveMid
    }

    func draw(in context: CGContext, bounds: NSRect) {
        // Arrow shaft + head from badge center to tip (drawn first so the
        // badge sits on top and hides the part of the shaft inside the
        // circle — visually the arrow emerges from the badge's edge while
        // geometrically the bezier starts from the center).
        if hasArrow, let tip {
            let shaftWidth: CGFloat = 3
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(shaftWidth)
            context.setLineCap(.round)

            let endTangent: (dx: CGFloat, dy: CGFloat)
            if let cp = controlPoint {
                context.move(to: center)
                context.addQuadCurve(to: tip, control: cp)
                context.strokePath()
                endTangent = (tip.x - cp.x, tip.y - cp.y)
            } else {
                context.move(to: center)
                context.addLine(to: tip)
                context.strokePath()
                endTangent = (tip.x - center.x, tip.y - center.y)
            }

            // Arrowhead — direction follows the local tangent at the tip.
            let tlen = hypot(endTangent.dx, endTangent.dy)
            if tlen > 0 {
                let unitX = endTangent.dx / tlen
                let unitY = endTangent.dy / tlen
                let headLength: CGFloat = max(10, shaftWidth * 4)
                let headWidth: CGFloat = max(7, shaftWidth * 3)
                let baseX = tip.x - unitX * headLength
                let baseY = tip.y - unitY * headLength
                context.move(to: tip)
                context.addLine(to: CGPoint(x: baseX - unitY * headWidth / 2, y: baseY + unitX * headWidth / 2))
                context.addLine(to: CGPoint(x: baseX + unitY * headWidth / 2, y: baseY - unitX * headWidth / 2))
                context.closePath()
                context.fillPath()
            }
        }

        // Filled badge circle
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circleRect)

        // Badge number — always drawn upright (no rotation).
        let text = "\(number)"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .bold)
        ]
        let size = text.size(withAttributes: attrs)
        let textOrigin = NSPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        NSGraphicsContext.saveGraphicsState()
        text.draw(at: textOrigin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    func containsPoint(_ point: NSPoint) -> Bool {
        // Badge hit
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r = NumberAnnotation.radius
        if dx * dx + dy * dy <= r * r {
            return true
        }
        // Arrow shaft hit (only when an arrow is actually drawn).
        if hasArrow, let tip {
            let line = CGMutablePath()
            line.move(to: center)
            if let cp = controlPoint {
                line.addQuadCurve(to: tip, control: cp)
            } else {
                line.addLine(to: tip)
            }
            return strokedPathContains(line, point: point, lineWidth: 4)
        }
        return false
    }

    func translated(by delta: NSPoint) -> Annotation {
        NumberAnnotation(
            center: NSPoint(x: center.x + delta.x, y: center.y + delta.y),
            tip: tip.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
            controlPoint: controlPoint.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) },
            number: number,
            color: color
        )
    }

    /// Adjust-mode helper: replace (or clear) the arrow tip. Clearing the
    /// tip also drops the curve control point — there's no shaft for it
    /// to bend.
    func withTip(_ tip: NSPoint?) -> NumberAnnotation {
        var copy = self
        copy.tip = tip
        if tip == nil {
            copy.controlPoint = nil
        }
        return copy
    }

    /// Adjust-mode helper: replace (or clear) the curve control point.
    func withControlPoint(_ cp: NSPoint?) -> NumberAnnotation {
        var copy = self
        copy.controlPoint = cp
        return copy
    }
}
