import SwiftUI
import AriaKit

/// Model picker, API key, calendar sync, Live Activity and appearance settings.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var customModel = ""
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                accountSection
                assistantSection
                calendarSection

                Section {
                    Toggle("Show on Lock Screen", isOn: $model.liveActivitiesEnabled)
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("Shows your current or next event, or today's top task, on the Lock Screen and in the Dynamic Island.")
                }

                Section("Accent Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(AriaTheme.accents, id: \.name) { accent in
                            Button {
                                withAnimation(AriaTheme.spring) { model.accentName = accent.name }
                            } label: {
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if model.accentName == accent.name {
                                            Image(systemName: "checkmark")
                                                .font(.footnote.weight(.bold))
                                                .foregroundStyle(.white)
                                                .transition(.scale.combined(with: .opacity))
                                        }
                                    }
                                    .scaleEffect(model.accentName == accent.name ? 1.12 : 1)
                                    .shadow(color: accent.color.opacity(0.45), radius: model.accentName == accent.name ? 8 : 0, y: 3)
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.82))
                            .accessibilityLabel(accent.name.capitalized)
                            .accessibilityAddTraits(model.accentName == accent.name ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Backend") {
                    LabeledContent("Supabase", value: model.backendURL ?? "—")
                        .font(.footnote)
                    if !model.hasBundledBackend {
                        Button("Use a Different Project", role: .destructive) {
                            Task { await model.disconnectBackend() }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Settings")
            .task {
                await model.loadModels()
                await model.loadCalendarOptions()
            }
            .confirmationDialog("Sign out of Aria?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            if let user = model.user {
                LabeledContent("Name", value: user.displayName ?? "—")
                LabeledContent("Email", value: user.email ?? "—")
            }
            Button("Sign Out", role: .destructive) { confirmSignOut = true }
        }
    }

    private var assistantSection: some View {
        Section {
            if model.hasAPIKey {
                LabeledContent("OpenRouter key") {
                    Label("Saved in Keychain", systemImage: "lock.fill")
                        .foregroundStyle(.green)
                }
                Button("Remove Key", role: .destructive) { model.removeAPIKey() }
            } else {
                SecureField("OpenRouter API key (sk-or-…)", text: $apiKey)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save Key") {
                    model.saveAPIKey(apiKey)
                    apiKey = ""
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Picker("Model", selection: Binding(
                get: { model.selectedModel },
                set: { newValue in Task { await model.setModel(newValue) } }
            )) {
                ForEach(modelChoices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            .pickerStyle(.navigationLink)

            HStack {
                TextField("Other model id, e.g. mistralai/mistral-large", text: $customModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout)
                Button("Use") {
                    Task { await model.setModel(customModel) }
                    customModel = ""
                }
                .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Assistant")
        } footer: {
            Text("Your key never leaves this device except to call OpenRouter. The model choice syncs to your other devices.")
        }
    }

    /// The live/curated list, plus the current model if it was typed in by hand.
    private var modelChoices: [OpenRouterModel] {
        var choices = model.availableModels
        if !choices.contains(where: { $0.id == model.selectedModel }) {
            choices.insert(OpenRouterModel(id: model.selectedModel, name: model.selectedModel), at: 0)
        }
        return choices
    }

    private var calendarSection: some View {
        Section {
            Toggle("Sync with Calendar", isOn: Binding(
                get: { model.calendarSyncEnabled },
                set: { newValue in Task { await model.setCalendarSync(enabled: newValue) } }
            ))
            if model.calendarSyncEnabled {
                HStack {
                    Button("Sync Now") { Task { await model.syncCalendar() } }
                        .disabled(model.isSyncingCalendar)
                    Spacer()
                    if model.isSyncingCalendar {
                        ProgressView()
                    } else if let status = model.calendarSyncStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Picker("New events go to", selection: Binding(
                    get: { model.targetCalendarId ?? "" },
                    set: { model.targetCalendarId = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Default calendar").tag("")
                    ForEach(model.calendarOptions.filter(\.isWritable)) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                ForEach(model.calendarOptions) { option in
                    Toggle(isOn: Binding(
                        get: { model.isCalendarSynced(option) },
                        set: { model.setCalendar(option, synced: $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(option.title)
                            Text(option.isWritable ? option.sourceTitle : "\(option.sourceTitle) · read-only")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Two-way sync with the Calendar app: events you or Aria create appear there, and events from the calendars you pick appear in Aria. When both sides change, the most recent edit wins.")
        }
    }
}
