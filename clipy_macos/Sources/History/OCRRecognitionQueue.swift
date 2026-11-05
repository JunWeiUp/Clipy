import Foundation
import CoreGraphics
import ImageIO

/// One running interactive job, at most four admitted images / 128 MiB of source
/// pixels. A single serial history worker shares OCRSubprocess's process gate.
/// Pending cancellation removes the image and callback immediately; running cancellation
/// kills the child, then deletes staged files. Reservations last through UI delivery.
final class OCRRecognitionQueue {
    static let shared = OCRRecognitionQueue()
    typealias Worker = (CGImage, OCRRequest, OCRTask) throws -> OCRResponse

    private final class Job {
        let image: CGImage
        let request: OCRRequest
        let task: OCRTask
        let cost: Int
        let completion: (Result<OCRResponse, Error>) -> Void
        init(image: CGImage, request: OCRRequest, task: OCRTask, cost: Int,
             completion: @escaping (Result<OCRResponse, Error>) -> Void) {
            self.image = image; self.request = request; self.task = task
            self.cost = cost; self.completion = completion
        }
    }
    private let state = DispatchQueue(label: "com.clipy.ocr-admission")
    private let workerQueue = DispatchQueue(label: "com.clipy.ocr-recognition", qos: .userInitiated)
    private let worker: Worker
    private let maximumJobs: Int
    private let maximumBytes: Int
    private var pending: [Job] = []
    private var running = false
    private var admittedCount = 0
    private var admittedBytes = 0

    init(maximumJobs: Int = 4, maximumBytes: Int = 128 * 1_024 * 1_024,
         worker: @escaping Worker = OCRRecognitionQueue.recognize) {
        self.maximumJobs = maximumJobs; self.maximumBytes = maximumBytes; self.worker = worker
    }

    @discardableResult
    func submit(image: CGImage, request: OCRRequest,
                completion: @escaping (Result<OCRResponse, Error>) -> Void) -> OCRTask {
        let task = OCRTask()
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        let accepted = state.sync { () -> Bool in
            guard !overflow, cost <= maximumBytes, admittedCount < maximumJobs,
                  admittedBytes <= maximumBytes - cost else { return false }
            admittedCount += 1; admittedBytes += cost
            pending.append(Job(image: image, request: request, task: task, cost: cost, completion: completion))
            return true
        }
        guard accepted else {
            DispatchQueue.main.async { if !task.isCancelled { completion(.failure(OCRServiceError.busy)) } }
            return task
        }
        task.onCancel { [weak self, weak task] in
            guard let self, let task else { return }
            self.state.async {
                if let index = self.pending.firstIndex(where: { $0.task.id == task.id }) {
                    let job = self.pending.remove(at: index)
                    self.release(cost: job.cost)
                }
            }
        }
        state.async { self.startNext() }
        return task
    }

    private func startNext() {
        guard !running, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        if job.task.isCancelled {
            release(cost: job.cost)
            startNext()
            return
        }
        running = true
        workerQueue.async {
            let result: Result<OCRResponse, Error> = autoreleasepool {
                Result { try self.worker(job.image, job.request, job.task) }
            }
            job.task.onCancel(nil)
            // Capture only delivery data here, not the job/source CGImage.
            let task = job.task, cost = job.cost, completion = job.completion
            DispatchQueue.main.async {
                if !task.isCancelled { completion(result) }
                self.state.async { self.release(cost: cost) }
            }
            self.state.async { self.running = false; self.startNext() }
        }
    }

    private func release(cost: Int) { admittedCount -= 1; admittedBytes -= cost }

    /// Internal diagnostic/test seam. Includes responses waiting for main-thread delivery.
    var reservations: (count: Int, bytes: Int) { state.sync { (admittedCount, admittedBytes) } }

    private static func recognize(image: CGImage, request: OCRRequest, task: OCRTask) throws -> OCRResponse {
        guard !task.isCancelled else { throw OCRServiceError.cancelled }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-ocr-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw OCRServiceError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), !task.isCancelled else {
            throw task.isCancelled ? OCRServiceError.cancelled : OCRServiceError.invalidImage
        }
        let staged = OCRRequest(path: url.path, maxPixelSize: request.maxPixelSize, languages: request.languages,
                                kind: request.kind, matchingPatterns: request.matchingPatterns,
                                automaticLanguageDetection: request.automaticLanguageDetection)
        return try OCRSubprocess.perform(staged, task: task)
    }
}
