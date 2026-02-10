import Foundation

extension Character {
    var isPrintableASCII: Bool {
        guard let asciiValue = self.asciiValue else { return false }
        // Printable ASCII: 32-126 (space to ~)
        return (32...126).contains(asciiValue)
    }
    
    var isNewline: Bool {
        return self == "\n" || self == "\r"
    }
}