import AppKit
import Foundation

struct ShortcutCombo: Codable {
    var keyCode: Int
    var modifierFlags: UInt
    
    var displayString: String {
        var str = ""
        if modifierFlags & NSEvent.ModifierFlags.control.rawValue != 0 { str += "⌃" }
        if modifierFlags & NSEvent.ModifierFlags.option.rawValue != 0 { str += "⌥" }
        if modifierFlags & NSEvent.ModifierFlags.shift.rawValue != 0 { str += "⇧" }
        if modifierFlags & NSEvent.ModifierFlags.command.rawValue != 0 { str += "⌘" }
        
        // Simplified key mapping
        let keyMap: [Int: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
            0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
            0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
            0x21: "[", 0x22: "I", 0x23: "P", 0x24: "⏎", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
            0x29: ";", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥", 0x31: "␣",
            0x32: "`", 0x33: "⌫", 0x35: "⎋"
        ]
        str += keyMap[keyCode] ?? "?"
        return str
    }
}

struct Snippet: Codable, Identifiable {
    let id: UUID
    var title: String
    var content: String
    var shortcut: ShortcutCombo?
}

struct SnippetFolder: Codable, Identifiable {
    let id: UUID
    var title: String
    var snippets: [Snippet]
    var isEnabled: Bool = true
    var shortcut: ShortcutCombo?
}

class SnippetManager {
    static let shared = SnippetManager()
    
    private(set) var folders: [SnippetFolder] = []
    private let storageURL: URL
    
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    
    var onSnippetsChanged: (([SnippetFolder]) -> Void)?
    var onHotKeyTriggered: ((Any) -> Void)?

    private init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("ClipyClone")
        self.storageURL = appSupport.appendingPathComponent("snippets.json")
        
        loadSnippets()
        if folders.isEmpty {
            createDefaultSnippets()
        }
        registerHotKeys()
    }
    
    func registerHotKeys() {
        HotKeyManager.shared.unregisterAll()
        
        for folder in folders {
            if let combo = folder.shortcut {
                let folderId = UInt32(folder.id.hashValue & 0x7FFFFFFF)
                HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifierFlags, id: folderId) { [weak self] in
                    self?.onHotKeyTriggered?(folder)
                }
            }
            
            for snippet in folder.snippets {
                if let combo = snippet.shortcut {
                    let snippetId = UInt32(snippet.id.hashValue & 0x7FFFFFFF)
                    HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifierFlags, id: snippetId) { [weak self] in
                        self?.onHotKeyTriggered?(snippet)
                    }
                }
            }
        }
    }
    
    private func createDefaultSnippets() {
        let greetings = SnippetFolder(id: UUID(), title: "Greetings", snippets: [
            Snippet(id: UUID(), title: "Hi", content: "Hi there!"),
            Snippet(id: UUID(), title: "Hello", content: "Hello,"),
            Snippet(id: UUID(), title: "Regards", content: "Regards,")
        ])
        let work = SnippetFolder(id: UUID(), title: "Work", snippets: [
            Snippet(id: UUID(), title: "Thanks", content: "Thank you!"),
            Snippet(id: UUID(), title: "Check", content: "I'll check it."),
            Snippet(id: UUID(), title: "Email", content: "My Email: example@gmail.com")
        ])
        folders = [greetings, work]
        saveSnippets()
    }
    
    func loadSnippets() {
        if let data = try? Data(contentsOf: storageURL),
           let savedFolders = try? decoder.decode([SnippetFolder].self, from: data) {
            self.folders = savedFolders
        }
    }
    
    func saveSnippets() {
        if let data = try? encoder.encode(folders) {
            try? data.write(to: storageURL)
            registerHotKeys()
            onSnippetsChanged?(folders)
        }
    }
    
    func updateFolderTitle(id: UUID, title: String) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].title = title
            saveSnippets()
        }
    }
    
    func updateFolderShortcut(id: UUID, shortcut: ShortcutCombo?) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].shortcut = shortcut
            saveSnippets()
        }
    }
    
    func updateSnippetTitle(id: UUID, title: String) {
        for fIndex in 0..<folders.count {
            if let sIndex = folders[fIndex].snippets.firstIndex(where: { $0.id == id }) {
                folders[fIndex].snippets[sIndex].title = title
                saveSnippets()
                return
            }
        }
    }
    
    func updateSnippetContent(id: UUID, content: String) {
        for fIndex in 0..<folders.count {
            if let sIndex = folders[fIndex].snippets.firstIndex(where: { $0.id == id }) {
                folders[fIndex].snippets[sIndex].content = content
                saveSnippets()
                return
            }
        }
    }
    
    func updateSnippetShortcut(id: UUID, shortcut: ShortcutCombo?) {
        for fIndex in 0..<folders.count {
            if let sIndex = folders[fIndex].snippets.firstIndex(where: { $0.id == id }) {
                folders[fIndex].snippets[sIndex].shortcut = shortcut
                saveSnippets()
                return
            }
        }
    }
    
    func deleteFolder(id: UUID) {
        folders.removeAll(where: { $0.id == id })
        saveSnippets()
    }
    
    func deleteSnippet(id: UUID) {
        for i in 0..<folders.count {
            folders[i].snippets.removeAll(where: { $0.id == id })
        }
        saveSnippets()
    }
    
    func addFolder(title: String) {
        let newFolder = SnippetFolder(id: UUID(), title: title, snippets: [])
        folders.append(newFolder)
        saveSnippets()
    }
    
    func addSnippet(to folderId: UUID, title: String, content: String) {
        if let index = folders.firstIndex(where: { $0.id == folderId }) {
            let newSnippet = Snippet(id: UUID(), title: title, content: content)
            folders[index].snippets.append(newSnippet)
            saveSnippets()
        }
    }
    
    func updateSnippet(folderId: UUID, snippetId: UUID, title: String, content: String) {
        if let fIndex = folders.firstIndex(where: { $0.id == folderId }),
           let sIndex = folders[fIndex].snippets.firstIndex(where: { $0.id == snippetId }) {
            folders[fIndex].snippets[sIndex].title = title
            folders[fIndex].snippets[sIndex].content = content
            saveSnippets()
        }
    }

    func importFromXML(_ xmlString: String) {
        guard let data = xmlString.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        let delegate = SnippetXMLDelegate()
        parser.delegate = delegate
        if parser.parse() {
            // Append imported folders
            self.folders.append(contentsOf: delegate.importedFolders)
            saveSnippets()
        }
    }
}

class SnippetXMLDelegate: NSObject, XMLParserDelegate {
    var importedFolders: [SnippetFolder] = []
    private var currentFolder: SnippetFolder?
    private var currentSnippet: Snippet?
    private var currentElement = ""
    private var currentText = ""
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
        
        if elementName == "folder" {
            currentFolder = SnippetFolder(id: UUID(), title: "", snippets: [])
        } else if elementName == "snippet" {
            currentSnippet = Snippet(id: UUID(), title: "", content: "")
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")

        if elementName == "title" {
            if var snippet = currentSnippet {
                snippet.title = text
                currentSnippet = snippet
            } else if var folder = currentFolder {
                folder.title = text
                currentFolder = folder
            }
        } else if elementName == "content" {
            if var snippet = currentSnippet {
                snippet.content = text
                currentSnippet = snippet
            }
        } else if elementName == "snippet" {
            if let snippet = currentSnippet {
                currentFolder?.snippets.append(snippet)
            }
            currentSnippet = nil
        } else if elementName == "folder" {
            if let folder = currentFolder {
                importedFolders.append(folder)
            }
            currentFolder = nil
        }
    }
}
