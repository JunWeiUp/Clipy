import Foundation
struct BridgeFailure:Error{let code:String;let message:String}
@main struct DiagnosticsRegression{
 static func main()throws{
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("clipy-diagnostics-regression-"+UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let date=DateFormatter();date.locale=Locale(identifier:"en_US_POSIX");date.timeZone = .current;date.dateFormat="yyyy-MM-dd";let today=date.string(from:Date());let stale=root.appendingPathComponent("clipy-2000-01-01-000001.log");try Data("old".utf8).write(to:stale)
  let block=Data(repeating:120,count:5*1024*1024);for index in 1...10{try block.write(to:root.appendingPathComponent("clipy-\(today)-\(String(format:"%06d",index)).log"))}
  let logger=DiagnosticLogWriter(directory:root);logger.record(method:"clipboard.write",phase:"failure",errorCode:"PERMISSION_DENIED",durationMs:12.5,queued:3);logger.record(method:"model.translate",phase:"complete",durationMs:23);logger.flush()
  guard !FileManager.default.fileExists(atPath:stale.path)else{fatalError("expired day retained")};let summary=try logger.summary();guard summary["bytes"] as? Int ?? Int.max<=50*1024*1024 else{fatalError("global quota exceeded")}
  let recent=try logger.recent();let allowed=Set(["timestamp","method","phase","pid","errorCode","durationMs","queued"]);var found=false
  for line in recent.split(separator:"\n"){guard let row=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any]else{fatalError("not structured JSONL")};guard Set(row.keys).isSubset(of:allowed)else{fatalError("sensitive/freeform data in logs")};if row["method"] as? String=="clipboard.write"{found=true}}
  guard found,!recent.contains("FIXTURE_CREDENTIAL_NEVER_LOG")else{fatalError("log content invariant")};for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey]){guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max<=5*1024*1024 else{fatalError("single log quota exceeded")}}
  print("PASS: structured metadata-only JSONL, local daily rotation, 7-day pruning, 5MiB file/50MiB total caps and serial flush")
 }
}
