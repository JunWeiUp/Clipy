import Foundation

/// Localization helper for the macshot screenshot module.
///
/// macshot's source calls `L("English Text")` everywhere. clipy1 ships the
/// macshot string set as a static table in `ScreenshotLocalization.swift`.
/// On a Simplified-Chinese system the English key is replaced by its 中文
/// translation; on any other language the English string is returned verbatim
/// (which keeps every call site compiling and renders correct English UI).
///
/// Call sites never change — only this function decides whether to translate.
func L(_ key: String) -> String {
    ScreenshotLocalization.active[key] ?? key
}
