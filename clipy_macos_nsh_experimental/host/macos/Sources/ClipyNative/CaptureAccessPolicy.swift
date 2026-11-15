import Foundation
import ScreenCaptureKit

/// A legacy CoreGraphics preflight is only a passive UI hint. Explicit capture
/// actions go to ScreenCaptureKit, whose real result is authoritative.
enum CaptureAccessPolicy {
    static func mapped(_ error:Error) -> Error {
        if error is BridgeFailure || error is CancellationError { return error }
        let original = error as NSError
        var current = original
        var visited = Set<ObjectIdentifier>()
        for _ in 0..<5 {
            guard visited.insert(ObjectIdentifier(current)).inserted else { break }
            if current.domain == SCStreamError.errorDomain {
                if current.code == SCStreamError.Code.userDeclined.rawValue {
                    return BridgeFailure(code:"PERMISSION_DENIED",message:"系统拒绝了屏幕捕获。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许本应用；若已允许，请完全退出本应用后重新打开。")
                }
                return BridgeFailure(code:"SCK_ERROR_\(current.code)",message:"屏幕捕获失败（\(current.domain) / \(current.code)），请附上此诊断码排查。")
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        let domain = String(original.domain.unicodeScalars.prefix(48).map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-" ? Character(String(scalar)):"_"
        })
        return BridgeFailure(code:"CAPTURE_ERROR_\(domain)_\(original.code)",message:"屏幕捕获失败（\(original.domain) / \(original.code)），请附上此诊断码排查。")
    }
}
