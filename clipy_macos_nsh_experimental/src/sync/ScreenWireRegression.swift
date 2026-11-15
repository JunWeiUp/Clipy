import Foundation
import CryptoKit
struct BridgeFailure:Error{let code:String;let message:String}
@main struct ScreenWireRegression{
 @MainActor final class Box{var buffer=Data();var frames:[[String:Any]]=[];var actions:[String]=[]}
 @MainActor static func main()async throws{
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("clipy-screen-wire-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)};let box=Box();let service=LANService(emit:{_,_ in},peerId:"screen-mac",stateDirectory:root);defer{service.stop()};var configured=true
  service.screenStateProvider={ ["configured":configured,"helper":true,"locked":true] };service.screenCommandHandler={action in box.actions.append(action);return action=="lock" ? "notConfirmed":"ok"}
  let session=try service.openTunnel(id:"mock-phone",initiator:false,send:{data in box.buffer.append(data);while box.buffer.count>=4{let count=box.buffer.prefix(4).reduce(0){($0<<8)|Int($1)};guard box.buffer.count>=count+4 else{return};let body=Data(box.buffer.dropFirst(4).prefix(count));box.buffer=Data(box.buffer.dropFirst(count+4));box.frames.append(try JSONSerialization.jsonObject(with:body) as! [String:Any])}})
  let key=SymmetricKey(data:SHA256.hash(data:Data("ClipySyncSecret2026".utf8)))
  func feed(_ type:String,_ payload:[String:Any]?=nil)async throws->String{let id=UUID().uuidString;var envelope:[String:Any]=["v":3,"type":type,"peerId":"phone-test","name":"Phone","port":0,"msgId":id,"ts":Date().timeIntervalSince1970];if let payload{envelope["payload"]=try AES.GCM.seal(JSONSerialization.data(withJSONObject:payload),using:key).combined!.base64EncodedString()};let body=try JSONSerialization.data(withJSONObject:envelope);var length=UInt32(body.count).bigEndian;var frame=Data(bytes:&length,count:4);frame.append(body);try await service.feedTunnel(sessionId:session,data:frame);return id}
  func wait(_ type:String)async throws->[String:Any]{for _ in 0..<100{if let index=box.frames.firstIndex(where:{$0["type"] as? String==type}){return box.frames.remove(at:index)};try await Task.sleep(nanoseconds:1_000_000)};fatalError("missing response "+type)}
  func decode(_ frame:[String:Any])throws->[String:Any]{let combined=Data(base64Encoded:frame["payload"] as! String)!;return try JSONSerialization.jsonObject(with:AES.GCM.open(AES.GCM.SealedBox(combined:combined),using:key)) as! [String:Any]}
  func challenge()async throws->String{_=try await feed("screen.query");let frame=try await wait("screen.state");let payload=try decode(frame);guard payload["controlMode"] as? String=="connected-v1" else{fatalError("wrong capability")};return payload["challenge"] as! String}
  _=try await feed("hello");_=try await wait("welcome")
  let first=try await challenge();let command=try await feed("screen.command",["action":"lock","challenge":first]);let unconfirmed=try await wait("screen.result");guard unconfirmed["hash"] as? String==command,try decode(unconfirmed)["status"] as? String=="notConfirmed" else{fatalError("request mistaken for confirmation")}
  _=try await feed("screen.command",["action":"lock","challenge":first]);guard try decode(await wait("screen.result"))["status"] as? String=="sessionUnavailable",box.actions.count==1 else{fatalError("nonce reused")}
  let second=try await challenge();_=try await feed("screen.command",["action":"unlock","challenge":second]);guard try decode(await wait("screen.result"))["status"] as? String=="ok"else{fatalError("unlock wire result")}
  let third=try await challenge();_=try await feed("screen.command",["action":"unlock","challenge":third]);guard try decode(await wait("screen.result"))["status"] as? String=="cooldown",box.actions.count==2 else{fatalError("unlock cooldown missing")}
  let fourth=try await challenge();_=try await feed("screen.command",["action":"lock","challenge":fourth]);_=try await wait("screen.result");guard box.actions.count==3 else{fatalError("lock incorrectly shares unlock cooldown")}
  configured=false;let disabled=try await challenge();_=try await feed("screen.command",["action":"lock","challenge":disabled]);guard try decode(await wait("screen.result"))["status"] as? String=="notConfigured",box.actions.count==3 else{fatalError("disabled control executed")}
  print("PASS: mock-only screen v3 encrypted state/result, peer-bound one-use challenge, no request-as-success, unlock-only cooldown and disabled-config check; no real screen action")
 }
}
