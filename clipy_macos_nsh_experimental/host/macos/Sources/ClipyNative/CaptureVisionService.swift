import Foundation
import ImageIO
import Vision
import MachO
import Darwin

@MainActor final class CaptureVisionService {
    private let directory: URL
    private let timeout: TimeInterval
    private var workers: [UUID: Process] = [:]
    private var generation = 0
    nonisolated private static let methods: Set<String> = ["ocr.recognize", "image.redact", "image.smartHighlight"]
    init(root: URL, timeout: TimeInterval = 25) {
        self.timeout = min(25, max(0.05, timeout))
        directory = root.appendingPathComponent("capture-vision-jobs", isDirectory: true)
        // This namespace is exclusively temporary worker input, never user media.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
        }
    }
    func cancelAll() {
        generation += 1
        for (id, process) in workers {
            if process.isRunning { process.terminate(); if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
        }
    }
    func invoke(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard Self.methods.contains(method) else { throw Self.failure("UNSUPPORTED", "不支持此图像识别操作") }
        guard workers.count < 2 else { throw Self.failure("BUSY", "已有两个图像识别任务，请稍后再试") }
        try Task.checkCancellation()
        guard JSONSerialization.isValidJSONObject(params) else { throw Self.failure("INVALID_ARGUMENT", "图像识别参数无效") }
        let bytes = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        guard bytes.count <= 512 * 1024 else { throw Self.failure("TOO_LARGE", "图像识别参数过大") }
        let id = UUID(), current = generation, process = Process(), pipe = Pipe()
        let job = directory.appendingPathComponent(id.uuidString + ".json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try bytes.write(to: job, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: job.path)
        defer { workers.removeValue(forKey: id); try? FileManager.default.removeItem(at: job) }
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw Self.failure("WORKER_UNAVAILABLE", "无法定位图像识别子进程") }
        process.executableURL = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        process.arguments = ["--capture-vision-worker", job.path]
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        workers[id] = process
        do { try process.run() } catch { throw Self.failure("WORKER_UNAVAILABLE", "无法启动图像识别子进程") }
        try? pipe.fileHandleForWriting.close()
        let reader = Task.detached { () throws -> Data in
            defer { try? pipe.fileHandleForReading.close() }
            var data = Data()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                guard data.count + chunk.count <= 1024 * 1024 else { if process.isRunning { process.terminate() };throw CaptureVisionService.failure("WORKER_OUTPUT_TOO_LARGE", "图像识别结果超过限制") }
                data.append(chunk)
            }
            return data
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let data = try await withTaskCancellationHandler(operation: {
                while process.isRunning {
                    try Task.checkCancellation()
                    guard current == generation else { throw CancellationError() }
                    guard ProcessInfo.processInfo.systemUptime - started < timeout else { throw Self.failure("TIMEOUT", "图像识别超时，请缩小图片后重试") }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                return try await reader.value
            }, onCancel: { if process.isRunning { process.terminate() } })
            try Task.checkCancellation()
            guard current == generation else { throw CancellationError() }
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Self.failure("INVALID_WORKER_RESULT", "图像识别返回无效结果") }
            if let error = result["error"] as? [String: Any], let code = error["code"] as? String {
                throw Self.failure(code, error["message"] as? String ?? "图像识别失败")
            }
            guard process.terminationStatus == 0 else { throw Self.failure("CAPTURE_VISION_FAILED", "图像识别子进程未完成") }
            return result
        } catch {
            // Only this invocation's direct child is terminated; never search by name.
            if process.isRunning { process.terminate(); if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
            _ = try? await reader.value
            throw error
        }
    }
    nonisolated private static func failure(_ code: String, _ message: String) -> BridgeFailure { BridgeFailure(code: code, message: message) }
    nonisolated static func runWorker(jobPath: String) throws -> [String: Any] {
        let job = URL(fileURLWithPath: jobPath)
        let values = try job.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 512 * 1024 else { throw failure("INVALID_JOB", "图像识别任务文件无效") }
        let bytes = try Data(contentsOf: job, options: .mappedIfSafe)
        guard bytes.count <= 512 * 1024, let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let method = request["method"] as? String, methods.contains(method), let params = request["params"] as? [String: Any] else { throw failure("INVALID_JOB", "图像识别任务无效") }
        let key = method == "ocr.recognize" ? "path" : "imagePath"
        guard let path = params[key] as? String else { throw failure("INVALID_IMAGE", "请选择识别图片") }
        let sourceURL = URL(fileURLWithPath: path)
        let sourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard sourceValues.isRegularFile == true, let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, width <= 120000, height <= 120000, Int64(width) * Int64(height) <= 80_000_000 else { throw failure("INVALID_IMAGE", "识别图片尺寸无效或超过 8000 万像素") }
        if method == "image.redact" { return try ImageEditorService.redact(params) }
        if method == "image.smartHighlight" { return try ImageEditorService.smartHighlight(params) }
        // Downsample only OCR work. VN normalized boxes map back to ORIGINAL pixels.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw failure("INVALID_IMAGE", "无法解码识别图片") }
        let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate; text.recognitionLanguages = ["zh-Hans", "en-US"]; text.usesLanguageCorrection = true
        let qr = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, qr])
        var rows: [[String: Any]] = [], total = 0
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            guard rows.count < 2000, total + candidate.string.utf8.count + 1 <= 128 * 1024 else { throw failure("OCR_TOO_LARGE", "识别文字超过限制，请缩小图片范围") }
            let box = observation.boundingBox
            rows.append(["id": "ocr-\(rows.count)", "text": candidate.string, "confidence": candidate.confidence, "rect": ["x": box.minX * CGFloat(width), "y": (1 - box.maxY) * CGFloat(height), "width": box.width * CGFloat(width), "height": box.height * CGFloat(height)]])
            total += candidate.string.utf8.count + 1
        }
        let codes = (qr.results ?? []).compactMap(\.payloadStringValue)
        guard codes.count <= 128, codes.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024 else { throw failure("OCR_TOO_LARGE", "识别二维码超过限制") }
        let result: [String: Any] = ["text": rows.compactMap { $0["text"] as? String }.joined(separator: "\n"), "codes": codes, "rows": rows, "width": width, "height": height, "coordinateSpace": "source-pixels-top-left"]
        guard try JSONSerialization.data(withJSONObject: result).count <= 1024 * 1024 else { throw failure("OCR_TOO_LARGE", "识别结果超过限制") }
        return result
    }
}
