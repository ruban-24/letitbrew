import CoreGraphics
import Foundation

/// What the menu-bar icon is telling the person, in priority order: paused
/// beats an agent needing you, which beats keeping awake.
public enum BrewIconState: Equatable, Sendable, CaseIterable {
    /// Nothing is held: an empty, still icon.
    case idle
    /// The Mac is held awake: a looping frame sequence.
    case awake
    /// An agent is Waiting on the person: filled, still, with an orange dot.
    case needsYou
    /// Let It Brew is paused: empty with a slash.
    case paused

    public static func resolve(
        isPaused: Bool,
        isKeepingAwake: Bool,
        isWaitingForYou: Bool
    ) -> BrewIconState {
        if isPaused { return .paused }
        if isWaitingForYou { return .needsYou }
        if isKeepingAwake { return .awake }
        return .idle
    }
}

/// The family of menu-bar icons, in the order Settings offers them. Each one
/// draws every state on the shared 24×24 y-down canvas; only `awake` has more
/// than one frame.
public enum BrewIcon: String, Equatable, Sendable, CaseIterable {
    case flask
    case beerMug
    case coffee
    case kettle
    case cauldron

    /// The saved choice (its `rawValue`), or the flask when nothing (or
    /// nothing known) was saved: installs from before the picker never saved one.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .flask
    }

    /// The name under the icon's tile in Settings.
    public var displayName: String {
        switch self {
        case .flask: "Flask"
        case .beerMug: "Beer mug"
        case .coffee: "Coffee"
        case .kettle: "Kettle"
        case .cauldron: "Cauldron"
        }
    }

    /// How often the menu-bar label swaps to the next awake frame.
    public static let frameInterval: Duration = .milliseconds(160)

    /// Frames to cycle through for `state`. A count of one means a still icon
    /// and no animation timer: everything but `awake`, and `awake` itself when
    /// Reduce Motion or Low Power Mode is on.
    public func frameCount(
        for state: BrewIconState,
        reduceMotion: Bool,
        lowPowerMode: Bool
    ) -> Int {
        guard state == .awake, !reduceMotion, !lowPowerMode else { return 1 }
        return awakeFrameCount
    }

    /// The frame after `frame` in a sequence of `count`, wrapping to the start.
    public static func frame(after frame: Int, count: Int) -> Int {
        count > 1 ? (frame + 1) % count : 0
    }

    private var awakeFrameCount: Int {
        switch self {
        case .flask: FlaskIcon.awakeFrameCount
        case .beerMug, .coffee, .cauldron: VesselIcons.awakeFrameCount
        case .kettle: VesselIcons.kettleAwakeFrameCount
        }
    }

    /// Draw `state` at `frame` into a y-down context. `ink` is the glyph (a
    /// template colour in the menu bar); `dot` is the needs-you dot, the only
    /// element that is not template-coloured.
    public func draw(
        in context: CGContext,
        state: BrewIconState,
        frame: Int,
        scale: CGFloat,
        ink: CGColor,
        dot: CGColor
    ) {
        switch self {
        case .flask:
            FlaskIcon.draw(in: context, state: state, frame: frame, scale: scale, ink: ink, dot: dot)
        case .beerMug:
            VesselIcons.draw(frameCount: awakeFrameCount, VesselIcons.beerMug, in: context, state: state, frame: frame, scale: scale, ink: ink, dot: dot)
        case .coffee:
            VesselIcons.draw(frameCount: awakeFrameCount, VesselIcons.coffee, in: context, state: state, frame: frame, scale: scale, ink: ink, dot: dot)
        case .kettle:
            VesselIcons.draw(frameCount: awakeFrameCount, VesselIcons.kettle, in: context, state: state, frame: frame, scale: scale, ink: ink, dot: dot)
        case .cauldron:
            VesselIcons.draw(frameCount: awakeFrameCount, VesselIcons.cauldron, in: context, state: state, frame: frame, scale: scale, ink: ink, dot: dot)
        }
    }
}

/// The flask's four states, built on `FlaskGeometry`.
enum FlaskIcon {
    static let awakeFrameCount = 9

    /// A fraction of the cone's height, not its area: the cone widens
    /// downward, so this covers well over half the glyph and reads as clearly
    /// filled next to the empty idle outline at 18 pt.
    static let fillLevel: CGFloat = 0.62

    /// Three bubbles, a third of a cycle apart, each rising from near the base
    /// through the liquid and on up the neck. Under the surface a bubble is a
    /// hole in the liquid; above it, a small dot of ink.
    private static let bubbleXs: [CGFloat] = [11.3, 12.9, 12.1]
    private static let bubbleStartY: CGFloat = 19.4
    private static let bubbleEndY: CGFloat = 5.2
    private static let submergedRadius: CGFloat = 1.25
    private static let risenRadius: CGFloat = 0.8

    private static let dotCenter = CGPoint(x: 19.3, y: 4.7)
    private static let dotRadius: CGFloat = 3.4
    private static let dotGap: CGFloat = 1.3

    private static let slashStart = CGPoint(x: 3.5, y: 3.5)
    private static let slashEnd = CGPoint(x: 20.5, y: 20.5)

    static func draw(
        in context: CGContext,
        state: BrewIconState,
        frame: Int,
        scale: CGFloat,
        ink: CGColor,
        dot: CGColor
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(ink)
        context.setStrokeColor(ink)

        switch state {
        case .idle:
            FlaskGeometry.draw(in: context, level: 0, scale: scale)
        case .awake:
            FlaskGeometry.draw(in: context, level: fillLevel, scale: scale)
            drawBubbles(in: context, frame: frame, scale: scale)
        case .needsYou:
            FlaskGeometry.draw(in: context, level: fillLevel, scale: scale)
            clearCircle(in: context, center: dotCenter, radius: dotRadius + dotGap, scale: scale)
            context.setFillColor(dot)
            context.fillEllipse(in: circle(dotCenter, dotRadius, scale))
        case .paused:
            FlaskGeometry.draw(in: context, level: 0, scale: scale)
            drawSlash(in: context, scale: scale)
        }
    }

    private static func drawBubbles(in context: CGContext, frame: Int, scale: CGFloat) {
        let surface = FlaskGeometry.surfaceY(level: fillLevel)
        let step = ((frame % awakeFrameCount) + awakeFrameCount) % awakeFrameCount
        for (index, x) in bubbleXs.enumerated() {
            let phase = (CGFloat(step) / CGFloat(awakeFrameCount)
                + CGFloat(index) / CGFloat(bubbleXs.count))
                .truncatingRemainder(dividingBy: 1)
            let y = bubbleStartY - (bubbleStartY - bubbleEndY) * phase
            let center = CGPoint(x: x, y: y)
            if y - submergedRadius > surface {
                clearCircle(in: context, center: center, radius: submergedRadius, scale: scale)
            } else if y + risenRadius < surface {
                context.fillEllipse(in: circle(center, risenRadius, scale))
            }
            // A bubble breaking the surface is hidden for that frame.
        }
    }

    private static func drawSlash(in context: CGContext, scale: CGFloat) {
        let slash = CGMutablePath()
        slash.move(to: CGPoint(x: slashStart.x * scale, y: slashStart.y * scale))
        slash.addLine(to: CGPoint(x: slashEnd.x * scale, y: slashEnd.y * scale))
        context.setLineCap(.round)

        // A clear channel either side so the slash reads against the outline.
        context.saveGState()
        context.setBlendMode(.clear)
        context.setLineWidth(FlaskGeometry.strokeWidth * 2.6 * scale)
        context.addPath(slash)
        context.strokePath()
        context.restoreGState()

        context.setLineWidth(FlaskGeometry.strokeWidth * scale)
        context.addPath(slash)
        context.strokePath()
    }

    private static func clearCircle(in context: CGContext, center: CGPoint, radius: CGFloat, scale: CGFloat) {
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: circle(center, radius, scale))
        context.restoreGState()
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat, _ scale: CGFloat) -> CGRect {
        CGRect(
            x: (center.x - radius) * scale,
            y: (center.y - radius) * scale,
            width: radius * 2 * scale,
            height: radius * 2 * scale
        )
    }
}

/// The menu-bar icon's tooltip: the current state in a few words.
public enum MenuBarToolTipCopy {
    public static func resolve(
        state: BrewIconState,
        workingCount: Int,
        waitingCount: Int,
        isKeepingAwake: Bool,
        idleReason: String
    ) -> String {
        switch state {
        case .paused:
            return "Let It Brew is paused"
        case .needsYou:
            let needs = waitingCount == 1
                ? "1 agent needs you"
                : "\(waitingCount) agents need you"
            return isKeepingAwake ? "Keeping awake · \(needs)" : needs
        case .awake:
            switch workingCount {
            case 0: return "Keeping awake"
            case 1: return "Keeping awake · 1 agent working"
            default: return "Keeping awake · \(workingCount) agents working"
            }
        case .idle:
            return idleReason
        }
    }
}
