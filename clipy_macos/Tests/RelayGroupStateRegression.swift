import Foundation
#if canImport(CommonRelay)
import CommonRelay
#endif
@main struct RelayGroupStateRegression {
    static func main() {
        let old: [String:Any] = ["app":"clipy","group":"existing-group","device":"existing-mac","token":String(repeating:"t",count:32),"secret_key":String(repeating:"01",count:32),"trusted_peers":["phone":"public-test-key"]]
        precondition(SyncRelayGroupState.classify(old) == .legacy,"Existing transport enrollment must not be shown as a new device")
        var managed = old;managed["group_entry"] = ["payload":"cached-test-record"]
        precondition(SyncRelayGroupState.classify(managed) == .managed,"Cached signed enrollment must survive network failure")
        precondition(SyncRelayGroupState.classify([:]) == .unconfigured)
        precondition(old["group"] as? String == "existing-group")
        for length in [8, 128] {
            precondition(SyncRelayAccessPolicy.validPassword(String(repeating: "!", count: length)))
        }
        precondition(SyncRelayAccessPolicy.validPassword(String((0x21...0x7e).map { Character(UnicodeScalar($0)!) })))
        for value in ["", "short", String(repeating: "a", count: 129), " leading", "trailing ", "with gap", "with\tTAB", "with\nline", "test\rline", "aaaaaaa\u{7f}", "aaaaaaa\u{0}", "密码abcdefgh", "éabcdefg"] {
            precondition(!SyncRelayAccessPolicy.validPassword(value), "Invalid credential accepted")
            precondition((try? SyncRelayAccessPolicy.validate(value)) == nil)
        }
        let secret = "Fixture-Only!123"
        let authenticated = SyncRelayAccessPolicy.applying(secret, to: managed)
        precondition(authenticated["password"] as? String == secret)
        precondition(authenticated["secret_key"] as? String == managed["secret_key"] as? String)
        precondition(authenticated["token"] as? String == managed["token"] as? String)
        precondition(SyncRelayGroupState.classify(authenticated) == .managed)
        let persisted = SyncRelayAccessPolicy.applying(nil, to: authenticated)
        precondition(persisted["password"] == nil, "Password must remain separate from enrollment/drafts")
        precondition(persisted["device"] as? String == "existing-mac")
        precondition(persisted["trusted_peers"] as? [String:String] == old["trusted_peers"] as? [String:String])
        let updated = SyncRelayAccessPolicy.applying("Rotated-Fixture!", to: authenticated)
        precondition(updated["password"] as? String == "Rotated-Fixture!", "Retries must use the latest credential")
        let invitation: [String:Any] = ["app":"clipy", "id":"fixture", "password":secret,
                                      "short_link":"common-relay://relay.example/i/fixture#key.encoded-secret"]
        let exported = SyncRelayAccessPolicy.invitationForExport(invitation)
        precondition(exported["password"] == nil && exported["short_link"] as? String == invitation["short_link"] as? String)
        precondition(exported["id"] as? String == "fixture")
        let cleanLink = "common-relay://relay.example/i/fixture#key"
        precondition(SyncRelayAccessPolicy.invitationForExport(["short_link":cleanLink])["short_link"] as? String == cleanLink)
        let nested: [String:Any] = ["password":secret,"enrollment_invitation":invitation,
            "pending_join":["invitation":invitation],"array":[["password":secret,"device":"phone"]]]
        let scrubbed = SyncRelayAccessPolicy.applying(nil,to:nested)
        precondition((scrubbed["enrollment_invitation"] as? [String:Any])?["password"] == nil)
        let pending = scrubbed["pending_join"] as! [String:Any]
        precondition((pending["invitation"] as! [String:Any])["password"] == nil)
        precondition((scrubbed["array"] as! [[String:Any]])[0]["password"] == nil)
        let endpoint = "wss://relay.example/relay/v1/ws"
        precondition(try! SyncRelayAccessPolicy.invitationPassword(url:endpoint,configuredURL:endpoint,supplied:secret,saved:nil) == secret)
        precondition(try! SyncRelayAccessPolicy.invitationPassword(url:endpoint,configuredURL:endpoint,supplied:secret,saved:"Old-Fixture!") == secret)
        precondition(try! SyncRelayAccessPolicy.invitationPassword(url:endpoint,configuredURL:endpoint,supplied:nil,saved:secret) == secret)
        do {
            _ = try SyncRelayAccessPolicy.invitationPassword(url:endpoint,configuredURL:endpoint,supplied:nil,saved:nil)
            preconditionFailure("Old invitation must explain the missing credential")
        } catch SyncRelayAccessPolicy.InvitationFailure.missingPassword { } catch { preconditionFailure("Wrong fallback") }
        for supplied in [nil, secret] {
            do {
                _ = try SyncRelayAccessPolicy.invitationPassword(url:"wss://other.example/relay/v1/ws",configuredURL:endpoint,supplied:supplied,saved:secret)
                preconditionFailure("Foreign invitations must be rejected before requests or writes")
            } catch SyncRelayAccessPolicy.InvitationFailure.differentRelay { } catch { preconditionFailure("Wrong scope error") }
        }
        var snapshot = authenticated;snapshot["url"] = endpoint
        precondition(SyncRelayAccessPolicy.sameRequestConfiguration(snapshot,snapshot))
        for key in ["url","device","group","token","secret_key","password"] {
            var changed = snapshot;changed[key] = "changed"
            precondition(!SyncRelayAccessPolicy.sameRequestConfiguration(snapshot,changed),"Late callback must not write after configuration changes")
        }
        precondition(SyncRelayAccessPolicy.isAuthenticationMessage("group HTTP 401"))
        for error in ["group HTTP 403", "group HTTP 404", "group HTTP 500", "network timeout 401ms", "identity mismatch", "401"] {
            precondition(!SyncRelayAccessPolicy.isAuthenticationMessage(error))
        }
        #if canImport(CommonRelay)
        do {
            let key = Data(repeating:7,count:32)
            let fixture: [String:Any] = ["url":endpoint,"id":String(repeating:"ab",count:16)]
            let oldLink = try RelayInvitationLinks.make(fixture,key:key)
            let parsed = try RelayInvitationLinks.parse(oldLink)
            precondition(parsed.password == nil)
            let upgraded = try RelayInvitationLinks.make(fixture,key:parsed.key,password:secret)
            let imported = try RelayInvitationLinks.parse(upgraded)
            precondition(imported.password == secret && imported.url == endpoint && imported.key == key)
            let rotated = try RelayInvitationLinks.make(fixture,key:imported.key,password:"Rotated-Fixture!")
            let rotation = try RelayInvitationLinks.parse(rotated)
            precondition(rotation.password == "Rotated-Fixture!" && rotation.id == parsed.id)
            precondition(URLComponents(string:upgraded)?.percentEncodedPath == URLComponents(string:oldLink)?.percentEncodedPath)
            let bad = String(oldLink.prefix(through:oldLink.firstIndex(of:"#")!)) + RelayInvitationLinks.base64url(key) + ".%%%"
            precondition((try? RelayInvitationLinks.parse(bad)) == nil)
        } catch { preconditionFailure("SDK invitation codec regression: \(error)") }
        #endif
        print("Relay enrollment, access credential and invitation regressions passed")
    }
}
