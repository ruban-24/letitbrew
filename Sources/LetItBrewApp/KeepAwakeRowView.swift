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
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel
            runningLine(row)
        }
    }

    private func runningLine(_ row: MenuKeepAwakeRunningPresentation) -> some View {
        HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel
            WrappingRow(spacing: 5) {
                ForEach(ManualSessionLength.presets, id: \.label) { preset in
                    Button(preset.label) { model.startManualSession(preset.length) }
                        .buttonStyle(DurationChipStyle())
                }
                untilButton
                Button("Indefinitely") { model.startManualSession(.indefinitely) }
                    .buttonStyle(DurationChipStyle())
            }
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
                .buttonStyle(DurationChipStyle(isSelected: true))
        } else {
            Button("Until…") {
                untilTime = ManualSessionUntil.defaultTime(now: Date())
                showsUntil = true
            }
            .buttonStyle(DurationChipStyle())
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

    /// Styled like the session board's section titles.
    private var sectionLabel: some View {
        Text("Keep awake")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A compact duration button: 12 pt text on a 20 pt rounded chip. Selected,
/// it fills with the accent colour.
private struct DurationChipStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.05))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
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
