import Foundation
import Combine

struct SavedWord: Codable, Equatable, Identifiable {
    var id: String { entry.word.lowercased() }
    var entry: WordEntry
    var isFamiliar: Bool
    let firstLookedUpAt: Date
    var lastLookedUpAt: Date
    var lookupCount: Int
}

/// Shared by the lookup and vocabulary windows; accessed on the main thread.
/// Commit to disk before publishing so failed writes never appear as saved.
final class WordBookStore: ObservableObject {
    static let shared = WordBookStore(fileURL: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClipyClone/word-book.json"))

    @Published private(set) var words: [SavedWord] = []
    @Published private(set) var errorKey: L10nKey?
    private let fileURL: URL
    private var loadFailed = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            let data = try Data(contentsOf: fileURL)
            words = try JSONDecoder().decode([SavedWord].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // The first successful query creates the vocabulary file.
        } catch {
            loadFailed = true
            errorKey = .wordBookReadError
        }
    }

    func record(_ entry: WordEntry, at date: Date = Date()) {
        var updated = words
        if let index = updated.firstIndex(where: { $0.id == entry.word.lowercased() }) {
            updated[index].entry = entry
            updated[index].lastLookedUpAt = date
            updated[index].lookupCount += 1
        } else {
            updated.append(SavedWord(entry: entry, isFamiliar: false,
                                     firstLookedUpAt: date, lastLookedUpAt: date, lookupCount: 1))
        }
        commit(updated.sorted { $0.lastLookedUpAt > $1.lastLookedUpAt })
    }

    func setFamiliar(_ familiar: Bool, id: String) {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        var updated = words
        updated[index].isFamiliar = familiar
        commit(updated)
    }

    private func commit(_ updated: [SavedWord]) {
        // Never overwrite an unreadable existing library with a partial one.
        guard !loadFailed else { return }
        do {
            let data = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            words = updated
            errorKey = nil
        } catch {
            errorKey = .wordBookWriteError
        }
    }
}
