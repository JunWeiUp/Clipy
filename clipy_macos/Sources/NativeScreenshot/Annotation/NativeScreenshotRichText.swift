import AppKit
import CoreText

/// Converts the editable AppKit text storage to the value-semantic annotation
/// model. Attribute ranges are retained, so editing one word does not restyle
/// the rest of an annotation.
enum NativeScreenshotRichText {
    static func attributedString(from runs: [NativeScreenshotTextRun]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in runs where !run.text.isEmpty {
            let size = max(1, run.fontSize.isFinite ? run.fontSize : 24)
            var font = run.fontName.flatMap { NSFont(name: $0, size: size) }
                ?? NSFont.systemFont(ofSize: size)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if run.bold { traits.insert(.bold) }
            if run.italic { traits.insert(.italic) }
            if !traits.isEmpty {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size)
                    ?? font
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color(run.color)
            ]
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let background = run.backgroundColor {
                attributes[.backgroundColor] = color(background)
            }
            if run.outlineWidth > 0 {
                attributes[.strokeWidth] = -100 * run.outlineWidth / size
                attributes[.strokeColor] = color(run.color)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    static func runs(from text: NSAttributedString) -> [NativeScreenshotTextRun] {
        guard text.length > 0 else { return [] }
        var result: [NativeScreenshotTextRun] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let value = (text.string as NSString).substring(with: range)
            guard !value.isEmpty else { return }
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 24)
            let traits = font.fontDescriptor.symbolicTraits
            let foreground = attributes[.foregroundColor] as? NSColor ?? .black
            let background = attributes[.backgroundColor] as? NSColor
            let underline = (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0
            let strokePercent = abs((attributes[.strokeWidth] as? NSNumber)?.doubleValue ?? 0)
            result.append(NativeScreenshotTextRun(
                text: value,
                color: color(foreground),
                // AppKit's hidden .SFNS-* names are not stable font names for
                // NSFont(name:); keep the semantic system font instead.
                fontName: font.fontName.hasPrefix(".") ? nil : font.fontName,
                fontSize: font.pointSize,
                bold: traits.contains(.bold),
                italic: traits.contains(.italic),
                underline: underline != 0,
                outlineWidth: CGFloat(strokePercent) * font.pointSize / 100,
                backgroundColor: background.map(color)
            ))
        }
        return result
    }

    static func requiredHeight(for runs: [NativeScreenshotTextRun], width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 44 }
        let text = attributedString(from: runs)
        guard text.length > 0 else { return 44 }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: width, height: 100_000), nil)
        return max(44, ceil(size.height) + 8)
    }

    private static func color(_ value: NativeScreenshotColor) -> NSColor {
        NSColor(calibratedRed: value.red, green: value.green,
                blue: value.blue, alpha: value.alpha)
    }

    private static func color(_ value: NSColor) -> NativeScreenshotColor {
        let rgba = value.usingColorSpace(.deviceRGB) ?? .black
        return NativeScreenshotColor(red: rgba.redComponent, green: rgba.greenComponent,
                                     blue: rgba.blueComponent, alpha: rgba.alphaComponent)
    }
}
