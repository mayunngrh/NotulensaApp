import SwiftUI

/// Connect the app to Google Drive: paste the OAuth Desktop client credentials once,
/// then sign in via the browser. Tokens live in the Keychain.
struct GoogleDriveSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = GoogleAuthService.shared
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var masterFolder = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Client ID", text: $clientID, prompt: Text("xxxx.apps.googleusercontent.com"))
                    SecureField("Client Secret", text: $clientSecret)
                } header: {
                    Text("OAuth Client (Desktop app)")
                } footer: {
                    Text("Create once at console.cloud.google.com → APIs & Services → Credentials → Create credentials → OAuth client ID → Desktop app. Also enable the Google Drive API for the project.")
                }

                Section {
                    TextField("Master folder name", text: $masterFolder, prompt: Text("Photobooth"))
                } header: {
                    Text("Drive Folder Structure")
                } footer: {
                    Text("Uploads go to My Drive → \(masterFolder.isEmpty ? "Photobooth" : masterFolder) → <Event name> → Session <date & time>. Created automatically on first upload.")
                }

                Section {
                    if auth.isSignedIn {
                        Label("Connected to Google Drive", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Sign Out", role: .destructive) {
                            auth.signOut()
                        }
                    } else {
                        Button {
                            signIn()
                        } label: {
                            if busy {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .disabled(busy || clientID.isEmpty || clientSecret.isEmpty)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Every finished session uploads to Photobooth/<event>/<session> on this Drive, and the result QR links to that folder.")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 540)
        .onAppear {
            clientID = auth.clientID
            clientSecret = auth.clientSecret
            masterFolder = auth.masterFolderName
        }
        .onChange(of: clientID) { _ in auth.clientID = clientID }
        .onChange(of: clientSecret) { _ in auth.clientSecret = clientSecret }
        .onChange(of: masterFolder) { _ in auth.masterFolderName = masterFolder }
    }

    private func signIn() {
        busy = true
        errorMessage = nil
        Task {
            do {
                try await auth.signIn()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
