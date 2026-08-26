import SwiftUI

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @State private var pat = ""
    @State private var showPat = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("GitMenu")
                    .font(.title3.weight(.semibold))
                Text("Your GitHub inbox, in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 28)

            VStack(spacing: 10) {
                switch model.auth {
                case .deviceCode(let code, let url):
                    VStack(spacing: 8) {
                        Text("Enter this code on GitHub.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(.title, design: .monospaced).weight(.medium))
                            .textSelection(.enabled)
                        Text("Copied to your clipboard. Waiting for approval…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Link("Open \(url)", destination: URL(string: url)!)
                            .font(.caption)
                    }
                default:
                    if !AppModel.oauthClientId.isEmpty {
                        Button {
                            Task { await model.signInWithDevice() }
                        } label: {
                            Text("Sign in with GitHub").frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        Button(showPat ? "Hide token sign-in" : "Use a personal access token instead") { showPat.toggle() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if showPat || AppModel.oauthClientId.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SecureField("Personal access token (classic)", text: $pat)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { submit() }
                            Text("Needs the notifications and repo scopes. Fine-grained tokens cannot read notifications.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            signInButton
                        }
                    }
                }
                if let e = model.signInError {
                    Text(e).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .frame(width: 280)
            Spacer()
            Spacer()
        }
        .padding(24)
    }

    @ViewBuilder private var signInButton: some View {
        let b = Button { submit() } label: { Text("Sign in").frame(maxWidth: .infinity) }
            .controlSize(.large)
            .disabled(pat.trimmingCharacters(in: .whitespaces).isEmpty)
        if AppModel.oauthClientId.isEmpty { b.buttonStyle(.borderedProminent) } else { b.buttonStyle(.bordered) }
    }

    private func submit() { Task { await model.signIn(pat: pat) } }
}
