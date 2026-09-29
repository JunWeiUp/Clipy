import CoreGraphics

/// Selection geometry lives with the new canvas, independent of capture or
/// recording. Coordinates match annotation pixels (upper-left origin).
extension NativeScreenshotAnnotationContent {
    func editingBounds(lineWidth: CGFloat) -> CGRect {
        switch self {
        case let .pencil(samples, _): return bounds(of: samples.map(\.point), inset: lineWidth)
        case let .line(start, end), let .arrow(start, end, _), let .ruler(start, end):
            return bounds(of: [start, end], inset: lineWidth)
        case let .highlighter(points): return bounds(of: points, inset: max(10, lineWidth))
        case let .rectangle(rect), let .filledRectangle(rect), let .ellipse(rect),
             let .richText(rect, _), let .stamp(rect, _), let .pixelate(rect, _),
             let .blur(rect, _), let .solidCensor(rect), let .eraseCensor(rect),
             let .spotlight(rect):
            return rect.standardized
        case let .magnifier(_, destination): return destination.standardized
        case let .number(center, _):
            let diameter = max(24, lineWidth * 9)
            return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                          width: diameter, height: diameter)
        case let .colorSampler(point):
            return CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        }
    }

    func scaled(by factor: CGFloat, around pivot: CGPoint) -> NativeScreenshotAnnotationContent {
        guard factor.isFinite, factor > 0 else { return self }
        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(x: pivot.x + (value.x - pivot.x) * factor,
                    y: pivot.y + (value.y - pivot.y) * factor)
        }
        func rect(_ value: CGRect) -> CGRect {
            let value = value.standardized
            let origin = point(value.origin)
            return CGRect(origin: origin,
                          size: CGSize(width: max(1, value.width * factor),
                                       height: max(1, value.height * factor)))
        }
        switch self {
        case let .pencil(samples, smoothing):
            return .pencil(samples: samples.map {
                NativeScreenshotStrokeSample(point($0.point), pressure: $0.pressure)
            }, smoothing: smoothing)
        case let .line(start, end): return .line(start: point(start), end: point(end))
        case let .arrow(start, end, arrowStyle):
            return .arrow(start: point(start), end: point(end), style: arrowStyle)
        case let .rectangle(value): return .rectangle(rect(value))
        case let .filledRectangle(value): return .filledRectangle(rect(value))
        case let .ellipse(value): return .ellipse(rect(value))
        case let .highlighter(points): return .highlighter(points: points.map(point))
        case let .richText(value, runs):
            return .richText(rect: rect(value), runs: runs.map { run in
                var scaledRun = run
                scaledRun.fontSize = max(1, run.fontSize * factor)
                scaledRun.outlineWidth = max(0, run.outlineWidth * factor)
                return scaledRun
            })
        case let .number(center, value): return .number(center: point(center), value: value)
        case let .stamp(value, content): return .stamp(rect: rect(value), content: content)
        case let .pixelate(value, blockSize):
            return .pixelate(rect: rect(value), blockSize: max(2, blockSize * factor))
        case let .blur(value, radius): return .blur(rect: rect(value), radius: max(1, radius * factor))
        case let .solidCensor(value): return .solidCensor(rect(value))
        case let .eraseCensor(value): return .eraseCensor(rect(value))
        case let .magnifier(source, destination):
            // Scaling a loupe changes its display size while preserving the
            // sampled source area, so the visual zoom can be adjusted later.
            return .magnifier(source: source, destination: rect(destination))
        case let .ruler(start, end): return .ruler(start: point(start), end: point(end))
        case let .colorSampler(value): return .colorSampler(point(value))
        case let .spotlight(value): return .spotlight(rect(value))
        }
    }
}

private func bounds(of points: [CGPoint], inset: CGFloat) -> CGRect {
    guard let first = points.first else { return .zero }
    var minimumX = first.x
    var minimumY = first.y
    var maximumX = first.x
    var maximumY = first.y
    for point in points.dropFirst() {
        minimumX = min(minimumX, point.x)
        minimumY = min(minimumY, point.y)
        maximumX = max(maximumX, point.x)
        maximumY = max(maximumY, point.y)
    }
    return CGRect(x: minimumX, y: minimumY,
                  width: max(1, maximumX - minimumX),
                  height: max(1, maximumY - minimumY))
        .insetBy(dx: -max(0, inset / 2), dy: -max(0, inset / 2))
}
