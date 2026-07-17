import Foundation
import Combine

/// JSON-backed replacement for SwiftData (which requires macOS 14). Holds all events and
/// persists them to Application Support/Photobooth/library.json. A short autosave timer
/// covers field edits; structural changes call save() directly.
@MainActor
final class PhotoboothStore: ObservableObject {
    static let shared = PhotoboothStore()

    @Published var events: [Event] = []

    private var libraryURL: URL {
        MediaStore.root.appendingPathComponent("library.json")
    }

    private var autosaveTimer: Timer?

    init() {
        load()
        // Field edits (text fields, steppers) are picked up by this periodic save.
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    // MARK: Load / save

    func load() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        if let decoded = try? JSONDecoder().decode([Event].self, from: data) {
            events = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: MediaStore.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(events) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    // MARK: Mutations

    func addEvent(_ event: Event) {
        events.insert(event, at: 0)
        save()
    }

    func deleteEvent(_ event: Event) {
        for template in event.templates {
            MediaStore.delete(relativePath: template.frameImagePath)
        }
        for capture in event.captures {
            MediaStore.delete(relativePath: capture.filePath)
            if let slideshow = capture.slideshowPath { MediaStore.delete(relativePath: slideshow) }
            if let live = capture.livePhotoPath { MediaStore.delete(relativePath: live) }
            for raw in capture.rawPhotoPaths { MediaStore.delete(relativePath: raw) }
        }
        if let idle = event.idleMediaPath { MediaStore.delete(relativePath: idle) }
        if let background = event.welcomeBackgroundPath { MediaStore.delete(relativePath: background) }
        events.removeAll { $0.id == event.id }
        save()
    }
}
