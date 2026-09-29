/// Separates an uncommitted hover/drag from a selection with visible actions.
/// A selected region may be moved or resized, but clicking outside it must not
/// silently replace the captured area and discard the current editing context.
struct NativeScreenshotSelectionInputState {
    enum Hit {
        case outside
        case body
        case resizeHandle
    }

    enum Intent {
        case beginSelection
        case moveSelection
        case resizeSelection
        case ignore
    }

    private(set) var isCommitted = false

    mutating func commit() { isCommitted = true }
    mutating func clear() { isCommitted = false }

    func pointerIntent(regionMode: Bool, hit: Hit) -> Intent {
        guard isCommitted else { return .beginSelection }
        guard regionMode else { return .ignore }
        switch hit {
        case .outside: return .ignore
        case .body: return .moveSelection
        case .resizeHandle: return .resizeSelection
        }
    }
}
