import AppKit
import Foundation
struct BridgeFailure: Error { let code: String; let message: String }
@main struct CaptureVisionRegression {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--capture-vision-worker" {
            do {
                let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
                let mode = (raw["params"] as? [String: Any])?["_regressionMode"] as? String
                if mode == "slow" { try await Task.sleep(nanoseconds: 5_000_000_000) }
                if mode == "overflow" { try FileHandle.standardOutput.write(contentsOf: Data(repeating: 32, count: 1_100_000)); exit(0) }
                let result = try CaptureVisionService.runWorker(jobPath: CommandLine.arguments[2])
                try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result)); exit(0)
            } catch let failure as BridgeFailure {
                try? FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: ["error": ["code": failure.code, "message": failure.message]])); exit(1)
            } catch { exit(1) }
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-capture-vision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        NSColor.white.setFill();NSRect(x: 0, y: 0, width: 1200, height: 400).fill()
        ("SYNTHETIC HELLO WORLD" as NSString).draw(at: NSPoint(x: 70, y: 270), withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
        ("test@example.com" as NSString).draw(at: NSPoint(x: 70, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let path = root.appendingPathComponent("synthetic.png")
        try image.representation(using: .png, properties: [:])!.write(to: path)
        let service = CaptureVisionService(root: root)
        let result = try await service.invoke("ocr.recognize", ["path": path.path])
        assert(result["width"] as? Int == 1200 && result["height"] as? Int == 400)
        assert(result["coordinateSpace"] as? String == "source-pixels-top-left")
        let rows = result["rows"] as! [[String: Any]]
        let hello = rows.first { ($0["text"] as? String ?? "").contains("HELLO") }!
        let box = hello["rect"] as! [String: Double]
        assert(box["x"]! > 30 && box["y"]! < 150 && box["width"]! > 300, "bbox must remain original top-left pixels")
        let redacted = try await service.invoke("image.redact", ["imagePath": path.path, "categories": ["privacy"]])
        assert((redacted["annotations"] as? [[String: Any]])?.isEmpty == false)
        let highlighted = try await service.invoke("image.smartHighlight", ["imagePath": path.path, "rect": ["x": 0, "y": 0, "width": 1200, "height": 400]])
        assert((highlighted["annotations"] as? [[String: Any]])?.isEmpty == false)
        func code(_ work: Task<[String: Any], Error>) async -> String {
            do { _ = try await work.value; return "NO_ERROR" } catch let error as BridgeFailure { return error.code } catch is CancellationError { return "CANCELLED" } catch { return "OTHER" }
        }
        let overflow = Task { try await service.invoke("ocr.recognize", ["path": path.path, "_regressionMode": "overflow"]) }
        let overflowCode = await code(overflow);assert(overflowCode == "WORKER_OUTPUT_TOO_LARGE")
        let one = Task { try await service.invoke("ocr.recognize", ["path": path.path, "_regressionMode": "slow"]) }
        let two = Task { try await service.invoke("ocr.recognize", ["path": path.path, "_regressionMode": "slow"]) }
        try await Task.sleep(nanoseconds: 80_000_000)
        let third = Task { try await service.invoke("ocr.recognize", ["path": path.path]) }
        let busyCode = await code(third);assert(busyCode == "BUSY")
        service.cancelAll()
        let oneCode = await code(one), twoCode = await code(two);assert(oneCode == "CANCELLED" && twoCode == "CANCELLED")
        let timed = CaptureVisionService(root: root, timeout: 0.15)
        let timeout = Task { try await timed.invoke("ocr.recognize", ["path": path.path, "_regressionMode": "slow"]) }
        let timeoutCode = await code(timeout);assert(timeoutCode == "TIMEOUT")
        let cancelled = Task { try await service.invoke("ocr.recognize", ["path": path.path, "_regressionMode": "slow"]) }
        try await Task.sleep(nanoseconds: 50_000_000);cancelled.cancel()
        let cancelledCode = await code(cancelled);assert(cancelledCode == "CANCELLED")
        let remaining = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("capture-vision-jobs"), includingPropertiesForKeys: nil)
        assert(remaining.isEmpty)
        print("PASS capture Vision short-lived OCR bbox, redact/highlight, bounded drain, two-child limit, cancel/generation, timeout, private job cleanup; synthetic-only")
    }
}
