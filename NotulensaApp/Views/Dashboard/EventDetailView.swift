import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Event setup hub. Each numbered section is one step of getting an event kiosk-ready:
/// 1) name (set on creation), 2) welcome screen, 3) templates, 4) capture settings.
struct EventDetailView: View {
    @ObservedObject var event: Event
    @EnvironmentObject private var store: PhotoboothStore
    /// When provided, shows a Done button that is disabled until the event is valid.
    var onDone: (() -> Void)? = nil

    private enum ImportTarget: Identifiable {
        case frame
        var id: Self { self }
    }

    @State private var importTarget: ImportTarget?
    @State private var importerPresented = false
    @State private var importError: String?

    private let maxTemplates = 3

    var body: some View {
        Form {
            Section("Event") {
                TextField("Name", text: $event.name)
            }

            Section {
                NavigationLink {
                    WelcomeScreenEditorView(event: event)
                } label: {
                    Label("Step 2 · Welcome Screen", systemImage: "sparkles.rectangle.stack")
                }
            } footer: {
                Text("Idle video/photo, welcome background, and the Start / Gallery button layout.")
            }

            Section {
                ForEach(event.templates) { template in
                    NavigationLink(value: template) {
                        HStack {
                            frameThumb(template)
                            VStack(alignment: .leading) {
                                Text(template.name)
                                Text("\(template.shotCount) photo slot(s)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        MediaStore.delete(relativePath: event.templates[index].frameImagePath)
                    }
                    event.templates.remove(atOffsets: offsets)
                    store.save()
                }
                if event.templates.count < maxTemplates {
                    Button {
                        present(.frame)
                    } label: {
                        Label("New Template (upload frame PNG)", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
            } header: {
                Text("Step 3 · Templates (\(event.templates.count)/\(maxTemplates))")
            } footer: {
                Text("Each template is a frame PNG with transparent cutouts plus photo slots you place in the editor. At least one is required.")
            }

            Section {
                NavigationLink {
                    CaptureSettingsView(event: event)
                } label: {
                    Label("Step 4 · Capture Settings", systemImage: "camera.badge.ellipsis")
                }
            } footer: {
                Text("Countdown timing, photo review duration, GIF size, and live photo looping.")
            }

            Section {
                Toggle("Enable Preview Mode", isOn: $event.enablePreview)
            } header: {
                Text("Preview Mode")
            } footer: {
                Text("When enabled, a Preview button appears on the welcome screen showing a landscape camera feed. Taps clear all shots and start fresh.")
            }

            if !event.canStart {
                Section {
                    Label(
                        event.templates.isEmpty
                            ? "Add at least one template to finish setup."
                            : "Every template needs at least one photo slot.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(event.name)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.save()
                        onDone()
                    }
                    .disabled(!event.canStart)
                }
            }
        }
        .navigationDestination(for: PhotoTemplate.self) { template in
            TemplateEditorView(template: template)
        }
        .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.png]) { result in
            importTarget = nil
            handleImport(result) { url in
                let path = try MediaStore.importFile(from: url, into: .frames)
                // Canvas is always 4R portrait (4×6 in): 1200×1800 px at 300 dpi.
                let template = PhotoTemplate(
                    name: "Template \(event.templates.count + 1)",
                    frameImagePath: path
                )
                // Every template needs at least one photo slot — start with one centered.
                template.slots.append(PhotoSlot(
                    order: 1,
                    x: template.canvasWidth * 0.15,
                    y: template.canvasHeight * 0.15,
                    width: template.canvasWidth * 0.7,
                    height: template.canvasHeight * 0.7,
                    layer: 0
                ))
                event.templates.append(template)
                store.save()
            }
        }
        .alert("Import failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func present(_ target: ImportTarget) {
        importTarget = target
        importerPresented = true
    }

    private func handleImport(_ result: Result<URL, Error>, _ action: (URL) throws -> Void) {
        do {
            try action(try result.get())
        } catch {
            importError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func frameThumb(_ template: PhotoTemplate) -> some View {
        if let image = NSImage(contentsOf: MediaStore.url(for: template.frameImagePath)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 60)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 40, height: 60)
        }
    }
}
