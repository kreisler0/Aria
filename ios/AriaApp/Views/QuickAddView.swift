import SwiftUI
import AriaKit

/// The lightweight sheet the Quick Add widget deep-links into (spec §4.1): type a task, or
/// hand the sentence to Aria.
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var reply: String?
    @State private var isAsking = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Quick Add")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .font(.subheadline)
            }
            TextField("Add a task, or ask Aria…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(14)
                .liquidGlass(cornerRadius: AriaTheme.smallRadius, interactive: true)
            HStack(spacing: 12) {
                Button {
                    let title = text
                    text = ""
                    Task { await model.addTask(title: title) }
                    dismiss()
                } label: {
                    Label("Add Task", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await ask() }
                } label: {
                    ZStack {
                        Label("Ask Aria", systemImage: "sparkles").opacity(isAsking ? 0 : 1)
                        if isAsking { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAsking)
            .buttonBorderShape(.capsule)
            if let reply {
                Text(LocalizedStringKey(reply))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func ask() async {
        isAsking = true
        defer { isAsking = false }
        let message = text
        let before = model.chat.count
        await model.send(message)
        text = ""
        withAnimation(AriaTheme.spring) {
            reply = model.chat.dropFirst(before).last(where: { $0.role == .assistant || $0.role == .error })?.text
        }
    }
}
