import Foundation

/// Owns the on-disk media layout under Application Support/Photobooth/.
/// SwiftData models store paths relative to `root` so the container can move freely.
enum MediaStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Photobooth", isDirectory: true)
    }

    enum Folder: String {
        case frames
        case idle
        case sessions
    }

    static func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func directory(_ folder: Folder) -> URL {
        let dir = root.appendingPathComponent(folder.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a user-selected file into the store; returns the relative path to persist.
    static func importFile(from source: URL, into folder: Folder) throws -> String {
        let dir = directory(folder)
        let name = UUID().uuidString + "." + source.pathExtension.lowercased()
        let dest = dir.appendingPathComponent(name)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: dest)
        return "\(folder.rawValue)/\(name)"
    }

    /// Writes data into the store; returns the relative path to persist.
    static func write(_ data: Data, into folder: Folder, subfolder: String? = nil, fileName: String) throws -> String {
        var dir = directory(folder)
        var rel = folder.rawValue
        if let subfolder {
            dir = dir.appendingPathComponent(subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            rel += "/\(subfolder)"
        }
        try data.write(to: dir.appendingPathComponent(fileName))
        return "\(rel)/\(fileName)"
    }

    static func delete(relativePath: String) {
        try? FileManager.default.removeItem(at: url(for: relativePath))
    }
}
