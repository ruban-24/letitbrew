import CoreGraphics
import Testing
@testable import LetItBrewAppCore

private let ink = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
private let orange = CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)

/// The icon rendered at menu-bar size (18 pt at 2×) as raw RGBA bytes.
private func render(_ icon: BrewIcon, _ state: BrewIconState, frame: Int = 0) -> [UInt8] {
    let side = 36
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Match the menu bar's y-down drawing.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        icon.draw(
            in: context,
            state: state,
            frame: frame,
            scale: CGFloat(side) / FlaskGeometry.canvas,
            ink: ink,
            dot: orange
        )
    }
    return pixels
}

private func inkedPixels(_ pixels: [UInt8]) -> Int {
    stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 0 }
}

private func hasOrange(_ pixels: [UInt8]) -> Bool {
    stride(from: 0, to: pixels.count, by: 4).contains {
        pixels[$0 + 3] == 255 && pixels[$0] > 200 && pixels[$0 + 1] > 80 && pixels[$0 + 1] < 180
    }
}

private func awakeFrames(_ icon: BrewIcon) -> [[UInt8]] {
    let count = icon.frameCount(for: .awake, reduceMotion: false, lowPowerMode: false)
    return (0..<count).map { render(icon, .awake, frame: $0) }
}

// MARK: - States

@Test(arguments: BrewIcon.allCases)
func idleAwakeNeedsYouAndPausedAllLookDifferent(icon: BrewIcon) {
    let frames = [
        render(icon, .idle),
        render(icon, .needsYou),
        render(icon, .paused),
    ] + awakeFrames(icon)

    for i in frames.indices {
        for j in frames.indices where j > i {
            #expect(frames[i] != frames[j], "frames \(i) and \(j) are identical")
        }
    }
}

@Test(arguments: BrewIcon.allCases)
func everyStateDrawsAVisibleMostlyTransparentGlyph(icon: BrewIcon) {
    let total = 36 * 36
    for state in BrewIconState.allCases {
        let inked = inkedPixels(render(icon, state))
        #expect(inked * 100 / total > 10, "\(state) is nearly blank")
        #expect(inked * 100 / total < 60, "\(state) would render as a solid square")
    }
}

@Test(arguments: BrewIcon.allCases)
func onlyNeedsYouShowsTheOrangeDot(icon: BrewIcon) {
    #expect(hasOrange(render(icon, .needsYou)))
    #expect(!hasOrange(render(icon, .idle)))
    #expect(!hasOrange(render(icon, .paused)))
    for frame in awakeFrames(icon) { #expect(!hasOrange(frame)) }
}

@Test(arguments: BrewIcon.allCases)
func awakeAndNeedsYouAreFilledWhileIdleAndPausedAreEmpty(icon: BrewIcon) {
    let idle = inkedPixels(render(icon, .idle))
    #expect(inkedPixels(render(icon, .awake)) > idle)
    #expect(inkedPixels(render(icon, .needsYou)) > idle)
}

// MARK: - Animation

@Test(arguments: BrewIcon.allCases)
func theAwakeSequenceHasSeveralFramesAndLoops(icon: BrewIcon) {
    let count = icon.frameCount(for: .awake, reduceMotion: false, lowPowerMode: false)
    #expect(count > 1)
    #expect(BrewIcon.frame(after: count - 1, count: count) == 0)
    #expect(BrewIcon.frame(after: 0, count: count) == 1)
    // Frame indices wrap, so a frame past the end draws the start again.
    #expect(render(icon, .awake, frame: count) == render(icon, .awake, frame: 0))
}

@Test(arguments: BrewIcon.allCases)
func reduceMotionOrLowPowerModeHoldsTheAwakeIconOnOneFrame(icon: BrewIcon) {
    #expect(icon.frameCount(for: .awake, reduceMotion: true, lowPowerMode: false) == 1)
    #expect(icon.frameCount(for: .awake, reduceMotion: false, lowPowerMode: true) == 1)
    #expect(icon.frameCount(for: .awake, reduceMotion: true, lowPowerMode: true) == 1)
    #expect(BrewIcon.frame(after: 0, count: 1) == 0)
}

@Test(arguments: BrewIcon.allCases)
func onlyAwakeAnimates(icon: BrewIcon) {
    for state in [BrewIconState.idle, .needsYou, .paused] {
        #expect(icon.frameCount(for: state, reduceMotion: false, lowPowerMode: false) == 1)
    }
}

// MARK: - State resolution

@Test func pausedBeatsAWaitingAgentWhichBeatsKeepingAwake() {
    #expect(BrewIconState.resolve(isPaused: true, isKeepingAwake: true, isWaitingForYou: true) == .paused)
    #expect(BrewIconState.resolve(isPaused: false, isKeepingAwake: true, isWaitingForYou: true) == .needsYou)
    #expect(BrewIconState.resolve(isPaused: false, isKeepingAwake: false, isWaitingForYou: true) == .needsYou)
    #expect(BrewIconState.resolve(isPaused: false, isKeepingAwake: true, isWaitingForYou: false) == .awake)
    #expect(BrewIconState.resolve(isPaused: false, isKeepingAwake: false, isWaitingForYou: false) == .idle)
}

// MARK: - Tooltip

private func toolTip(
    _ state: BrewIconState,
    working: Int = 0,
    waiting: Int = 0,
    keepingAwake: Bool = false,
    idleReason: String = "Watching for agents"
) -> String {
    MenuBarToolTipCopy.resolve(
        state: state,
        workingCount: working,
        waitingCount: waiting,
        isKeepingAwake: keepingAwake,
        idleReason: idleReason
    )
}

@Test func theToolTipNamesTheCurrentState() {
    #expect(toolTip(.awake, working: 2, keepingAwake: true) == "Keeping awake · 2 agents working")
    #expect(toolTip(.awake, working: 1, keepingAwake: true) == "Keeping awake · 1 agent working")
    #expect(toolTip(.awake, keepingAwake: true) == "Keeping awake")
    #expect(toolTip(.paused, working: 2, waiting: 1) == "Let It Brew is paused")
    #expect(toolTip(.needsYou, waiting: 1) == "1 agent needs you")
    #expect(toolTip(.needsYou, working: 1, waiting: 2, keepingAwake: true)
        == "Keeping awake · 2 agents need you")
    #expect(toolTip(.idle, idleReason: "Low Power Mode is on") == "Low Power Mode is on")
}
