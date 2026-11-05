import Cocoa

/// Handles text translation overlay: OCR → translate → create overlay annotations.
enum TranslateOverlay {

    /// Perform OCR + translation on the selected region. Calls completion with overlay annotations.
    @discardableResult
    static func translate(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        targetLang: String,
        onError: @escaping (String) -> Void,
        completion: @escaping ([Annotation]) -> Void
    ) -> OCRTask? {
        let regionImage = NSImage(size: selectionRect.size, flipped: false) { _ in
            screenshot.draw(in: NSRect(x: captureDrawRect.origin.x - selectionRect.origin.x,
                                        y: captureDrawRect.origin.y - selectionRect.origin.y,
                                       width: captureDrawRect.width, height: captureDrawRect.height),
                            from: .zero, operation: .copy, fraction: 1.0)
            return true
        }

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            onError("Failed to process image")
            return nil
        }

        weak var token: OCRTask?
        let task = VisionOCR.performTextRecognition(cgImage: cgImage) { observations, error in
            guard let token, !token.isCancelled else { return }
            if let error = error {
                onError("OCR failed: \(error.localizedDescription)")
                return
            }

            guard
                  !observations.isEmpty else {
                onError("No text found in selection.")
                return
            }

            let blocks = observations.compactMap { obs -> (text: String, box: CGRect)? in
                let t = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                return (t, obs.boundingBox)
            }

            // Sample now: translation retains only small colors/boxes, not the image.
            let colors = blocks.map { block in
                sampleAverageColor(in: cgImage, region: CGRect(
                    x: block.box.minX * CGFloat(cgImage.width),
                    y: block.box.minY * CGFloat(cgImage.height),
                    width: block.box.width * CGFloat(cgImage.width),
                    height: block.box.height * CGFloat(cgImage.height)))
            }
            TranslationService.translateBatch(texts: blocks.map { $0.text }, targetLang: targetLang, cancellation: token) { [weak token] result in
                guard let token, !token.isCancelled else { return }
                switch result {
                case .failure(let error):
                    onError("Translation failed: \(error.localizedDescription)")

                case .success(let translations):
                    var annotations: [Annotation] = []
                    let groupID = UUID()

                    for (i, block) in blocks.enumerated() {
                        guard i < translations.count else { continue }
                        let translated = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !translated.isEmpty else { continue }

                        let box = block.box
                        let padding: CGFloat = 1
                        let viewX = selectionRect.origin.x + box.origin.x * selectionRect.width - padding
                        let viewY = selectionRect.origin.y + box.origin.y * selectionRect.height - padding
                        let viewW = box.width * selectionRect.width + padding * 2
                        let viewH = box.height * selectionRect.height + padding * 2

                        let bgColor = colors[i]

                        let ann = Annotation(
                            tool: .translateOverlay,
                            startPoint: NSPoint(x: viewX, y: viewY),
                            endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                            color: bgColor, strokeWidth: 0
                        )
                        ann.text = translated
                        ann.fontSize = max(8, viewH * 0.65)
                        ann.groupID = groupID
                        annotations.append(ann)
                    }

                    completion(annotations)
                }
            }
        }
        token = task
        return task
    }

    // MARK: - Helpers

    private static func sampleAverageColor(in cgImage: CGImage, region: CGRect) -> NSColor {
        let clampedX = max(0, min(Int(region.origin.x), cgImage.width - 1))
        let clampedY = max(0, min(Int(region.origin.y), cgImage.height - 1))
        let clampedW = min(max(1, Int(region.width)), cgImage.width - clampedX)
        let clampedH = min(max(1, Int(region.height)), cgImage.height - clampedY)
        guard clampedW > 0, clampedH > 0 else { return .white }

        let thumbW = 4, thumbH = 4
        var pixelData = [UInt8](repeating: 0, count: thumbW * thumbH * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixelData, width: thumbW, height: thumbH,
                                  bitsPerComponent: 8, bytesPerRow: thumbW * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cropped = cgImage.cropping(to: CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH))
        else { return .white }

        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        let count = CGFloat(thumbW * thumbH)
        for i in 0..<(thumbW * thumbH) {
            let base = i * 4
            r += CGFloat(pixelData[base]) / 255.0
            g += CGFloat(pixelData[base + 1]) / 255.0
            b += CGFloat(pixelData[base + 2]) / 255.0
        }
        return NSColor(deviceRed: r / count, green: g / count, blue: b / count, alpha: 1.0)
    }
}
