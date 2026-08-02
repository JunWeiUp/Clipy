import AppKit

/// Draws a per-glyph text OUTLINE that sits *outside* the letter fill, instead of
/// AppKit's built-in `.strokeWidth`, which draws a stroke centered on the glyph
/// path and eats into the fill (making text thin and hard to read — issue #257).
///
/// The outline is expressed as two custom attributes so AppKit's own centered
/// stroke never fires:
///   - `.macshotOutlineColor`  (NSColor)  — the outline color
///   - `.macshotOutlineWidth`  (CGFloat)  — outline thickness in points (optional;
///     when absent it auto-scales from the glyph's font size)
///
/// `OutlineTextLayoutManager` renders those attributes as stroke-underneath +
/// fill-on-top. Because the SAME layout manager is used both for the live
/// `NSTextView` and for rendering the committed text image, the editing view and
/// the baked image are pixel-identical in every state (typing, committed, resize,
/// re-edit).
extension NSAttributedString.Key {
    static let macshotOutlineColor = NSAttributedString.Key("macshotOutlineColor")
    static let macshotOutlineWidth = NSAttributedString.Key("macshotOutlineWidth")
}

enum OutlineTextRenderer {

    /// Outline thickness as a fraction of the font point size when no explicit
    /// width is given. Tuned to read like the old `-6.0` stroke but drawn outside,
    /// so it looks consistent across small and large text.
    static let autoWidthFraction: CGFloat = 0.09

    /// Resolve the outline width for a font, honoring an explicit override.
    static func outlineWidth(for font: NSFont, explicit: CGFloat?) -> CGFloat {
        if let explicit, explicit > 0 { return explicit }
        return max(1, font.pointSize * autoWidthFraction)
    }

    /// Apply the outline attributes to a mutable attributed string over `range`
    /// (or the whole string when `range` is nil). Pass `color == nil` to remove
    /// the outline. Also strips any legacy `.strokeColor`/`.strokeWidth` so the
    /// old centered stroke can't render alongside the new outline.
    static func applyOutline(_ color: NSColor?, to s: NSMutableAttributedString,
                             range: NSRange? = nil, width: CGFloat? = nil) {
        let r = range ?? NSRange(location: 0, length: s.length)
        guard r.length > 0 || range == nil else { return }
        // Never keep AppKit's centered stroke — it's the bug we're replacing.
        s.removeAttribute(.strokeColor, range: r)
        s.removeAttribute(.strokeWidth, range: r)
        if let color {
            s.addAttribute(.macshotOutlineColor, value: color, range: r)
            if let width { s.addAttribute(.macshotOutlineWidth, value: width, range: r) }
            else { s.removeAttribute(.macshotOutlineWidth, range: r) }
        } else {
            s.removeAttribute(.macshotOutlineColor, range: r)
            s.removeAttribute(.macshotOutlineWidth, range: r)
        }
    }

    /// Normalize a decoded/legacy attributed string: convert any AppKit centered
    /// stroke (`.strokeColor` + negative-or-any `.strokeWidth`) into the new
    /// outside-outline attributes, so old saved annotations render correctly.
    static func normalizeLegacyStroke(_ s: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: s.length)
        guard full.length > 0 else { return }
        var conversions: [(NSRange, NSColor)] = []
        s.enumerateAttribute(.strokeColor, in: full) { value, range, _ in
            if let color = value as? NSColor { conversions.append((range, color)) }
        }
        // Drop the legacy stroke everywhere first.
        s.removeAttribute(.strokeColor, range: full)
        s.removeAttribute(.strokeWidth, range: full)
        // Re-express as an outline (auto-width) only where a stroke color existed
        // and no explicit outline is already present.
        for (range, color) in conversions {
            if s.attribute(.macshotOutlineColor, at: range.location, effectiveRange: nil) == nil {
                s.addAttribute(.macshotOutlineColor, value: color, range: range)
            }
        }
    }

    /// A layout manager + storage + container preconfigured to draw the outline.
    /// Reused for both the live NSTextView and image rendering.
    static func makeLayoutManager() -> OutlineTextLayoutManager {
        OutlineTextLayoutManager()
    }

    /// Render an attributed string to a flipped image of `size`, drawing the text
    /// inside `size` inset by `inset` on all edges — through the outline layout
    /// manager, so the result matches the live editor exactly.
    static func renderImage(_ attr: NSAttributedString, size: NSSize, inset: CGFloat) -> NSImage {
        return NSImage(size: size, flipped: true) { _ in
            let storage = NSTextStorage(attributedString: attr)
            let layout = OutlineTextLayoutManager()
            let container = NSTextContainer(size: NSSize(
                width: max(0, size.width - inset * 2),
                height: max(0, size.height - inset * 2)))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            let glyphRange = layout.glyphRange(for: container)
            let origin = NSPoint(x: inset, y: inset)
            layout.drawBackground(forGlyphRange: glyphRange, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphRange, at: origin)
            return true
        }
    }
}

/// NSLayoutManager that renders `.macshotOutlineColor` as an outline OUTSIDE the
/// glyph fill. It hooks the low-level `showCGGlyphs` call AppKit makes for each
/// run: when the run carries the outline attribute, it first strokes the glyphs
/// (thick, outline color) and then lets the normal fill draw on top. The fill
/// covers the inner half of the stroke, leaving a clean outer outline — never a
/// centered stroke that thins the fill.
final class OutlineTextLayoutManager: NSLayoutManager {

    /// The outline color/width for the run currently being drawn, set in
    /// `drawGlyphs` before AppKit calls `showCGGlyphs`. nil = no outline.
    private var currentOutline: (color: NSColor, width: CGFloat)?

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        // Split the draw into runs of constant outline so `showCGGlyphs` sees a
        // single outline value per call.
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.macshotOutlineColor, in: charRange) { value, subCharRange, _ in
            let subGlyphRange = self.glyphRange(forCharacterRange: subCharRange, actualCharacterRange: nil)
            if let color = value as? NSColor {
                let font = (storage.attribute(.font, at: subCharRange.location, effectiveRange: nil) as? NSFont)
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let explicit = storage.attribute(.macshotOutlineWidth, at: subCharRange.location,
                                                 effectiveRange: nil) as? CGFloat
                self.currentOutline = (color, OutlineTextRenderer.outlineWidth(for: font, explicit: explicit))
            } else {
                self.currentOutline = nil
            }
            super.drawGlyphs(forGlyphRange: subGlyphRange, at: origin)
        }
        currentOutline = nil
    }

    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>,
                               positions: UnsafePointer<CGPoint>,
                               count glyphCount: Int,
                               font: NSFont,
                               textMatrix: CGAffineTransform,
                               attributes: [NSAttributedString.Key: Any],
                               in ctx: CGContext) {
        // Outline pass first (underneath), if this run is outlined. Reuse
        // super's glyph placement (correct font/matrix/positions) but switch the
        // context to stroke mode with the outline color/width. The fill pass then
        // draws the letters on top, covering the inner half of the stroke and
        // leaving a clean outer outline (issue #257).
        if let outline = currentOutline {
            ctx.saveGState()
            ctx.setLineWidth(outline.width)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(outline.color.cgColor)
            ctx.setTextDrawingMode(.stroke)
            super.showCGGlyphs(glyphs, positions: positions, count: glyphCount,
                               font: font, textMatrix: textMatrix, attributes: attributes, in: ctx)
            ctx.restoreGState()
        }
        // Normal fill pass on top.
        super.showCGGlyphs(glyphs, positions: positions, count: glyphCount,
                           font: font, textMatrix: textMatrix, attributes: attributes, in: ctx)
    }
}
