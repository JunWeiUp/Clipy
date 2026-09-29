@main
enum NativeScreenshotSelectionInputRegression {
    static func main() {
        var state = NativeScreenshotSelectionInputState()

        // Window/full-screen hover can have a visible candidate rectangle, but
        // it is still uncommitted and must accept the first click.
        precondition(state.pointerIntent(regionMode: true, hit: .outside) == .beginSelection)
        precondition(state.pointerIntent(regionMode: false, hit: .body) == .beginSelection)

        state.commit()
        precondition(state.isCommitted)
        precondition(state.pointerIntent(regionMode: true, hit: .outside) == .ignore,
                     "A drag outside a committed region must not replace it")
        precondition(state.pointerIntent(regionMode: true, hit: .body) == .moveSelection)
        precondition(state.pointerIntent(regionMode: true, hit: .resizeHandle) == .resizeSelection)
        precondition(state.pointerIntent(regionMode: false, hit: .outside) == .ignore)
        precondition(state.pointerIntent(regionMode: false, hit: .body) == .ignore,
                     "Window and full-screen captures stay fixed after confirmation")

        state.clear()
        precondition(!state.isCommitted)
        precondition(state.pointerIntent(regionMode: true, hit: .outside) == .beginSelection,
                     "Escape must restore the ability to select again")
        print("NativeScreenshotSelectionInputRegression passed")
    }
}
