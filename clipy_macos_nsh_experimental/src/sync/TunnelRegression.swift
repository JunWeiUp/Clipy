import Foundation
struct BridgeFailure:Error{let code:String;let message:String}
@main struct TunnelRegression{
 @MainActor final class Box{var c="";var d="";var received:[[String:Any]]=[]}
 @MainActor static func main()async throws{
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("clipy-tunnel-regression-"+UUID().uuidString,isDirectory:true);defer{try? FileManager.default.removeItem(at:root)}
  let box=Box();let c=LANService(emit:{_,_ in},peerId:"tunnel-c",stateDirectory:root);let d=LANService(emit:{event,payload in if event=="lan.history.received"{box.received.append(payload)}},peerId:"tunnel-d",stateDirectory:root);defer{c.stop();d.stop()}
  box.d=try d.openTunnel(id:"c",initiator:false,send:{bytes in for offset in stride(from:0,to:bytes.count,by:65519){try await c.feedTunnel(sessionId:box.c,data:Data(bytes.dropFirst(offset).prefix(65519)));await Task.yield()}})
  box.c=try c.openTunnel(id:"d",initiator:true,send:{bytes in for offset in stride(from:0,to:bytes.count,by:65519){try await d.feedTunnel(sessionId:box.d,data:Data(bytes.dropFirst(offset).prefix(65519)));await Task.yield()}})
  for _ in 0..<100{if (c.status()["peers"] as? [[String:Any]])?.count==1{break};try await Task.sleep(nanoseconds:1_000_000)}
  let one=String(repeating:"甲",count:120000),two=String(repeating:"乙",count:120000)
  let first=Task{@MainActor in try await c.sendText(peerId:"tunnel-d",text:one)};let second=Task{@MainActor in try await c.sendText(peerId:"tunnel-d",text:two)}
  for _ in 0..<200{if box.received.count==2{break};try await Task.sleep(nanoseconds:10_000_000)}
  guard box.received.count==2,Set(box.received.compactMap{$0["content"] as? String})==Set([one,two])else{fatalError("interleaved tunnel frames")}
  for row in box.received{try d.acknowledge(messageId:row["messageId"] as! String)}
  _=try await first.value;_=try await second.value
  var closed=0,handle="";let lifecycle=LANService(emit:{_,_ in},peerId:"callback-test",stateDirectory:root.appendingPathComponent("callback"));handle=try lifecycle.openTunnel(id:"callback",initiator:false,send:{_ in},onClose:{closed+=1;lifecycle.closeTunnel(sessionId:handle)});lifecycle.closeTunnel(sessionId:handle);lifecycle.closeTunnel(sessionId:handle);lifecycle.stopAll();guard closed==1 else{fatalError("tunnel close callback not exactly once")};print("PASS: tunnel onClose runs once after teardown, recursive/duplicate close and stopAll do not invoke it again")
  print("PASS: two concurrent 360KB UTF8 history frames survive 65519-byte yielded tunnel records without interleaving; v3 AES/hash/ACK reused")
 }
}
