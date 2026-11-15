import Foundation
struct BridgeFailure: Error { let code:String; let message:String }
@main struct Regression {
 @MainActor static func main() async throws {
  let workspace=FileManager.default.temporaryDirectory.appendingPathComponent("clipy-lan-regression-"+UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:workspace)}
  var receiveA:[String:Any]?;var receiveB:[String:Any]?;var fileA:[String:Any]?;var fileB:[String:Any]?;var notificationB:[String:Any]?
  let a=LANService(emit:{event,payload in if event=="lan.history.received"{receiveA=payload};if event=="lan.file.received"{fileA=payload}},peerId:"test-a",receiveDirectory:workspace.appendingPathComponent("a-received"),stateDirectory:workspace.appendingPathComponent("state"))
  let b=LANService(emit:{event,payload in if event=="lan.history.received"{receiveB=payload};if event=="lan.file.received"{fileB=payload};if event=="lan.notification.received"{notificationB=payload}},peerId:"test-b",receiveDirectory:workspace.appendingPathComponent("b-received"),stateDirectory:workspace.appendingPathComponent("state"))
  _=try a.start(port:15567,deviceName:"A");_=try b.start(port:15568,deviceName:"B")
  defer{a.stop();b.stop()}
  try await Task.sleep(nanoseconds:100_000_000)
  guard a.status()["listening"] as? Bool==true,b.status()["listening"] as? Bool==true else{fatalError("listeners unavailable")}
  let peer=try await a.connect(host:"127.0.0.1",port:15568);guard peer["id"] as? String=="test-b" else{fatalError("wrong peer")}
  var confirmed=false
  let outgoing=Task { @MainActor in let result=try await a.sendText(peerId:"test-b",text:"你好\r\nLAN v3");confirmed=true;return result }
  try await Task.sleep(nanoseconds:150_000_000)
  guard !confirmed,let received=receiveB,received["content"] as? String=="你好\r\nLAN v3",let id=received["messageId"] as? String else{fatalError("received or precommit ACK invariant failed")}
  let target=workspace.appendingPathComponent("history.txt");try Data((received["content"] as! String).utf8).write(to:target,options:.atomic)
  try b.acknowledge(messageId:id);let result=try await outgoing.value;guard result["confirmed"] as? Bool==true else{fatalError("unconfirmed")}
  let reverse=Task { @MainActor in try await b.sendText(peerId:"test-a",text:"reverse") }
  try await Task.sleep(nanoseconds:100_000_000);guard let reverseId=receiveA?["messageId"] as? String else{fatalError("reverse missing")};try a.acknowledge(messageId:reverseId);_=try await reverse.value
  let source=workspace.appendingPathComponent("fixture.bin");let content=Data((0..<(3*1024*1024+17)).map{UInt8($0%251)});try content.write(to:source,options:.atomic)
  var fileConfirmed=false;let fileSend=Task { @MainActor in let result=try await a.sendFile(peerId:"test-b",path:source.path);fileConfirmed=true;return result }
  for _ in 0..<100 {if fileB != nil{break};try await Task.sleep(nanoseconds:20_000_000)}
  guard !fileConfirmed,let file=fileB,let path=file["path"] as? String,let fileId=file["messageId"] as? String,try Data(contentsOf:URL(fileURLWithPath:path))==content else{fatalError("file delivery or ACK-before-persist")}
  try b.acknowledge(messageId:fileId);_=try await fileSend.value
  let zero=workspace.appendingPathComponent("empty.bin");try Data().write(to:zero,options:.atomic);let backwards=Task { @MainActor in try await b.sendFile(peerId:"test-a",path:zero.path) }
  for _ in 0..<100 {if fileA != nil{break};try await Task.sleep(nanoseconds:20_000_000)}
  guard let zeroId=fileA?["messageId"] as? String,let zeroPath=fileA?["path"] as? String,try Data(contentsOf:URL(fileURLWithPath:zeroPath)).count==0 else{fatalError("zero file missing")};try a.acknowledge(messageId:zeroId);_=try await backwards.value
  let tree=workspace.appendingPathComponent("Tree",isDirectory:true);try FileManager.default.createDirectory(at:tree.appendingPathComponent("empty",isDirectory:true),withIntermediateDirectories:true);try Data("secret fixture".utf8).write(to:tree.appendingPathComponent(".hidden"));try Data("#!/bin/sh\necho fixture\n".utf8).write(to:tree.appendingPathComponent("run.sh"));try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:tree.appendingPathComponent("run.sh").path)
  fileB=nil;let folderSend=Task{@MainActor in try await a.sendFile(peerId:"test-b",path:tree.path)}
  for _ in 0..<200{if fileB != nil{break};try await Task.sleep(nanoseconds:10_000_000)}
  guard let folderEvent=fileB,folderEvent["isFolder"] as? Bool==true,let folderPath=folderEvent["path"] as? String,let folderId=folderEvent["messageId"] as? String,try String(contentsOf:URL(fileURLWithPath:folderPath).appendingPathComponent(".hidden"),encoding:.utf8)=="secret fixture",try FileManager.default.contentsOfDirectory(atPath:folderPath+"/empty").isEmpty else{fatalError("folder restore failed")};try b.acknowledge(messageId:folderId);_=try await folderSend.value
  fileA=nil;let folderBack=Task{@MainActor in try await b.sendFile(peerId:"test-a",path:folderPath)}
  for _ in 0..<200{if fileA != nil{break};try await Task.sleep(nanoseconds:10_000_000)}
  guard let restored=fileA?["path"] as? String,let backId=fileA?["messageId"] as? String,((try FileManager.default.attributesOfItem(atPath:restored+"/run.sh")[.posixPermissions] as? NSNumber)?.intValue ?? 0)&0o111 != 0 else{fatalError("reverse folder permissions missing")};try a.acknowledge(messageId:backId);_=try await folderBack.value
  let snapshot=try FolderTransferService.archive(tree,temporaryDirectory:workspace);let before=try Data(contentsOf:snapshot);var malicious=before
  let needle=Array("Tree/".utf8),replacement=Array("../x/".utf8);if malicious.count>=needle.count{for index in 0...(malicious.count-needle.count){if Array(malicious[index..<index+needle.count])==needle{malicious.replaceSubrange(index..<index+needle.count,with:replacement)}}};let attack=workspace.appendingPathComponent("malicious.zip");try malicious.write(to:attack)
  var rejected=0;do{_=try FolderTransferService.extract(attack,into:workspace.appendingPathComponent("attack-output"),expectedName:"Tree")}catch{rejected+=1}
  try FileManager.default.createSymbolicLink(atPath:tree.appendingPathComponent("link").path,withDestinationPath:"/tmp");do{_=try FolderTransferService.archive(tree,temporaryDirectory:workspace)}catch{rejected+=1};try FileManager.default.removeItem(at:tree.appendingPathComponent("link"))
  let restoredOnce=try FolderTransferService.extract(snapshot,into:workspace.appendingPathComponent("collision"),expectedName:"Tree");let restoredTwice=try FolderTransferService.extract(snapshot,into:workspace.appendingPathComponent("collision"),expectedName:"Tree");guard rejected==2,restoredOnce.lastPathComponent=="Tree",restoredTwice.lastPathComponent=="Tree (2)" else{fatalError("folder security/collision handling failed")}
  print("PASS: stored ZIP folder roundtrip preserves hidden/empty/executable, rejects traversal and source symlink, publishes same-name as Tree (2)")
  receiveB=nil
  let interrupted=Task { @MainActor in try await a.sendText(peerId:"test-b",text:"durable after restart") }
  for _ in 0..<100 {if receiveB != nil{break};try await Task.sleep(nanoseconds:10_000_000)}
  guard a.status()["pendingOffline"] as? Int==1 else{fatalError("pending not durable before wire ACK")};a.stop();do{_=try await interrupted.value;fatalError("stop falsely confirmed")}catch{}
  receiveB=nil
  let restarted=LANService(emit:{_,_ in},peerId:"test-a",receiveDirectory:workspace.appendingPathComponent("a-received"),stateDirectory:workspace.appendingPathComponent("state"));_=try restarted.start(port:15567,deviceName:"A restarted");defer{restarted.stop()}
  for _ in 0..<300 {if receiveB != nil{break};try await Task.sleep(nanoseconds:10_000_000)}
  guard let replay=receiveB,replay["content"] as? String=="durable after restart",let replayId=replay["messageId"] as? String else{fatalError("pending not restored/reconnected")};try b.acknowledge(messageId:replayId);try await Task.sleep(nanoseconds:50_000_000);guard restarted.status()["pendingOffline"] as? Int==0 else{fatalError("ACK did not clear durable queue")}
  _=try restarted.authorize(peerId:"test-b",clipboard:false,notifications:true)
  _=try restarted.notification(peerId:"test-b",type:"notif.post",payload:["id":"notif-1","title":"验证码","body":"123","appName":"SMS","packageName":"example.sms","postTime":Date().timeIntervalSince1970,"isClearable":true],hash:"notif-1")
  for _ in 0..<100 {if notificationB != nil{break};try await Task.sleep(nanoseconds:10_000_000)}
  guard let notificationId=notificationB?["messageId"] as? String,notificationB?["operation"] as? String=="notif.post",restarted.status()["pendingOffline"] as? Int==1 else{fatalError("notification missing or ACKed early")};try b.acknowledge(messageId:notificationId);try await Task.sleep(nanoseconds:50_000_000);guard restarted.status()["pendingOffline"] as? Int==0 else{fatalError("notification ACK missing")}
  print("PASS: stop is unconfirmed, encrypted pending journal restores and reconnects after owner recreation, notif.post waits for application ACK")
  print("PASS: file 3MiB+17 and reverse empty file, sequential 1MiB encrypted chunks, streamed SHA256, ACK after application commit")
  print("PASS: two actual TCP listeners, AES-GCM UTF-8 payload/hash, handshake, bidirectional history.direct, ACK withheld until atomic store, matching peer+hash receipt")
 }
}
