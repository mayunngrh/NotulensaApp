import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Step 2 of event setup: idle attract media, welcome background, and a drag-to-position
/// layout editor for the Start / Gallery buttons, with a live preview toggle.
struct WelcomeScreenEditorView: View {
    @Bindable var event: Event
    @Environment(\.modelContext) private var context

    private enum ImportTarget: Identifiable {
        case idleMedia, welcomeBackground
        var id: Self { self }
    }

    @State private var importTarget: ImportTarget?
    @State private var importerPresented = false
    @State private var importError: String?
    @State private var previewMode = false

    var body: some View {
        Group {
            if previewMode {
                previewStack
            } else {
                editorForm
            }
        }
        .navigationTitle("Welcome Screen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $previewMode) {
                    Label(previewMode ? "Editing" : "Preview", systemImage: previewMode ? "pencil" : "eye")
                }
                .toggleStyle(.button)
            }
        }
        .fileImporter(isPresented: $importerPresented, allowedContentTypes: allowedTypes) { result in
            let target = importTarget
            importTarget = nil
            handleImport(result) { url in
                switch target {
                case .idleMedia:
                    if let old = event.idleMediaPath { MediaStore.delete(relativePath: old) }
                    event.idleMediaPath = try MediaStore.importFile(from: url, into: .idle)
                case .welcomeBackground:
                    if let old = event.welcomeBackgroundPath { MediaStore.delete(relativePath: old) }
                    event.welcomeBackgroundPath = try MediaStore.importFile(from: url, into: .idle)
                case nil:
                    break
                }
            }
        }
        .alert("Import failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Preview

    private var previewStack: some View {
        VStack(spacing: 0) {
            Text("Idle Screen")
                .font(.headline)
                .padding(.top, 12)
            idleMediaPreview
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
            Divider()
            Text("Welcome Screen")
                .font(.headline)
                .padding(.top, 12)
            WelcomeScreenLayoutView(event: event, isEditable: false, onStart: nil, onGallery: nil)
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
        }
    }

    // MARK: Editor

    private var editorForm: some View {
        HSplitView {
            Form {
                Section {
                    if let path = event.idleMediaPath {
                        idlePreviewRow(path: path)
                        Button("Replace") { present(.idleMedia) }
                        Button("Remove", role: .destructive) {
                            MediaStore.delete(relativePath: path)
                            event.idleMediaPath = nil
                        }
                    } else {
                        Button {
                            present(.idleMedia)
                        } label: {
                            Label("Add Idle Photo or Video", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                } header: {
                    Text("Idle Screen Media")
                } footer: {
                    Text("Shown fullscreen while the booth waits. Tapping it opens the welcome screen below.")
                }

                Section {
                    if let path = event.welcomeBackgroundPath {
                        if let image = NSImage(contentsOf: MediaStore.url(for: path)) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button("Replace") { present(.welcomeBackground) }
                        Button("Remove", role: .destructive) {
                            MediaStore.delete(relativePath: path)
                            event.welcomeBackgroundPath = nil
                        }
                    } else {
                        Button {
                            present(.welcomeBackground)
                        } label: {
                            Label("Add Background Photo", systemImage: "photo")
                        }
                    }
                } header: {
                    Text("Welcome Background")
                } footer: {
                    Text("Optional — a gradient is used if left empty.")
                }

                Section("Button Layout") {
                    Text("Drag the Start and Gallery buttons on the canvas to place them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Start position", value: "\(Int(event.startButtonRelX * 100))%, \(Int(event.startButtonRelY * 100))%")
                    LabeledContent("Gallery position", value: "\(Int(event.galleryButtonRelX * 100))%, \(Int(event.galleryButtonRelY * 100))%")
                    Button("Reset Layout") {
                        event.startButtonRelX = 0.5; event.startButtonRelY = 0.72
                        event.galleryButtonRelX = 0.5; event.galleryButtonRelY = 0.86
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 320)

            WelcomeScreenLayoutView(event: event, isEditable: true)
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private var idleMediaPreview: some View {
        if let path = event.idleMediaPath {
            if event.idleMediaIsVideo {
                Color.black.overlay(Label("Video", systemImage: "video.fill").foregroundStyle(.white))
            } else if let image = NSImage(contentsOf: MediaStore.url(for: path)) {
                Image(nsImage: image).resizable().scaledToFill()
            }
        } else {
            Color.black.overlay(Text("No idle media set").foregroundStyle(.white.opacity(0.6)))
        }
    }

    @ViewBuilder
    private func idlePreviewRow(path: String) -> some View {
        let url = MediaStore.url(for: path)
        if event.idleMediaIsVideo {
            Label(url.lastPathComponent, systemImage: "video.fill")
        } else if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func present(_ target: ImportTarget) {
        importTarget = target
        importerPresented = true
    }

    private var allowedTypes: [UTType] {
        switch importTarget {
        case .welcomeBackground: [.png, .jpeg, .heic]
        default: [.png, .jpeg, .heic, .movie, .mpeg4Movie, .quickTimeMovie]
        }
    }

    private func handleImport(_ result: Result<URL, Error>, _ action: (URL) throws -> Void) {
        do {
            try action(try result.get())
        } catch {
            importError = error.localizedDescription
        }
    }
}
