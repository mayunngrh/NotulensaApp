import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Event setup hub. Each numbered section is one step of getting an event kiosk-ready:
/// 1) name (set on creation), 2) welcome screen, 3) templates, 4) capture settings.
struct EventDetailView: View {
    @Bindable var event: Event
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router

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
                        let template = event.templates[index]
                        MediaStore.delete(relativePath: template.frameImagePath)
                        context.delete(template)
                    }
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

            if !event.canStart {
                Section {
                    Text("Add at least one template — then launch from the dashboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(event.name)
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
                template.event = event
                context.insert(template)
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
