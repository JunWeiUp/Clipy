import Foundation
import ScreenCaptureKit
struct BridgeFailure:Error { let code:String;let message:String }
@main struct CaptureAccessRegression {
    static func main() throws {
        let declined = NSError(domain:SCStreamError.errorDomain,code:SCStreamError.Code.userDeclined.rawValue)
        guard let permission = CaptureAccessPolicy.mapped(declined) as? BridgeFailure,permission.code == "PERMISSION_DENIED",permission.message.contains("系统拒绝") else { fatalError("exact user decline not mapped") }
        for code in [-3802,-3803,-3812,-3818] {
            let error = NSError(domain:SCStreamError.errorDomain,code:code)
            guard let failure = CaptureAccessPolicy.mapped(error) as? BridgeFailure,failure.code == "SCK_ERROR_\(code)",failure.message.contains(String(code)),failure.code != "PERMISSION_DENIED" else { fatalError("non-permission SCK error misclassified") }
        }
        let unrelated = NSError(domain:NSCocoaErrorDomain,code:-3801,userInfo:[NSLocalizedDescriptionKey:"private description must not be copied"])
        guard let other = CaptureAccessPolicy.mapped(unrelated) as? BridgeFailure,other.code != "PERMISSION_DENIED",other.message.contains(NSCocoaErrorDomain),other.message.contains("-3801"),!other.message.contains("private description") else { fatalError("same integer in another domain treated as permission") }
        let wrapper = NSError(domain:NSCocoaErrorDomain,code:1,userInfo:[NSUnderlyingErrorKey:declined])
        guard (CaptureAccessPolicy.mapped(wrapper) as? BridgeFailure)?.code == "PERMISSION_DENIED" else { fatalError("underlying SCK rejection lost") }
        let existing = BridgeFailure(code:"WINDOW_GONE",message:"synthetic")
        guard (CaptureAccessPolicy.mapped(existing) as? BridgeFailure)?.code == "WINDOW_GONE",CaptureAccessPolicy.mapped(CancellationError()) is CancellationError else { fatalError("business/cancellation error overwritten") }
        print("PASS: exact SCK decline, non-permission diagnostic codes, foreign-domain same integer, wrapped denial, safe message and cancellation; no capture/permission APIs called")
    }
}
