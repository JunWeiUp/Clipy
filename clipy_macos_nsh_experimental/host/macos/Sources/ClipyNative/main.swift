import AppKit
import Foundation

/// Stdout is reserved for newline JSON-RPC. No port or shared rendezvous file exists.
enum BridgeOutput {
    static let lock = NSLock()
    static func write(_ value:[String:Any]) {
        guard JSONSerialization.isValidJSONObject(value),let data = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else { return }
        lock.lock();defer { lock.unlock() };do { try FileHandle.standardOutput.write(contentsOf:data+Data([10])) } catch { exit(0) }
    }
}
if CommandLine.arguments.count == 3,CommandLine.arguments[1] == "--history-ocr-worker" {
    do { BridgeOutput.write(try HistoryStorageService.runOCRWorker(path:CommandLine.arguments[2]));exit(0) }
    catch { BridgeOutput.write(["error":"OCR_WORKER_FAILED"]);exit(1) }
}
if CommandLine.arguments.count == 4,CommandLine.arguments[1] == "--image-foreground-worker" {
    do { try ImageEditorService.foregroundMaskWorker(sourcePath:CommandLine.arguments[2],maskPath:CommandLine.arguments[3]);exit(0) }
    catch { exit(1) }
}
if CommandLine.arguments.count == 3,CommandLine.arguments[1] == "--capture-vision-worker" {
    do { BridgeOutput.write(try CaptureVisionService.runWorker(jobPath:CommandLine.arguments[2]));exit(0) }
    catch let failure as BridgeFailure { BridgeOutput.write(["error":["code":failure.code,"message":failure.message]]);exit(1) }
    catch { BridgeOutput.write(["error":["code":"CAPTURE_VISION_FAILED","message":"图片识别失败，请重试"]]);exit(1) }
}
MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let arguments = CommandLine.arguments
let root:URL
if let i = arguments.firstIndex(of:"--data-dir"),i+1 < arguments.count { root = URL(fileURLWithPath:arguments[i+1]).standardizedFileURL }
else { root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ClipyTSX-Experimental/native") }
let service:NativeService
 do { service = try NativeService(root:root) }
 catch let error as BridgeFailure {
    BridgeOutput.write(["event":"native.startupError","payload":["code":error.code,"message":error.message]]);exit(78)
 } catch {
    BridgeOutput.write(["event":"native.startupError","payload":["code":"STARTUP_FAILED","message":"无法读取本机数据，原数据已保留；请检查储存空间、访问权限或恢复备份"]]);exit(78)
 }
var inFlight = 0
var tasks:[String:Task<Void,Never>] = [:]
Thread.detachNewThread {
    while let line = readLine() {
        guard line.utf8.count <= 1024*1024,let data = line.data(using:.utf8),let request = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let id = request["id"] as? String,let method = request["method"] as? String,id.count <= 128 else { BridgeOutput.write(["id":"","ok":false,"error":["code":"INVALID_REQUEST","message":"无效请求"]]);continue }
        Task { @MainActor in
            guard tasks[id] == nil else { BridgeOutput.write(["id":id,"ok":false,"error":["code":"DUPLICATE_ID","message":"请求编号正在使用"]]);return }
            if method == "task.cancel" { let target = (request["params"] as? [String:Any])?["requestId"] as? String ?? "";tasks[target]?.cancel();BridgeOutput.write(["id":id,"ok":true,"result":true]);return }
            guard inFlight < 32 else { BridgeOutput.write(["id":id,"ok":false,"error":["code":"BUSY","message":"请求过多"]]);return };inFlight += 1
            let operation = Task { @MainActor in
            defer { inFlight -= 1;tasks.removeValue(forKey:id) }
            let started = ProcessInfo.processInfo.systemUptime
            service.diagnostics.record(method:method,phase:"start",queued:inFlight)
            do { let result = try await service.invoke(method,request["params"] as? [String:Any] ?? [:]);service.diagnostics.record(method:method,phase:"complete",durationMs:(ProcessInfo.processInfo.systemUptime-started)*1000);BridgeOutput.write(["id":id,"ok":true,"result":result]) }
            catch let error as BridgeFailure { service.diagnostics.record(method:method,phase:"failure",errorCode:error.code,durationMs:(ProcessInfo.processInfo.systemUptime-started)*1000);BridgeOutput.write(["id":id,"ok":false,"error":["code":error.code,"message":error.message]]) }
            catch is CancellationError { service.diagnostics.record(method:method,phase:"cancelled",errorCode:"CANCELLED");BridgeOutput.write(["id":id,"ok":false,"error":["code":"CANCELLED","message":"操作已取消"]]) }
            catch let error as URLError where error.code == .cancelled { service.diagnostics.record(method:method,phase:"cancelled",errorCode:"CANCELLED");BridgeOutput.write(["id":id,"ok":false,"error":["code":"CANCELLED","message":"操作已取消"]]) }
            catch { service.diagnostics.record(method:method,phase:"failure",errorCode:"NATIVE_ERROR",durationMs:(ProcessInfo.processInfo.systemUptime-started)*1000);BridgeOutput.write(["id":id,"ok":false,"error":["code":"NATIVE_ERROR","message":String(describing:error)]]) }
            };tasks[id] = operation
        }
    }
    DispatchQueue.main.async { service.close();app.terminate(nil) }
}
app.run()

}
