import AppKit
import LetItBrewAppCore
import SwiftUI

/// Settings → General → Appearance: one tile per menu-bar icon, each showing
/// its awake animation. Choosing a tile switches the menu bar right away.
struct AppearanceSettingsSection: View {
    @Binding var selection: BrewIcon

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        Section("Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menu bar icon")
                    Text("Changes right away. It moves while your Mac is kept awake.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(BrewIcon.allCases, id: \.self) { icon in
                        tile(icon)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Menu bar icon")
            }
        }
    }

    private func tile(_ icon: BrewIcon) -> some View {
        let isSelected = icon == selection
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            selection = icon
        } label: {
            VStack(spacing: 6) {
                AwakeIconPreview(icon: icon)
                Text(icon.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(shape.fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(
                shape.strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                    lineWidth: isSelected ? 2 : 1
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An icon's awake loop at preview size, timed like the menu bar. Reduce
/// Motion and Low Power Mode hold it on one frame, as they do the menu bar.
private struct AwakeIconPreview: View {
    let icon: BrewIcon
    private static let size: CGFloat = 30

    @State private var frame = 0
    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var frameCount: Int {
        icon.frameCount(for: .awake, reduceMotion: reduceMotion, lowPowerMode: lowPowerMode)
    }

    var body: some View {
        Image(nsImage: BrewIconImages.image(
            icon: icon,
            state: .awake,
            frame: frameCount > 1 ? frame % frameCount : 0,
            side: Self.size
        ))
        .renderingMode(.template)
        .foregroundStyle(.primary)
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
        .task(id: frameCount) {
            frame = 0
            guard frameCount > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: BrewIcon.frameInterval)
                frame = BrewIcon.frame(after: frame, count: frameCount)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        ).receive(on: RunLoop.main)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}
