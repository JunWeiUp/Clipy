import CoreGraphics
import Foundation

@main
enum NativeScreenshotSelectionPresetsRegression {
    static func main() {
        let ratios = NativeScreenshotSelectionPresetCatalog.ratios
        precondition(ratios.map(\.title) == [
            "Freeform", "1 : 1", "4 : 3", "3 : 2", "16 : 10", "16 : 9",
            "21 : 9", "5 : 1", "3 : 4", "9 : 16"
        ])
        precondition(ratios[0].aspectRatio == nil)
        precondition(abs((ratios[9].aspectRatio ?? 0) - 9.0 / 16.0) < 0.0001)

        let resolutions = NativeScreenshotSelectionPresetCatalog.resolutions
        precondition(resolutions.map(\.title) == [
            "1920 × 1080", "1920 × 384", "1280 × 720", "1080 × 1080",
            "1080 × 1920", "800 × 600", "640 × 480"
        ])
        precondition(resolutions.allSatisfy { $0.aspectRatio == nil })
        precondition(NativeScreenshotSelectionPresetCatalog.matchingRatio(1.5)?.title == "3 : 2")
        let custom = NativeScreenshotSelectionPresetCatalog.customRatio(
            widthPixels: 1344, heightPixels: 840)
        precondition(custom?.title == "8 : 5")
        precondition(custom?.aspectRatio == 1.6)
        precondition(custom?.matches(.ratio(label: "Custom", value: 1.6)) == true)

        let widthEdited = NativeScreenshotSelectionSizing.pixels(
            width: 800, height: 600, aspectRatio: 16.0 / 9.0, edited: .width)
        precondition(widthEdited.width == 800 && widthEdited.height == 450)
        let heightEdited = NativeScreenshotSelectionSizing.pixels(
            width: 800, height: 600, aspectRatio: 16.0 / 9.0, edited: .height)
        precondition(heightEdited.width == 1067 && heightEdited.height == 600)
        let freeform = NativeScreenshotSelectionSizing.pixels(
            width: 800, height: 600, aspectRatio: nil, edited: .height)
        precondition(freeform.width == 800 && freeform.height == 600)
        precondition(NativeScreenshotSelectionSizing.displayedDimension(
            pixels: 1920, pixelsPerPoint: 2, unitIsPoints: true) == 960)
        precondition(NativeScreenshotSelectionSizing.pixelDimension(
            displayed: 540, pixelsPerPoint: 2, unitIsPoints: true) == 1080)
        precondition(NativeScreenshotSelectionSizing.displayedDimension(
            pixels: 1920, pixelsPerPoint: 2, unitIsPoints: false) == 1920)

        let display = CGRect(x: 100, y: 200, width: 1440, height: 900)
        let current = CGRect(x: 600, y: 500, width: 240, height: 120)
        let exact = NativeScreenshotSelectionSizing.rect(
            widthPixels: 1920, heightPixels: 1080, pixelsPerPoint: 2,
            in: display, around: current)
        precondition(exact.size == CGSize(width: 960, height: 540))
        precondition(exact.midX == current.midX && exact.midY == current.midY)

        let tooLarge = NativeScreenshotSelectionSizing.rect(
            widthPixels: 4000, heightPixels: 2000, pixelsPerPoint: 2,
            in: display, around: current)
        precondition(tooLarge.width == display.width)
        precondition(tooLarge.height == 720)
        precondition(display.contains(tooLarge))

        let suite = "ClipySelectionPresets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NativeScreenshotSelectionPreferenceStore(defaults: defaults)
        precondition(store.activePreselection == .freeform)
        store.chooseBeforeSelection(.resolution(width: 1080, height: 1920))
        precondition(store.activePreselection == .resolution(width: 1080, height: 1920))
        // An idle choice remains active even while the keep toggle is off.
        store.chooseBeforeSelection(ratios[5])
        precondition(store.activePreselection.matches(ratios[5]))
        store.chooseForCurrentSelection(ratios[2])
        precondition(store.activePreselection == .freeform)
        store.setKeepRatio(true, currentPreset: ratios[2], beforeSelection: false)
        precondition(store.activePreselection.matches(ratios[2]))
        precondition(abs(defaults.double(forKey: "keepAspectRatioValue") - 4.0 / 3.0) < 0.001)
        store.setKeepRatio(false, currentPreset: ratios[2], beforeSelection: false)
        precondition(store.activePreselection == .freeform)
        store.chooseBeforeSelection(resolutions[1])
        store.setKeepRatio(false, currentPreset: resolutions[1], beforeSelection: true)
        precondition(store.activePreselection.matches(resolutions[1]))
        store.unitIsPoints = true
        precondition(NativeScreenshotSelectionPreferenceStore(defaults: defaults).unitIsPoints)
        print("NativeScreenshotSelectionPresetsRegression passed")
    }
}
