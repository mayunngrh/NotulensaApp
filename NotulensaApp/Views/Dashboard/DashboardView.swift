import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Event.createdAt, order: .reverse) private var events: [Event]
    @State private var showNewEvent = false
    @State private var newEventName = ""
    @State private var showDriveSettings = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if events.isEmpty {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "camera.on.rectangle",
                        description: Text("Create an event to set up templates and start a photobooth session.")
                    )
                } else {
                    List {
                        ForEach(events) { event in
                            NavigationLink(value: event) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.name).font(.headline)
                                    Text("\(event.templates.count) template(s) · \(event.captures.count) photo(s) · \(event.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: deleteEvents)
                    }
                }
            }
            .navigationTitle("Photobooth Events")
            .navigationDestination(for: Event.self) { event in
                EventDetailView(event: event)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newEventName = ""
                        showNewEvent = true
                    } label: {
                        Label("New Event", systemImage: "plus")
                    }
                }
                ToolbarItem {
                    Button {
                        showDriveSettings = true
                    } label: {
                        Label("Google Drive", systemImage: "icloud.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showDriveSettings) {
                GoogleDriveSettingsView()
            }
            .alert("New Event", isPresented: $showNewEvent) {
                TextField("Event name", text: $newEventName)
                Button("Create") {
                    let trimmed = newEventName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let event = Event(name: trimmed)
                    context.insert(event)
                    path.append(event)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Step 1 of 4 — you'll set up the welcome screen, templates, and capture settings next.")
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private func deleteEvents(at offsets: IndexSet) {
        for index in offsets {
            let event = events[index]
            for template in event.templates {
                MediaStore.delete(relativePath: template.frameImagePath)
            }
            for capture in event.captures {
                MediaStore.delete(relativePath: capture.filePath)
                if let gif = capture.gifPath { MediaStore.delete(relativePath: gif) }
                if let live = capture.livePhotoPath { MediaStore.delete(relativePath: live) }
            }
            if let idle = event.idleMediaPath {
                MediaStore.delete(relativePath: idle)
            }
            if let background = event.welcomeBackgroundPath {
                MediaStore.delete(relativePath: background)
            }
            context.delete(event)
        }
    }
}
