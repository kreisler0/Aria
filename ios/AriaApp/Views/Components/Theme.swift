import SwiftUI
import AriaKit

/// Design tokens (spec §6): large continuous corner radii, one spring for every state
/// change, system colors with a user-selectable accent.
enum AriaTheme {
    static let cornerRadius: CGFloat = 24
    static let smallRadius: CGFloat = 20
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.8)

    static let accents: [(name: String, color: Color)] = [
        ("indigo", .indigo), ("blue", .blue), ("teal", .teal), ("mint", .mint), ("green", .green),
        ("orange", .orange), ("red", .red), ("pink", .pink), ("purple", .purple),
    ]

    static func accent(named name: String) -> Color {
        accents.first { $0.name == name }?.color ?? .indigo
    }

    static func color(for priority: TaskPriority) -> Color {
        switch priority {
        case .none: return .secondary
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        }
    }
}

/// A frosted-glass card.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AriaTheme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AriaTheme.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
    }
}

/// Soft, accent-tinted backdrop that gives the materials something to blur.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            GeometryReader { proxy in
                let size = proxy.size
                Circle()
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.22))
                    .frame(width: size.width * 0.9)
                    .blur(radius: 90)
                    .offset(x: -size.width * 0.3, y: -size.height * 0.15)
                Circle()
                    .fill(Color.purple.opacity(colorScheme == .dark ? 0.25 : 0.14))
                    .frame(width: size.width * 0.8)
                    .blur(radius: 100)
                    .offset(x: size.width * 0.45, y: size.height * 0.35)
            }
        }
        .ignoresSafeArea()
    }
}

/// A checkmark path, drawn on with `trim` so completion animates instead of snapping.
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.midY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY - rect.height * 0.22))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.minY + rect.height * 0.24))
        return path
    }
}

/// The round completion toggle: fills with the accent color, draws a checkmark on and
/// plays a haptic when a task is completed.
struct CompletionCheckbox: View {
    let isOn: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isOn ? tint : Color.secondary.opacity(0.6), lineWidth: 2)
                Circle()
                    .fill(tint)
                    .scaleEffect(isOn ? 1 : 0.2)
                    .opacity(isOn ? 1 : 0)
                CheckmarkShape()
                    .trim(from: 0, to: isOn ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .padding(5)
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
            .animation(AriaTheme.spring, value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Completed" : "Not completed")
        .accessibilityHint(isOn ? "Marks the task as not done" : "Marks the task as done")
    }
}

struct PriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        if priority != .none {
            Text(priority.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(AriaTheme.color(for: priority))
                .background(AriaTheme.color(for: priority).opacity(0.15), in: Capsule())
        }
    }
}

struct SourceBadge: View {
    let source: ItemSource

    var body: some View {
        if source == .ai {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(.tint)
                .accessibilityLabel("Added by Aria")
        }
    }
}
