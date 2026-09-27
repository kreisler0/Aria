import SwiftUI
import AriaKit

/// The conversational control surface: everything typed here goes through the fixed tool
/// schema (AriaKit `AssistantEngine`), and each change it makes shows up as a chip.
struct AIChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let isSheet: Bool
    @State private var draft = ""
    @State private var apiKey = ""
    @State private var confirmClear = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if !isSheet { AmbientBackground() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !model.hasAPIKey {
                            apiKeyCard
                        } else if model.chat.isEmpty {
                            suggestions
                        }
                        ForEach(model.chat) { bubble in
                            BubbleView(bubble: bubble)
                                .id(bubble.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                        if model.isThinking {
                            ThinkingIndicator()
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 90)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.chat.count) { _, _ in
                    guard let last = model.chat.last?.id else { return }
                    withAnimation(AriaTheme.spring) { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: model.isThinking) { _, thinking in
                    if thinking { withAnimation(AriaTheme.spring) { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }
            inputBar
        }
        .navigationTitle("Aria")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Aria").font(.headline)
                    Text(model.selectedModel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.chat.isEmpty)
                .accessibilityLabel("Clear conversation")
            }
        }
        .confirmationDialog("Clear the conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await model.clearChat() } }
        } message: {
            Text("Aria forgets this conversation. Your tasks and events are not affected.")
        }
        .onAppear { if model.hasAPIKey { inputFocused = true } }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Aria…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .liquidGlass(cornerRadius: AriaTheme.smallRadius, interactive: true)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.86))
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isThinking)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 760)
    }

    private var apiKeyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connect OpenRouter", systemImage: "key.fill")
                    .font(.headline)
                Text("Aria uses your own OpenRouter API key. It's stored only in this device's Keychain.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SecureField("sk-or-…", text: $apiKey)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Save Key") {
                    model.saveAPIKey(apiKey)
                    apiKey = ""
                    inputFocused = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Link("Get a key at openrouter.ai", destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.footnote)
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(["Add 'Finish essay' due Friday at 5pm", "What's on my calendar tomorrow?",
                     "Move my dentist appointment to next Tuesday at 10", "Clear everything I finished today"], id: \.self) { prompt in
                Button {
                    draft = prompt
                    send()
                } label: {
                    Text(prompt)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .liquidGlass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.vertical, 12)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
    }
}

private struct BubbleView: View {
    let bubble: ChatBubble

    var body: some View {
        switch bubble.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(bubble.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: AriaTheme.smallRadius, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 10, y: 5)
            }
        case .assistant:
            HStack {
                // Rendered Markdown, so replies never show stray asterisks.
                Text(ChatMarkdown.attributed(bubble.text))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .liquidGlass(cornerRadius: AriaTheme.smallRadius)
                Spacer(minLength: 48)
            }
        case .action(let succeeded):
            Label(bubble.text, systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(succeeded ? Color.green : Color.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlass(in: Capsule(), tint: succeeded ? .green : .orange)
        case .error:
            Label(bubble.text, systemImage: "exclamationmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct ThinkingIndicator: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.weight(.bold))
            .symbolEffect(.variableColor.iterative.reversing)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .liquidGlass(in: Capsule())
            .accessibilityLabel("Aria is thinking")
    }
}
