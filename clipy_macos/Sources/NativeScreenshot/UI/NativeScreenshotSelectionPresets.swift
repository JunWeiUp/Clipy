import CoreGraphics
import Foundation

/// Selection sizes offered by the original screenshot UI. Ratios constrain
/// subsequent drags; resolutions apply an exact pixel size without a lock.
enum NativeScreenshotSelectionPreset: Equatable {
    case freeform
    case ratio(label: String, value: CGFloat)
    case resolution(width: Int, height: Int)

    var title: String {
        switch self {
        case .freeform: return "Freeform"
        case let .ratio(label, _): return label
        case let .resolution(width, height): return "\(width) × \(height)"
        }
    }

    var aspectRatio: CGFloat? {
        guard case let .ratio(_, value) = self else { return nil }
        return value
    }

    func matches(_ other: Self) -> Bool {
        switch (self, other) {
        case (.freeform, .freeform): return true
        case let (.ratio(_, left), .ratio(_, right)): return abs(left - right) < 0.001
        case let (.resolution(leftW, leftH), .resolution(rightW, rightH)):
            return leftW == rightW && leftH == rightH
        default: return false
        }
    }
}

enum NativeScreenshotSelectionPresetCatalog {
    static let ratios: [NativeScreenshotSelectionPreset] = [
        .freeform,
        .ratio(label: "1 : 1", value: 1),
        .ratio(label: "4 : 3", value: 4.0 / 3.0),
        .ratio(label: "3 : 2", value: 3.0 / 2.0),
        .ratio(label: "16 : 10", value: 16.0 / 10.0),
        .ratio(label: "16 : 9", value: 16.0 / 9.0),
        .ratio(label: "21 : 9", value: 21.0 / 9.0),
        .ratio(label: "5 : 1", value: 5),
        .ratio(label: "3 : 4", value: 3.0 / 4.0),
        .ratio(label: "9 : 16", value: 9.0 / 16.0),
    ]

    static let resolutions: [NativeScreenshotSelectionPreset] = [
        .resolution(width: 1920, height: 1080),
        .resolution(width: 1920, height: 384),
        .resolution(width: 1280, height: 720),
        .resolution(width: 1080, height: 1080),
        .resolution(width: 1080, height: 1920),
        .resolution(width: 800, height: 600),
        .resolution(width: 640, height: 480),
    ]

    static var all: [NativeScreenshotSelectionPreset] { ratios + resolutions }

    static func matchingRatio(_ value: CGFloat) -> NativeScreenshotSelectionPreset? {
        ratios.first { candidate in
            guard let ratio = candidate.aspectRatio else { return false }
            return abs(ratio - value) < 0.001
        }
    }

    static func customRatio(widthPixels: Int, heightPixels: Int) -> NativeScreenshotSelectionPreset? {
        guard widthPixels > 0, heightPixels > 0 else { return nil }
        let value = CGFloat(widthPixels) / CGFloat(heightPixels)
        var a = widthPixels
        var b = heightPixels
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = max(1, a)
        let shortLabel: String
        if widthPixels / divisor <= 32 && heightPixels / divisor <= 32 {
            shortLabel = "\(widthPixels / divisor) : \(heightPixels / divisor)"
        } else if abs(value.rounded() - value) < 0.001 {
            shortLabel = "\(Int(value.rounded())) : 1"
        } else {
            shortLabel = String(format: "%.2f : 1", Double(value))
        }
        return .ratio(label: shortLabel, value: value)
    }
}

enum NativeScreenshotEditedDimension {
    case width, height
}

enum NativeScreenshotSelectionSizing {
    static func displayedDimension(pixels: Int, pixelsPerPoint: CGFloat,
                                   unitIsPoints: Bool) -> Int {
        guard unitIsPoints, pixelsPerPoint > 0 else { return pixels }
        return Int((CGFloat(pixels) / pixelsPerPoint).rounded())
    }

    static func pixelDimension(displayed: Int, pixelsPerPoint: CGFloat,
                               unitIsPoints: Bool) -> Int {
        guard unitIsPoints, pixelsPerPoint > 0 else { return displayed }
        return Int((CGFloat(displayed) * pixelsPerPoint).rounded())
    }

    static func pixels(width: Int, height: Int, aspectRatio: CGFloat?,
                       edited: NativeScreenshotEditedDimension) -> (width: Int, height: Int) {
        let width = min(40_000, max(4, width))
        let height = min(40_000, max(4, height))
        guard let aspectRatio, aspectRatio > 0, aspectRatio.isFinite else {
            return (width, height)
        }
        switch edited {
        case .width:
            return (width, min(40_000, max(4, Int((CGFloat(width) / aspectRatio).rounded()))))
        case .height:
            return (min(40_000, max(4, Int((CGFloat(height) * aspectRatio).rounded()))), height)
        }
    }

    /// Center a pixel size on the previous selection and fit it to the display
    /// using one scale factor, so a too-large preset keeps its proportions.
    static func rect(widthPixels: Int, heightPixels: Int, pixelsPerPoint: CGFloat,
                     in display: CGRect, around current: CGRect?) -> CGRect {
        guard widthPixels > 0, heightPixels > 0, pixelsPerPoint > 0,
              !display.isEmpty else { return .zero }
        let requestedWidth = CGFloat(widthPixels) / pixelsPerPoint
        let requestedHeight = CGFloat(heightPixels) / pixelsPerPoint
        let fit = min(1, display.width / requestedWidth, display.height / requestedHeight)
        let width = requestedWidth * fit
        let height = requestedHeight * fit
        let center = current.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: display.midX, y: display.midY)
        let x = max(display.minX, min(center.x - width / 2, display.maxX - width))
        let y = max(display.minY, min(center.y - height / 2, display.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Storage for the old capture preset keys. A selected-area choice applies to
/// the next capture only while keep-ratio is on; an idle choice is always kept.
final class NativeScreenshotSelectionPreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var keepRatioForNextCaptures: Bool {
        get { defaults.bool(forKey: "keepAspectRatio") }
        set { defaults.set(newValue, forKey: "keepAspectRatio") }
    }

    var unitIsPoints: Bool {
        get { defaults.bool(forKey: "resolutionUnitIsPoints") }
        set { defaults.set(newValue, forKey: "resolutionUnitIsPoints") }
    }

    var activePreselection: NativeScreenshotSelectionPreset {
        switch defaults.integer(forKey: "preSelectionResolutionPresetKind") {
        case 1:
            return .freeform
        case 2:
            let value = CGFloat(defaults.double(forKey: "preSelectionResolutionPresetAspect"))
            return ratioPreset(value) ?? .freeform
        case 3:
            let width = defaults.integer(forKey: "preSelectionResolutionPresetWidth")
            let height = defaults.integer(forKey: "preSelectionResolutionPresetHeight")
            return width > 0 && height > 0 ? .resolution(width: width, height: height) : .freeform
        default:
            let value = CGFloat(defaults.double(forKey: "keepAspectRatioValue"))
            return keepRatioForNextCaptures ? ratioPreset(value) ?? .freeform : .freeform
        }
    }

    func chooseBeforeSelection(_ preset: NativeScreenshotSelectionPreset) {
        switch preset {
        case .freeform:
            defaults.set(1, forKey: "preSelectionResolutionPresetKind")
        case let .ratio(_, value):
            defaults.set(2, forKey: "preSelectionResolutionPresetKind")
            defaults.set(Double(value), forKey: "preSelectionResolutionPresetAspect")
        case let .resolution(width, height):
            defaults.set(3, forKey: "preSelectionResolutionPresetKind")
            defaults.set(width, forKey: "preSelectionResolutionPresetWidth")
            defaults.set(height, forKey: "preSelectionResolutionPresetHeight")
        }
    }

    func chooseForCurrentSelection(_ preset: NativeScreenshotSelectionPreset) {
        chooseBeforeSelection(keepRatioForNextCaptures ? preset : .freeform)
        if keepRatioForNextCaptures {
            defaults.set(Double(preset.aspectRatio ?? 0), forKey: "keepAspectRatioValue")
        }
    }

    func setKeepRatio(_ enabled: Bool, currentPreset: NativeScreenshotSelectionPreset,
                      beforeSelection: Bool) {
        keepRatioForNextCaptures = enabled
        if !beforeSelection {
            chooseBeforeSelection(enabled ? currentPreset : .freeform)
        }
        if enabled {
            let ratio = beforeSelection ? activePreselection.aspectRatio : currentPreset.aspectRatio
            defaults.set(Double(ratio ?? 0), forKey: "keepAspectRatioValue")
        } else if beforeSelection {
            defaults.set(0.0, forKey: "keepAspectRatioValue")
        }
    }

    private func ratioPreset(_ value: CGFloat) -> NativeScreenshotSelectionPreset? {
        guard value > 0, value.isFinite else { return nil }
        return NativeScreenshotSelectionPresetCatalog.matchingRatio(value)
            ?? .ratio(label: String(format: "%.2f : 1", Double(value)), value: value)
    }
}
