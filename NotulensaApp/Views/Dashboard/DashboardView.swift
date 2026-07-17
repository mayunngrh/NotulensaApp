import SwiftUI
import AppKit

/// Split dashboard: event list on the left, read-only event overview on the right
/// with Edit Event / Launch Event actions.
struct DashboardView: View {
    @EnvironmentObject private var store: PhotoboothStore
    @EnvironmentObject private var router: AppRouter

    @State private var selectedEventID: Event.ID?
    @State private var showNewEvent = false
    @State private var newEventName = ""
    @State private var showDriveSettings = false
    @State private var editingEvent: Event?

    private var selectedEvent: Event? {
        store.events.first { $0.id == selectedEventID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedEventID) {
                ForEach(store.events) { event in
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
                    .tag(event.id)
                    .contextMenu {
                        Button("Edit Event") { editingEvent = event }
                        Button("Delete Event", role: .destructive) { store.deleteEvent(event) }
                    }
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
                EmptyStateView(
                    title: "No Event Selected",
                    systemImage: "camera.on.rectangle",
                    message: store.events.isEmpty
                        ? "Create an event with the + button to get started."
                        : "Select an event on the left to see its setup."
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
                store.addEvent(event)
                selectedEventID = event.id
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
            let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            NavigationStack {
                EventDetailView(event: event) {
                    editingEvent = nil
                }
            }
            .frame(width: screen.width * 0.8, height: screen.height * 0.8)
        }
    }
}

/// Simple replacement for ContentUnavailableView (macOS 14+).
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
