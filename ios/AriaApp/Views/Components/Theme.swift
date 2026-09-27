import SwiftUI
import AriaKit

/// Design tokens (spec §6): large continuous corner radii, one spring for every state
/// change, system colors with a user-selectable accent.
enum AriaTheme {
    static let cornerRadius: CGFloat = 24
    static let smallRadius: CGFloat = 20
    /// State changes: a lively spring with a little overshoot.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.72)
    /// Touch-down: quick and firm. Release uses `release`, which bounces back.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let release = Animation.spring(response: 0.5, dampingFraction: 0.55)

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

// MARK: Liquid Glass

/// Apple's Liquid Glass on iOS 26 (`glassEffect`): it refracts what's behind it, catches
/// light as the device moves and, when interactive, flexes under the finger. Earlier
/// iOS versions get a hand-built equivalent: frosted material, a specular top edge, a
/// light rim and a soft shadow.
struct LiquidGlass<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive = false
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        let dark = colorScheme == .dark
        return content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.16)) }
                    // Specular sheen across the top.
                    shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.12 : 0.4), .white.opacity(0)],
                                              startPoint: .top, endPoint: .center))
                }
            }
            .overlay {
                // A bright rim on top, fading round the sides, catching again at the bottom.
                shape.stroke(LinearGradient(colors: [.white.opacity(dark ? 0.38 : 0.85), .white.opacity(0.04),
                                                     .white.opacity(dark ? 0.12 : 0.35)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(dark ? 0.35 : 0.1), radius: 18, y: 8)
    }
}

extension View {
    /// Liquid Glass in the given shape. `interactive` glass reacts to touch.
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, interactive: interactive))
    }

    func liquidGlass(cornerRadius: CGFloat = AriaTheme.cornerRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: interactive)
    }
}

/// Squishes on touch-down and springs back with a little overshoot on release; lifts
/// under the iPad pointer.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(configuration.isPressed ? AriaTheme.press : AriaTheme.release, value: configuration.isPressed)
            .contentShape(Rectangle())
            .hoverEffect(.lift)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// A glass card.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass()
    }
}

/// A slowly drifting field of accent colours: it gives the glass something to refract.
/// Still when Reduce Motion is on, and during UI tests (so the app can go idle).
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            GeometryReader { proxy in
                let size = proxy.size
                let dark = colorScheme == .dark
                Circle()
                    .fill(Color.accentColor.opacity(dark ? 0.38 : 0.26))
                    .frame(width: size.width * 0.95)
                    .blur(radius: 90)
                    .offset(x: -size.width * (drift ? 0.18 : 0.32), y: -size.height * (drift ? 0.08 : 0.16))
                Circle()
                    .fill(Color.blue.opacity(dark ? 0.26 : 0.18))
                    .frame(width: size.width * 0.8)
                    .blur(radius: 100)
                    .offset(x: size.width * (drift ? 0.32 : 0.48), y: size.height * (drift ? 0.42 : 0.3))
                Circle()
                    .fill(Color.pink.opacity(dark ? 0.18 : 0.12))
                    .frame(width: size.width * 0.7)
                    .blur(radius: 110)
                    .offset(x: size.width * (drift ? 0.05 : -0.1), y: size.height * (drift ? 0.62 : 0.72))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion, !UITestPreview.isUITest else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

// MARK: Chat text

enum ChatMarkdown {
    /// Assistant replies are Markdown. Inline styles (bold, italics, code, links) are
    /// rendered; list markers become bullets and headings become bold lines, and line
    /// breaks are kept. Anything unparseable falls back to the plain text.
    static func attributed(_ text: String) -> AttributedString {
        let prepared = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                return "• " + String(trimmed[marker.upperBound...])
            }
            if let marker = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                return "**" + String(trimmed[marker.upperBound...]) + "**"
            }
            return line
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(text)
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
            // A squish-and-pop each time it's ticked or unticked.
            .keyframeAnimator(initialValue: 1.0, trigger: isOn) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.78, duration: 0.09)
                    SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
                }
            }
        }
        .buttonStyle(.pressable)
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
