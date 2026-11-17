import LetItBrewAppCore
import SwiftUI

/// The menu's Keep awake row: duration buttons, or the running session's
/// countdown with +1h and End.
struct KeepAwakeRowView: View {
    @EnvironmentObject private var model: LetItBrewAppModel
    @State private var showsUntil = false
    @State private var untilTime = ManualSessionUntil.defaultTime(now: Date())

    var body: some View {
        Group {
            if let row = model.keepAwakeRow {
                running(row)
            } else {
                picker
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.keepAwakeRow == nil) { showsUntil = false }
    }

    private func running(_ row: MenuKeepAwakeRunningPresentation) -> some View {
        HStack(spacing: 10) {
            timerGlyph
            VStack(alignment: .leading, spacing: 1) {
                runningTitle(row)
                Text(row.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if row.canExtend {
                Button("+1h") { model.extendManualSession() }
                    .accessibilityLabel("Add one hour")
            }
            Button("End") { model.endManualSession() }
                .accessibilityLabel("End keep awake session")
        }
        .controlSize(.small)
    }

    private func runningTitle(_ row: MenuKeepAwakeRunningPresentation) -> Text {
        guard let timeLeft = row.timeLeft else { return Text(row.title) }
        return Text("\(row.status) · ")
            + Text(timeLeft).bold().monospacedDigit()
            + Text(" left")
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                timerGlyph
                Text("Keep awake")
                    .fontWeight(.medium)
                    .accessibilityAddTraits(.isHeader)
            }
            WrappingRow(spacing: 6) {
                ForEach(ManualSessionLength.presets, id: \.label) { preset in
                    Button(preset.label) { model.startManualSession(preset.length) }
                        .buttonStyle(.bordered)
                }
                untilButton
                Button("Indefinitely") { model.startManualSession(.indefinitely) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            if showsUntil {
                untilLine
            }
            if model.isPaused {
                Text(MenuKeepAwakePresentationPolicy.pausedCaption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var untilButton: some View {
        if showsUntil {
            Button("Until…") { showsUntil = false }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Until…") {
                untilTime = ManualSessionUntil.defaultTime(now: Date())
                showsUntil = true
            }
            .buttonStyle(.bordered)
        }
    }

    private var untilLine: some View {
        let now = Date()
        let deadline = ManualSessionUntil.deadline(for: untilTime, now: now)
        return HStack(spacing: 8) {
            Text("Until")
            DatePicker("Keep awake until", selection: $untilTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
            Text(ManualSessionUntil.dayWord(for: deadline, now: now))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Start") {
                model.startManualSession(.until(
                    ManualSessionUntil.deadline(for: untilTime, now: Date())
                ))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var timerGlyph: some View {
        Image(systemName: "timer")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 20)
            .accessibilityHidden(true)
    }

}

/// Lays children out left to right, wrapping onto a new line when the row is
/// full.
private struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = lines(for: subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, lines.count - 1))
        let used = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
