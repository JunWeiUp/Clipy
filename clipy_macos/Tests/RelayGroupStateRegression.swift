import Foundation
@main struct RelayGroupStateRegression {
    static func main() {
        let old: [String:Any] = ["app":"clipy","group":"existing-group","device":"existing-mac","token":String(repeating:"t",count:32),"secret_key":String(repeating:"01",count:32),"trusted_peers":["phone":"public-test-key"]]
        precondition(SyncRelayGroupState.classify(old) == .legacy,"Existing transport enrollment must not be shown as a new device")
        var managed = old;managed["group_entry"] = ["payload":"cached-test-record"]
        precondition(SyncRelayGroupState.classify(managed) == .managed,"Cached signed enrollment must survive network failure")
        precondition(SyncRelayGroupState.classify([:]) == .unconfigured)
        precondition(old["group"] as? String == "existing-group")
        print("Relay group enrollment state regressions passed")
    }
}
