import GlassRailKit
import SwiftUI

/// "Penn track calls" in Settings: whether the track checker is reading New
/// York Penn's board, and the way in to connect it to NJ Transit.
struct PennCheckerRow: View {
    let checker: PennChecker?
    let loading: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(dot)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .grFont(15.2, .semibold, style: .headline, maxScale: 1.4)
                    Text(detail)
                        .grFont(11.5, style: .caption, maxScale: 1.4, digits: true)
                        .foregroundStyle(theme.ink.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let actionTitle {
                    Text(actionTitle)
                        .grFont(12.5, .semibold, style: .footnote, maxScale: 1.4)
                        .foregroundStyle(theme.ink.opacity(0.85))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.6))
            }
            .padding(14)
            .contentShape(Rectangle())
            .insetPanel(radius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Penn track calls, \(title)")
        .accessibilityValue(detail)
        .accessibilityHint(actionTitle == nil ? "Change the NJ Transit login" : "Connect your NJ Transit login")
    }

    private var title: String {
        switch checker?.state {
        case .ok: return "On"
        case .starting: return "Connected"
        case .needsLogin: return "Not connected"
        case .loginRefused: return "Login refused"
        case .trouble: return "Retrying"
        case .stopped: return "Stopped"
        case nil: return loading ? "Checking" : "Can't reach the checker"
        }
    }

    private var detail: String {
        let at = checker?.at.map(Format.time) ?? "a while"
        switch checker?.state {
        case .ok: return "Reading New York Penn's board every minute"
        case .starting: return "The first read of New York Penn's board is under a minute away"
        case .needsLogin: return "Add your NJ Transit developer login to call tracks before they post"
        case .loginRefused: return "NJ Transit turned the saved login down. Connect it again"
        case .trouble: return "Couldn't read New York Penn's board at \(at). It tries again every minute"
        case .stopped: return "No read of New York Penn's board since \(at)"
        case nil: return loading ? "Asking the track checker" : "Check your connection"
        }
    }

    private var actionTitle: String? {
        switch checker?.state {
        case .needsLogin, nil: return loading ? nil : "Connect"
        case .loginRefused: return "Reconnect"
        default: return nil
        }
    }

    private var dot: Color {
        switch checker?.state {
        case .ok, .starting: return Accent.onTime
        case .loginRefused, .trouble, .stopped: return Accent.delay
        default: return theme.ink.opacity(0.3)
        }
    }
}

/// "Connect NJ Transit": a one-time setup code and the rider's RailData
/// developer login, sent once to the track checker, which has NJ Transit
/// accept the login before keeping it, encrypted. The phone keeps nothing.
struct PennConnectPage: View {
    @Binding var code: String
    let onBack: () -> Void
    let onConnected: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var outcome: PennConnect.Outcome?
    /// What's still missing, said when Connect is tapped too soon.
    @State private var missing: PennConnect.Missing?
    @FocusState private var field: Field?
    @Environment(\.theme) private var theme

    private enum Field {
        case code, username, password
    }

    init(code: Binding<String>, onBack: @escaping () -> Void, onConnected: @escaping () -> Void) {
        _code = code
        self.onBack = onBack
        self.onConnected = onConnected
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(kicker: "Settings", title: "Connect NJ Transit", onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Glass Rail calls New York Penn tracks before they post by reading NJ Transit with your developer login. It goes once, encrypted, to your track checker, which keeps it encrypted. This phone doesn't keep it.")
                        .grFont(12.5, style: .footnote)
                        .foregroundStyle(theme.ink.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    if outcome == .connected {
                        connected
                    } else {
                        form
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // Connect, and anything it has to say, stays in reach above the keyboard.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if outcome != .connected {
                    connectBar
                }
            }
        }
        .onChange(of: code) { _, _ in missing = nil }
        .onChange(of: username) { _, _ in missing = nil }
        .onChange(of: password) { _, _ in missing = nil }
    }

    /// The Connect button, never greyed out: tapped too soon, it says what's
    /// missing and goes to that field.
    private var connectBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = missing?.message ?? refusalMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Accent.delay)
                        .accessibilityHidden(true)
                    Text(message)
                        .grFont(12.5, .medium, style: .footnote)
                        .foregroundStyle(theme.ink.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
            ConnectButton(title: working ? "Checking with NJ Transit" : "Connect", working: working) { connect() }
                .disabled(working)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .animation(.snappy, value: missing)
        .animation(.snappy, value: outcome)
    }

    private var refusalMessage: String? {
        if case .refused(let refusal) = outcome { return refusal.message }
        return nil
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Setup code")
            TextField("6 letters and numbers", text: $code)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($field, equals: .code)
                .submitLabel(.next)
                .onSubmit { field = .username }
                .accessibilityLabel("Setup code")
                .connectField(digits: true)
            label("Username")
            TextField("RailData username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($field, equals: .username)
                .submitLabel(.next)
                .onSubmit { field = .password }
                .accessibilityLabel("NJ Transit RailData username")
                .connectField()
            label("Password")
            SecureField("RailData password", text: $password)
                .textContentType(.password)
                .focused($field, equals: .password)
                .submitLabel(.go)
                .onSubmit { connect() }
                .accessibilityLabel("NJ Transit RailData password")
                .connectField()
            Text("The setup code is the one-time code you were sent. The username and password are your NJ Transit developer (RailData) login.")
                .grFont(11.5, style: .caption)
                .foregroundStyle(theme.ink.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 14)
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Accent.onTime)
                    .accessibilityHidden(true)
                Text("Connected")
                    .grFont(15.2, .semibold, style: .headline, maxScale: 1.4)
            }
            Text("NJ Transit accepted the login. Track calls at New York Penn start within a minute.")
                .grFont(12.5, style: .footnote)
                .foregroundStyle(theme.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            ConnectButton(title: "Done", working: false, action: onBack)
                .padding(.top, 10)
        }
        .padding(14)
        .insetPanel(radius: 16)
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .accessibilityElement(children: .contain)
    }

    private func label(_ text: String) -> some View {
        Text(text).kicker()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .accessibilityHidden(true)
    }

    private func connect() {
        guard !working else { return }
        if let gap = PennConnect.missing(code: code, username: username, password: password) {
            missing = gap
            switch gap {
            case .code: field = .code
            case .username: field = .username
            case .password: field = .password
            }
            return
        }
        missing = nil
        field = nil
        working = true
        outcome = nil
        let (code, username, password) = (self.code, self.username, self.password)
        Task {
            let result = await PennConnect().connect(code: code, username: username, password: password)
            working = false
            outcome = result
            if result == .connected {
                self.password = ""
                self.code = ""
                onConnected()
            }
        }
    }
}

/// The Connect / Done button: a full-width glass capsule.
private struct ConnectButton: View {
    let title: String
    let working: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if working {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.ink)
                }
                Text(title)
                    .grFont(14.4, .semibold, style: .subheadline, maxScale: 1.3)
            }
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private extension View {
    /// A Connect field: the Settings search field's inset well.
    func connectField(digits: Bool = false) -> some View {
        grFont(15.2, digits ? .semibold : .regular, style: .body, maxScale: 1.4, digits: digits)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .insetPanel(radius: 14)
            .padding(.horizontal, 12)
            .padding(.top, 6)
    }
}
