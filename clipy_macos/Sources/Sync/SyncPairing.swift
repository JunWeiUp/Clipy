import AppKit
import CoreImage
import Security

/// Pairing code generation and the `clipy://pair` link shown as a QR code.
/// Android registers the scheme, so the system camera can import the code
/// (and this Mac's address) without typing. See docs/PROTOCOL.md "Pairing".
enum SyncPairing {
    /// Crockford base32 without I/L/O/U — unambiguous when read aloud or typed.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 20 symbols × 5 bits = 100 bits of CSPRNG entropy, `XXXX-XXXX-…` groups.
    static func generateCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        // 256 is a multiple of 32, so `% 32` is unbiased.
        let symbols = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: symbols.count, by: 4)
            .map { String(symbols[$0..<min($0 + 4, symbols.count)]) }
            .joined(separator: "-")
    }

    static func pairingURL(secret: String, host: String?, port: UInt16, name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "clipy"
        components.host = "pair"
        var items = [URLQueryItem(name: "code", value: secret), URLQueryItem(name: "port", value: String(port))]
        if let host, !host.isEmpty { items.append(URLQueryItem(name: "host", value: host)) }
        if !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        components.queryItems = items
        return components.url
    }

    static func qrImage(for text: String, dimension: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, floor(dimension / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

extension SyncManager {
    /// Saves the pairing secret and restarts the service so every session is
    /// re-handshaken with the new key (old sessions would keep the old key).
    func applyPairingSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != PreferencesManager.shared.syncPairingSecret else { return }
        PreferencesManager.shared.syncPairingSecret = trimmed
        diagnostics.reset()
        appLog(trimmed.isEmpty ? "Pairing secret cleared — sync paused" : "Pairing secret updated")
        if PreferencesManager.shared.isSyncEnabled || NotificationManager.shared.notificationSyncEnabled {
            restartService()
        }
    }
}
