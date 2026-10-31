import Foundation

extension SyncManager {
    func sendScreenState(to id: String) {
        guard let session = sessions[id] else { return }
        let fd = session.fd
        let challenge = UUID().uuidString
        sessions[id]?.screenAuthorization = ScreenControlChallenge(token: challenge)
        DispatchQueue.main.async {
            let payload: [String: Any] = ["controlMode": "connected-v1", "configured": ScreenControlManager.shared.configured,
                                         "locked": ScreenControlManager.locked as Any? ?? NSNull(),
                                         "helper": ScreenControlManager.unlockReady,
                                         "challenge": challenge]
            guard let bytes = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: bytes, encoding: .utf8) else { return }
            self.syncQueue.async {
                guard self.sessions[id]?.fd == fd, self.sessions[id]?.screenAuthorization?.token == challenge else { return }
                self.writeScreenMessage("screen.state", text: text, to: id)
            }
        }
    }
    func writeScreenMessage(_ type: String, text: String, to id: String, request: String? = nil) {
        guard let payload = encrypt(text), let frame = encodeFrame(.make(type: type, peerId: peerId, hash: request, payload: payload)), let fd = sessions[id]?.fd else { return }
        _ = sendSessionFrame(fd, frame)
    }
    func handleScreenCommand(_ env: SyncEnvelope, from id: String) {
        guard env.peerId == id, let session = sessions[id],
              var authorization = session.screenAuthorization,
              let text = decryptPayload(env, from: id), text.utf8.count <= 2048,
              let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let action = object["action"], ["lock", "unlock"].contains(action), let token = object["challenge"],
              authorization.consume(token: token, action: action) else { return }
        // Consume before dispatch: duplicates and captured commands cannot run twice.
        sessions[id]?.screenAuthorization = authorization
        let fd = session.fd
        let acceptedGeneration = serviceGeneration
        DispatchQueue.main.async {
            self.scanStateLock.lock()
            let current = self.serviceGeneration == acceptedGeneration
            self.scanStateLock.unlock()
            guard current else { return }
            ScreenControlManager.shared.perform(action) { result in
                self.syncQueue.async {
                    guard self.sessions[id]?.fd == fd else { return }
                    let receipt = ["status": result, "challenge": authorization.token]
                    if let bytes = try? JSONSerialization.data(withJSONObject: receipt), let text = String(data: bytes, encoding: .utf8) {
                        self.writeScreenMessage("screen.result", text: text, to: id, request: env.msgId)
                    }
                    self.sendScreenState(to: id)
                }
            }
        }
    }
}
