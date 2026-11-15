import Foundation
struct BridgeFailure:Error{let code:String;let message:String}
@main struct SessionArbitrationRegression{
 @MainActor final class Box{var a="";var b="";var received:[String:Any]?;var file:[String:Any]?;var relayWrites=0;var stable=false;var flapped=false}
 @MainActor static func main()async throws{
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("clipy-session-regression-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  for round in 0..<10{
   let box=Box(),directory=root.appendingPathComponent(String(round));let portA=15571+round*2,portB=15572+round*2;let a=LANService(emit:{event,payload in if event=="lan.peers",box.stable,(payload["peers"] as? [Any])?.isEmpty==true{box.flapped=true}},peerId:"a-test",receiveDirectory:directory.appendingPathComponent("a-files"),stateDirectory:directory);let b=LANService(emit:{event,payload in if event=="lan.history.received"{box.received=payload};if event=="lan.file.received"{box.file=payload}},peerId:"b-test",receiveDirectory:directory.appendingPathComponent("b-files"),stateDirectory:directory);defer{a.stop();b.stop()}
   _=try a.start(port:portA,deviceName:"A");_=try b.start(port:portB,deviceName:"B");try await Task.sleep(nanoseconds:20_000_000)
   let one=Task{@MainActor in try await a.connect(host:"127.0.0.1",port:portB)},two=Task{@MainActor in try await b.connect(host:"127.0.0.1",port:portA)};_=try await one.value;_=try await two.value;try await Task.sleep(nanoseconds:40_000_000)
   guard let peersA=a.status()["peers"] as? [[String:Any]],peersA.count==1,peersA[0]["outbound"] as? Bool==true,let peersB=b.status()["peers"] as? [[String:Any]],peersB.count==1,peersB[0]["outbound"] as? Bool==false else{FileHandle.standardError.write(Data("round \(round) A \(a.status()) B \(b.status())\n".utf8));fatalError("crossed dial arbitration")};box.stable=true
   let sending=Task{@MainActor in try await a.sendText(peerId:"b-test",text:"pending-round-\(round)")};for _ in 0..<100{if box.received != nil{break};try await Task.sleep(nanoseconds:1_000_000)}
   let againA=Task{@MainActor in try await a.connect(host:"127.0.0.1",port:portB)},againB=Task{@MainActor in try await b.connect(host:"127.0.0.1",port:portA)};_=try await againA.value;_=try await againB.value;guard let id=box.received?["messageId"] as? String,a.status()["pendingReceipts"] as? Int==1,!box.flapped else{fatalError("duplicate dial interrupted receipt")};try b.acknowledge(messageId:id);_=try await sending.value
   if round==0{
    box.b=try b.openTunnel(id:"standby-a",initiator:false,send:{data in box.relayWrites+=1;try await a.feedTunnel(sessionId:box.a,data:data)})
    box.a=try a.openTunnel(id:"standby-b",initiator:true,send:{data in box.relayWrites+=1;try await b.feedTunnel(sessionId:box.b,data:data)})
    for _ in 0..<100{if a.status()["routeCount"] as? Int==2,b.status()["routeCount"] as? Int==2{break};try await Task.sleep(nanoseconds:1_000_000)};try await Task.sleep(nanoseconds:20_000_000)
    guard (a.status()["peers"] as? [[String:Any]])?.first?["transport"] as? String=="lan",(a.status()["peers"] as? [Any])?.count==1 else{fatalError("relay replaced LAN")}
    box.received=nil;let before=box.relayWrites;let failover=Task{@MainActor in try await a.sendText(peerId:"b-test",text:"survive LAN loss")};for _ in 0..<100{if box.received != nil{break};try await Task.sleep(nanoseconds:1_000_000)};guard box.relayWrites==before else{fatalError("relay used while LAN available")}
    let retry=box.received!["messageId"] as! String;a.disconnectLAN(peerId:"b-test");try await Task.sleep(nanoseconds:100_000_000);guard (a.status()["peers"] as? [[String:Any]])?.first?["transport"] as? String=="relay",a.status()["pendingReceipts"] as? Int==1 else{fatalError("relay fallback or pending receipt lost")};try b.acknowledge(messageId:retry);_=try await failover.value;guard a.status()["pendingOffline"] as? Int==0 else{fatalError("fallback ACK did not clear pending")}
    let filePath=directory.appendingPathComponent("same-sha.txt");try Data("identical bytes".utf8).write(to:filePath);box.received=nil;box.file=nil;var fileConfirmed=false;let fileTask=Task{@MainActor in let result=try await a.sendFile(peerId:"b-test",path:filePath.path);fileConfirmed=true;return result};let textTask=Task{@MainActor in try await a.sendText(peerId:"b-test",text:"identical bytes")};for _ in 0..<100{if box.received != nil,box.file != nil{break};try await Task.sleep(nanoseconds:1_000_000)};guard let textId=box.received?["messageId"] as? String,let fileId=box.file?["messageId"] as? String else{fatalError("same SHA fixtures not received")};try b.acknowledge(messageId:textId);_=try await textTask.value;try await Task.sleep(nanoseconds:20_000_000);guard !fileConfirmed else{fatalError("history ACK falsely confirmed file with same SHA")};try b.acknowledge(messageId:fileId);_=try await fileTask.value
    _=try a.authorize(peerId:"b-test",clipboard:true,notifications:true);let settings=a.status()["peers"] as! [[String:Any]];guard settings[0]["syncClipboard"] as? Bool==true,settings[0]["syncNotifications"] as? Bool==true,JSONSerialization.isValidJSONObject(a.status()) else{fatalError("peer flags lost authorization")}

   }
   box.stable=false;a.stop();b.stop()
  }
  guard !LANService.fileTransferExpired(started:0,progress:130,now:200),LANService.fileTransferExpired(started:0,progress:130,now:250),!LANService.fileTransferExpired(started:0,progress:1700,now:1750),LANService.fileTransferExpired(started:0,progress:1790,now:1800)else{fatalError("file progress/ACK timeout contract")}
  print("PASS: same-SHA history ACK cannot confirm file receipt; persisted sync flags survive peer-row rebuild and status serializes as JSON")
  print("PASS: simultaneous bidirectional TCP connect x10 chooses stable lexicographic role, duplicate dials retain receipts; LAN preferred over relay standby, LAN loss replays pending and confirms over relay; idle/progress/final ACK deadlines")
 }
}
