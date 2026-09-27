import SwiftUI
import AriaKit

/// Routes between first-run setup, sign-in and the main interface.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ZStack {
                    AmbientBackground()
                    ProgressView()
                }
            case .needsBackend:
                BackendSetupView()
            case .signedOut:
                AuthView()
            case .signedIn:
                MainView()
            }
        }
        .animation(AriaTheme.spring, value: model.phase)
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// First launch without a Supabase project baked into the build.
struct BackendSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var key = ""

    var body: some View {
        ZStack {
            AmbientBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "server.rack")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        Text("Connect your backend")
                            .font(.largeTitle.bold())
                        Text("Aria stores your planner in your own Supabase project so your iPhone, iPad and Windows PC stay in sync. Find these under Project Settings ▸ API.")
                            .foregroundStyle(.secondary)
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("https://your-project.supabase.co", text: $url)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Divider()
                            TextField("anon / publishable key", text: $key, axis: .vertical)
                                .lineLimit(1...4)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.callout.monospaced())
                        }
                    }
                    Button {
                        _ = model.connect(urlString: url, anonKey: key)
                    } label: {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(url.isEmpty || key.isEmpty)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Email + password sign-in / sign-up (Supabase Auth).
struct AuthView: View {
    @Environment(AppModel.self) private var model
    @State private var isSignUp = false
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        ZStack {
            AmbientBackground()
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(.tint)
                            .symbolEffect(.bounce, value: isSignUp)
                        Text("Aria")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                        Text("Your planner, run by an assistant.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    GlassCard {
                        VStack(spacing: 14) {
                            Picker("Mode", selection: $isSignUp.animation(AriaTheme.spring)) {
                                Text("Sign In").tag(false)
                                Text("Create Account").tag(true)
                            }
                            .pickerStyle(.segmented)
                            if isSignUp {
                                TextField("Name", text: $name)
                                    .textContentType(.name)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            TextField("Email", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField("Password", text: $password)
                                .textContentType(isSignUp ? .newPassword : .password)
                        }
                        .textFieldStyle(.roundedBorder)
                    }

                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        ZStack {
                            Text(isSignUp ? "Create Account" : "Sign In").opacity(isWorking ? 0 : 1)
                            if isWorking { ProgressView() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(isWorking || email.isEmpty || password.count < 6)

                    if !model.hasBundledBackend {
                        Button("Use a different Supabase project") {
                            Task { await model.disconnectBackend() }
                        }
                        .font(.footnote)
                    }
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            if isSignUp {
                try await model.signUp(email: email, password: password, name: name)
            } else {
                try await model.signIn(email: email, password: password)
            }
        } catch {
            withAnimation(AriaTheme.spring) {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if (error as? AriaError) == .emailConfirmationRequired { isSignUp = false }
        }
    }
}
