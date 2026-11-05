import AppKit
import Foundation
import ImageIO

private func ocrCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("OCR memory regression: \(message)") }
}

func runOCRMemoryRegressionTests() {
    // Success with no lines is deliberately different from an unavailable/failed worker.
    let empty = try! JSONDecoder().decode(OCRResponse.self, from: Data(#"{"status":"success","observations":[],"qrCodes":[],"boxes":[]}"#.utf8))
    ocrCheck((try? empty.validated().text) == "", "empty success became failure")
    ocrCheck((try? OCRResponse(status: .failure).validated()) == nil, "worker failure became empty success")
    let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)
    let observation = OCRTextObservation(text: "hello 世界", boundingBox: box, matchedBoxes: [box])
    let response = OCRResponse(status: .success, observations: [observation], qrCodes: ["https://example.invalid"])
    ocrCheck((try? OCRResponse.recognized(observations: [], qrCodes: [], textError: nil, qrError: nil))?.text == "",
             "genuinely empty combined recognition should succeed")
    ocrCheck((try? OCRResponse.recognized(observations: [], qrCodes: [], textError: nil, qrError: OCRServiceError.workerFailed)) == nil,
             "QR failure was disguised as an empty result")
    ocrCheck((try? OCRResponse.recognized(observations: [observation], qrCodes: [], textError: nil, qrError: OCRServiceError.workerFailed))?.text == observation.text,
             "QR failure lost successful text")
    ocrCheck((try? OCRResponse.recognized(observations: [], qrCodes: ["QR"], textError: OCRServiceError.workerFailed, qrError: nil))?.qrCodes == ["QR"],
             "text failure lost successful QR")
    let roundTrip = try! JSONDecoder().decode(OCRResponse.self, from: JSONEncoder().encode(response))
    ocrCheck(try! roundTrip.validated().observations == [observation], "geometry/text lost across child protocol")
    ocrCheck((try? OCRResponse(status: .success, observations: [OCRTextObservation(text: String(repeating: "a", count: 131_073), boundingBox: box)]).validated()) == nil,
             "text result limit missing")

    let token = OCRTask()
    var cancelledCalls = 0
    token.onCancel { cancelledCalls += 1 }
    token.cancel(); token.cancel()
    ocrCheck(cancelledCalls == 1 && token.isCancelled, "cancellation must be idempotent")
    let neverLaunch = Process()
    neverLaunch.executableURL = URL(fileURLWithPath: "/does-not-exist")
    do { try token.launch(neverLaunch); fatalError("cancelled worker launched") }
    catch OCRServiceError.cancelled {} catch { fatalError("cancelled launch did not short-circuit") }

    // Cancellation really terminates an owned child, not merely its completion handler.
    let childToken = OCRTask(), sleepingChild = Process()
    sleepingChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleepingChild.arguments = ["30"]
    try! childToken.launch(sleepingChild)
    childToken.cancel()
    sleepingChild.waitUntilExit()
    childToken.detachProcess()
    ocrCheck(!sleepingChild.isRunning && sleepingChild.terminationStatus != 0, "cancelled child stayed alive")
    MainActor.assumeIsolated {
        let owner = ScreenshotOCRTaskOwner()
        let oldGeneration = owner.begin()
        let oldTask = OCRTask()
        owner.task = oldTask
        let generation = owner.begin()
        ocrCheck(oldTask.isCancelled && !owner.isCurrent(oldGeneration), "owner replacement retained old task")
        let newTask = OCRTask()
        owner.task = newTask
        owner.finish(oldGeneration)
        ocrCheck(owner.task === newTask && owner.isCurrent(generation), "stale completion released new task")
        owner.cancel()
        ocrCheck(newTask.isCancelled && owner.task == nil, "owner close did not cancel")
    }

    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = context.makeImage()!
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let queue = OCRRecognitionQueue(maximumJobs: 2, maximumBytes: 2_048) { _, _, task in
        entered.signal()
        _ = release.wait(timeout: .now() + 3)
        if task.isCancelled { throw OCRServiceError.cancelled }
        return OCRResponse(status: .success)
    }
    let request = OCRRequest(path: "", maxPixelSize: 16)
    var deliveries = 0, rejections = 0
    let first = queue.submit(image: image, request: request) { _ in deliveries += 1 }
    ocrCheck(entered.wait(timeout: .now() + 2) == .success, "first job did not start")
    let second = queue.submit(image: image, request: request) { _ in deliveries += 1 }
    queue.submit(image: image, request: request) { result in
        if case .failure(OCRServiceError.busy) = result { rejections += 1 }
    }
    ocrCheck(queue.reservations.count == 2 && queue.reservations.bytes == 2_048, "admission count/bytes unbounded")
    second.cancel()
    ocrCheck(queue.reservations.count == 1, "pending cancellation did not release its reservation")
    first.cancel(); release.signal()
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline && (queue.reservations.count != 0 || rejections != 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    ocrCheck(queue.reservations.count == 0 && deliveries == 0 && rejections == 1,
             "cancelled tasks delivered or leaked a reservation")

    // A failed image decode is exercised in a real child, without loading Vision models.
    do {
        _ = try OCRSubprocess.perform(OCRRequest(path: "/clipy-nonexistent-fixture.png", maxPixelSize: 64), task: OCRTask())
        fatalError("missing image should fail")
    } catch {}

    if ProcessInfo.processInfo.environment["CLIPY_OCR_LIVE_TESTS"] == "1" {
        runOCRWorkerImageTests()
    }
    print("OCR memory regressions passed (empty success, geometry, limits, cancellation, bounded admission, child failure).")
}

/// Explicit opt-in: fictional images only; never reads the clipboard/history or opens app windows.
private func runOCRWorkerImageTests() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-ocr-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    func save(_ image: NSImage, name: String) -> String {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let url = directory.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        ocrCheck(CGImageDestinationFinalize(destination), "fixture encoding failed")
        return url.path
    }
    let blank = NSImage(size: NSSize(width: 640, height: 160), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill(); return true
    }
    let blankPath = save(blank, name: "blank.png")
    do {
        let result = try OCRSubprocess.perform(OCRRequest(path: blankPath, maxPixelSize: 640), task: OCRTask())
        ocrCheck(result.text.isEmpty && result.status == .success, "blank screenshot not successful empty")
        let textImage = NSImage(size: NSSize(width: 640, height: 160), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("hello@example.com" as NSString).draw(at: NSPoint(x: 30, y: 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            return true
        }
        let textPath = save(textImage, name: "text.png")
        let text = try OCRSubprocess.perform(OCRRequest(path: textPath, maxPixelSize: 640,
            kind: .textAndQR, matchingPatterns: [#"hello@example\.com"#]), task: OCRTask())
        ocrCheck(text.text.contains("hello@example.com") && text.observations.contains { !$0.matchedBoxes.isEmpty },
                 "child recognition or exact PII coordinates failed")
        func footprintMiB() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
        }
        var footprints = [footprintMiB()]
        for index in 0..<10 {
            let value = try OCRSubprocess.perform(OCRRequest(path: index.isMultiple(of: 2) ? blankPath : textPath,
                maxPixelSize: 640, kind: .textAndQR), task: OCRTask())
            ocrCheck(index.isMultiple(of: 2) ? value.text.isEmpty : value.text.contains("hello@example.com"),
                     "repeated blank/text recognition failed")
            footprints.append(footprintMiB())
        }
        print("Live OCR worker checks passed (blank image, text, exact match coordinates, ten repeated scans). Parent footprint MiB: \(footprints)")
    } catch { fatalError("Live OCR worker checks failed: \(error)") }
}
