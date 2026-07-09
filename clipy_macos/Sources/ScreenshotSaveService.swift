import AppKit
import Foundation

enum ScreenshotSaveService {
    @discardableResult
    static func saveIfEnabled(pngData: Data) -> URL? {
        guard PreferencesManager.shared.isScreenshotAutoSaveEnabled else {
            return nil
        }
        return save(pngData: pngData)
    }

    @discardableResult
    static func saveIfEnabled(image: NSImage?) -> URL? {
        guard PreferencesManager.shared.isScreenshotAutoSaveEnabled,
              let image else {
            return nil
        }
        return save(image: image)
    }

    @discardableResult
    static func save(pngData: Data) -> URL? {
        let directory = PreferencesManager.shared.screenshotSaveDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = uniqueFileURL(in: directory)
            try pngData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            appLog("Screenshot save failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    @discardableResult
    static func save(image: NSImage) -> URL? {
        let directory = PreferencesManager.shared.screenshotSaveDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = uniqueFileURL(in: directory)
            guard let pngData = ScreenshotImageProcessor.pngData(from: image) else {
                appLog("Screenshot save failed: could not encode PNG", level: .error)
                return nil
            }
            try pngData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            appLog("Screenshot save failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private static func uniqueFileURL(in directory: URL) -> URL {
        let baseName = formattedBaseName()
        var candidate = directory.appendingPathComponent("\(baseName).png")
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index).png")
            index += 1
        }
        return candidate
    }

    /// A timestamped filename (no extension) suitable for save panels.
    static func defaultFilename() -> String {
        formattedBaseName()
    }

    private static func formattedBaseName() -> String {
        // Include milliseconds so rapid successive captures stay unique without
        // falling back to the "-1/-2" suffix path.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let seconds = formatter.string(from: Date())
        let ms = Int(Date().timeIntervalSince1970 * 1000) % 1000
        return String(format: "Screenshot %@.%03d", seconds, ms)
    }
}
