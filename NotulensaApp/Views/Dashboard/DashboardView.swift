import SwiftUI
import SwiftData

/// Split dashboard: event list on the left, read-only event overview on the right
/// with Edit Event / Launch Event actions.
struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Query(sort: \Event.createdAt, order: .reverse) private var events: [Event]

    @State private var selectedEvent: Event?
    @State private var showNewEvent = false
    @State private var newEventName = ""
    @State private var showDriveSettings = false
    @State private var editingEvent: Event?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedEvent) {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.name).font(.headline)
                        Text("\(event.templates.count) template(s) · \(event.captures.count) session(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .tag(event)
                    .contextMenu {
                        Button("Edit Event") { editingEvent = event }
                        Button("Delete Event", role: .destructive) { delete(event) }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { delete(events[index]) }
                }
            }
            .navigationTitle("Events")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
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
        } detail: {
            if let event = selectedEvent {
                EventOverviewView(event: event) {
                    editingEvent = event
                } onLaunch: {
                    router.runningEvent = event
                }
            } else {
                ContentUnavailableView(
                    "No Event Selected",
                    systemImage: "camera.on.rectangle",
                    description: Text(events.isEmpty
                        ? "Create an event with the + button to get started."
                        : "Select an event on the left to see its setup.")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("New Event", isPresented: $showNewEvent) {
            TextField("Event name", text: $newEventName)
            Button("Create") {
                let trimmed = newEventName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let event = Event(name: trimmed)
                context.insert(event)
                selectedEvent = event
                editingEvent = event
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Step 1 of 4 — you'll set up the welcome screen, templates, and capture settings next.")
        }
        .sheet(isPresented: $showDriveSettings) {
            GoogleDriveSettingsView()
        }
        .sheet(item: $editingEvent) { event in
            NavigationStack {
                EventDetailView(event: event)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { editingEvent = nil }
                        }
                    }
            }
            .frame(minWidth: 700, minHeight: 600)
        }
    }

    private func delete(_ event: Event) {
        if selectedEvent === event { selectedEvent = nil }
        for template in event.templates {
            MediaStore.delete(relativePath: template.frameImagePath)
        }
        for capture in event.captures {
            MediaStore.delete(relativePath: capture.filePath)
            if let gif = capture.gifPath { MediaStore.delete(relativePath: gif) }
            if let live = capture.livePhotoPath { MediaStore.delete(relativePath: live) }
            for raw in capture.rawPhotoPaths { MediaStore.delete(relativePath: raw) }
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
