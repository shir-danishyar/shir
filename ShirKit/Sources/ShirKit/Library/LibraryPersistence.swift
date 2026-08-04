import Foundation

/// Persistence seam. The app writes JSON to Documents; tests use an in-memory
/// double so the whole store is exercisable without touching the filesystem.
public protocol LibraryPersisting: AnyObject {
    func load() throws -> Library
    func save(_ library: Library) throws
}

/// Writes the library as a single JSON document, atomically, so a crash
/// mid-write can never leave a half-serialised file behind.
public final class FileLibraryPersistence: LibraryPersisting {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Default location: `Documents/library.json`.
    public convenience init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(url: documents.appendingPathComponent("library.json"))
    }

    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: url.path) else { return Library() }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Library.self, from: data)
    }

    public func save(_ library: Library) throws {
        let data = try encoder.encode(library)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Test double.
public final class InMemoryLibraryPersistence: LibraryPersisting {
    public private(set) var stored: Library
    public private(set) var saveCount = 0

    public init(_ library: Library = Library()) {
        stored = library
    }

    public func load() throws -> Library { stored }

    public func save(_ library: Library) throws {
        stored = library
        saveCount += 1
    }
}
