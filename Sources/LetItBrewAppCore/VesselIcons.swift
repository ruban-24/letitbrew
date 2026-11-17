import CoreGraphics
import Foundation

/// The beer mug, coffee cup, kettle and cauldron, ported from the approved
/// mockup's drawing onto the same 24×24 y-down canvas as `FlaskGeometry`, with
/// its round 1.8-unit stroke. Everything is drawn in `ink` except the
/// needs-you dot.
///
/// Each vessel draws one state from two facts: whether it is `filled` (awake
/// or needs-you) and, only while awake, the animation `step`. Needs-you is
/// filled and still, without the steam, puffs or bubbles that awake adds.
enum VesselIcons {
    /// Steps in one rise of steam, fizz or bubbles.
    static let awakeFrameCount = 8
    /// The kettle's two puffs are half a rise apart, so its loop repeats after
    /// half the steps.
    static let kettleAwakeFrameCount = awakeFrameCount / 2

    typealias Vessel = (_ context: CGContext, _ filled: Bool, _ step: Int?) -> Void

    static func draw(
        frameCount: Int,
        _ vessel: Vessel,
        in context: CGContext,
        state: BrewIconState,
        frame: Int,
        scale: CGFloat,
        ink: CGColor,
        dot: CGColor
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        context.setLineWidth(FlaskGeometry.strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let step = state == .awake
            ? ((frame % frameCount) + frameCount) % frameCount
            : nil
        vessel(context, state == .awake || state == .needsYou, step)

        switch state {
        case .paused: drawSlash(in: context)
        case .needsYou: drawDot(in: context, color: dot)
        case .idle, .awake: break
        }
    }

    // MARK: Vessels

    /// A straight mug with a rounded base and a handle on the right. Filled,
    /// it carries a half-tone head of foam; awake, fizz rises through the beer
    /// and the foam bobs.
    static func beerMug(_ context: CGContext, filled: Bool, step: Int?) {
        let side = CGMutablePath()
        side.move(to: CGPoint(x: 4, y: 7.5))
        side.addLine(to: CGPoint(x: 4, y: 18.5))
        side.addArc(tangent1End: CGPoint(x: 4, y: 21), tangent2End: CGPoint(x: 6.5, y: 21), radius: 2.5)
        side.addLine(to: CGPoint(x: 12.5, y: 21))
        side.addArc(tangent1End: CGPoint(x: 15, y: 21), tangent2End: CGPoint(x: 15, y: 18.5), radius: 2.5)
        side.addLine(to: CGPoint(x: 15, y: 7.5))

        if filled {
            let body = side.mutableCopy()!
            body.closeSubpath()
            fill(body, from: 10.4, in: context) {
                guard let step else { return }
                for (x, offset) in [(7.0, 0), (9.6, 5), (12.2, 2)] {
                    let t = phase(step, offset)
                    clearCircle(in: context, x: x, y: 19.6 - t * 8.4, radius: 0.75 + 0.2 * t)
                }
            }

            // One layer, so overlapping foam stays an even half tone.
            context.saveGState()
            context.setAlpha(0.5)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.fill(CGRect(x: 3.1, y: 7.5, width: 12.8, height: 2.9))
            for (index, x) in [6.2, 9.5, 12.8].enumerated() {
                let bob = step.map { sin(CGFloat($0) / CGFloat(awakeFrameCount) * 2 * .pi + CGFloat(index) * 2) * 0.35 } ?? 0
                context.fillEllipse(in: circle(x: x, y: 7.4 + bob, radius: 2.3))
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }

        context.addPath(side)
        context.strokePath()

        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: 15, y: 9.6))
        handle.addLine(to: CGPoint(x: 17.6, y: 9.6))
        handle.addArc(tangent1End: CGPoint(x: 20.2, y: 9.6), tangent2End: CGPoint(x: 20.2, y: 12.2), radius: 2.4)
        handle.addLine(to: CGPoint(x: 20.2, y: 15))
        handle.addArc(tangent1End: CGPoint(x: 20.2, y: 17.6), tangent2End: CGPoint(x: 17.6, y: 17.6), radius: 2.4)
        handle.addLine(to: CGPoint(x: 15, y: 17.6))
        context.addPath(handle)
        context.strokePath()
    }

    /// A cup on a saucer. Awake, three wisps of steam rise and fade above it.
    static func coffee(_ context: CGContext, filled: Bool, step: Int?) {
        let cup = CGMutablePath()
        cup.move(to: CGPoint(x: 4, y: 10))
        cup.addLine(to: CGPoint(x: 4, y: 16))
        cup.addArc(tangent1End: CGPoint(x: 4, y: 19.5), tangent2End: CGPoint(x: 7.5, y: 19.5), radius: 3.5)
        cup.addLine(to: CGPoint(x: 12.5, y: 19.5))
        cup.addArc(tangent1End: CGPoint(x: 16, y: 19.5), tangent2End: CGPoint(x: 16, y: 16), radius: 3.5)
        cup.addLine(to: CGPoint(x: 16, y: 10))
        cup.closeSubpath()

        if filled { fill(cup, from: 12.8, in: context) }

        if let step {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0.5, width: 24, height: 8.3))
            context.setLineWidth(1.4)
            for (x, offset) in [(6.9, 0), (10.0, 3), (13.1, 6)] {
                let t = phase(step, offset)
                let y = 10.6 - t * 5.2
                context.setAlpha(1 - t * 0.55)
                let wisp = CGMutablePath()
                wisp.move(to: CGPoint(x: x, y: y))
                wisp.addCurve(
                    to: CGPoint(x: x, y: y - 4.8),
                    control1: CGPoint(x: x + 1.5, y: y - 1.6),
                    control2: CGPoint(x: x - 1.5, y: y - 3.2)
                )
                context.addPath(wisp)
                context.strokePath()
            }
            context.restoreGState()
        }

        context.addPath(cup)
        context.strokePath()

        let handle = CGMutablePath()
        handle.addArc(center: CGPoint(x: 16, y: 13.6), radius: 2.6, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        context.addPath(handle)
        context.strokePath()

        strokeLine(in: context, from: CGPoint(x: 2.5, y: 22.2), to: CGPoint(x: 19.5, y: 22.2))
    }

    /// A tall oval kettle with a lid knob, a high arched handle and a spout on
    /// the left. Awake, two puffs drift up from the spout.
    static func kettle(_ context: CGContext, filled: Bool, step: Int?) {
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 5, y: 20.6))
        body.addCurve(to: CGPoint(x: 12, y: 8.8), control1: CGPoint(x: 3.3, y: 15), control2: CGPoint(x: 6, y: 8.8))
        body.addCurve(to: CGPoint(x: 19, y: 20.6), control1: CGPoint(x: 18, y: 8.8), control2: CGPoint(x: 20.7, y: 15))
        body.closeSubpath()

        if filled { fill(body, from: 14.4, in: context) }

        if let step {
            context.saveGState()
            context.setLineWidth(1.2)
            for offset in [0, 4] {
                let t = phase(step, offset)
                context.setAlpha(1 - t * 0.6)
                context.strokeEllipse(in: circle(x: 2.2 + t * 2, y: 9.4 - t * 7, radius: 0.7 + 1.1 * t))
            }
            context.restoreGState()
        }

        context.addPath(body)
        context.strokePath()

        let knob = CGMutablePath()
        knob.move(to: CGPoint(x: 10.7, y: 8.9))
        knob.addQuadCurve(to: CGPoint(x: 13.3, y: 8.9), control: CGPoint(x: 12, y: 6.4))
        context.addPath(knob)
        context.strokePath()

        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: 6.5, y: 11.6))
        handle.addCurve(to: CGPoint(x: 17.5, y: 11.6), control1: CGPoint(x: 6.2, y: 1.4), control2: CGPoint(x: 17.8, y: 1.4))
        context.addPath(handle)
        context.strokePath()

        strokeLine(in: context, from: CGPoint(x: 4.5, y: 15.4), to: CGPoint(x: 1.8, y: 11.6))
    }

    /// A pot-bellied cauldron with a rim and three legs. Awake, bubbles rise
    /// through the brew and pop above it.
    static func cauldron(_ context: CGContext, filled: Bool, step: Int?) {
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 6.4, y: 9))
        body.addCurve(to: CGPoint(x: 8, y: 20.4), control1: CGPoint(x: 1.6, y: 10.8), control2: CGPoint(x: 1.6, y: 19.4))
        body.addLine(to: CGPoint(x: 16, y: 20.4))
        body.addCurve(to: CGPoint(x: 17.6, y: 9), control1: CGPoint(x: 22.4, y: 19.4), control2: CGPoint(x: 22.4, y: 10.8))
        body.closeSubpath()

        if filled {
            fill(body, from: 12, in: context) {
                guard let step else { return }
                for (x, offset) in [(8.6, 1), (15.0, 5)] {
                    let t = phase(step, offset)
                    clearCircle(in: context, x: x, y: 18.8 - t * 6.2, radius: 0.8 + 0.25 * t)
                }
            }
        }

        if let step {
            context.saveGState()
            context.setLineWidth(1.2)
            for (index, (x, offset)) in [(8.6, 0), (12.0, 3), (15.4, 5)].enumerated() {
                let t = phase(step, offset)
                context.setAlpha(1 - t * 0.6)
                context.strokeEllipse(in: circle(
                    x: x + CGFloat(index - 1) * t * 0.6,
                    y: 6.6 - t * 4.6,
                    radius: 0.75 + 0.6 * t
                ))
            }
            context.restoreGState()
        }

        context.addPath(body)
        context.strokePath()
        strokeLine(in: context, from: CGPoint(x: 4.4, y: 8.6), to: CGPoint(x: 19.6, y: 8.6))
        strokeLine(in: context, from: CGPoint(x: 7.4, y: 20.2), to: CGPoint(x: 6.6, y: 22.4))
        strokeLine(in: context, from: CGPoint(x: 12, y: 20.4), to: CGPoint(x: 12, y: 22.4))
        strokeLine(in: context, from: CGPoint(x: 16.6, y: 20.2), to: CGPoint(x: 17.4, y: 22.4))
    }

    // MARK: Shared marks

    private static let slashStart = CGPoint(x: 3.2, y: 2.6)
    private static let slashEnd = CGPoint(x: 20.8, y: 21.4)
    private static let dotCenter = CGPoint(x: 19.6, y: 4.6)

    /// Paused: a slash with a clear channel either side so it reads against
    /// the outline.
    private static func drawSlash(in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.clear)
        context.setLineWidth(4.6)
        strokeLine(in: context, from: slashStart, to: slashEnd)
        context.restoreGState()
        strokeLine(in: context, from: slashStart, to: slashEnd)
    }

    /// Needs-you: the orange dot in a cleared ring at the top right.
    private static func drawDot(in context: CGContext, color: CGColor) {
        clearCircle(in: context, x: dotCenter.x, y: dotCenter.y, radius: 4.8)
        context.setFillColor(color)
        context.fillEllipse(in: circle(x: dotCenter.x, y: dotCenter.y, radius: 3.3))
    }

    // MARK: Helpers

    /// Where a looping element is in its rise, 0 up to (not including) 1, for
    /// an element `offset` steps ahead of the first.
    private static func phase(_ step: Int, _ offset: Int) -> CGFloat {
        CGFloat((step + offset) % awakeFrameCount) / CGFloat(awakeFrameCount)
    }

    /// Fill `vessel` with liquid from `surface` down, then run `inside` while
    /// still clipped to the vessel, so fizz cut from the liquid stays in it.
    private static func fill(
        _ vessel: CGPath,
        from surface: CGFloat,
        in context: CGContext,
        inside: () -> Void = {}
    ) {
        context.saveGState()
        context.addPath(vessel)
        context.clip()
        context.fill(CGRect(x: 0, y: surface, width: 24, height: 24 - surface))
        inside()
        context.restoreGState()
    }

    private static func strokeLine(in context: CGContext, from start: CGPoint, to end: CGPoint) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private static func clearCircle(in context: CGContext, x: CGFloat, y: CGFloat, radius: CGFloat) {
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: circle(x: x, y: y, radius: radius))
        context.restoreGState()
    }

    private static func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> CGRect {
        CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
    }
}
