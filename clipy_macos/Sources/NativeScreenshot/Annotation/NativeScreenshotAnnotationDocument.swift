import CoreGraphics
import Foundation

/// Editable, value-semantic annotation state. Image stamps share immutable CGImage
/// references between snapshots; history is capped to avoid unbounded retention.
struct NativeScreenshotAnnotationDocument {
    let canvasSize: CGSize
    private(set) var annotations: [NativeScreenshotAnnotation] = []
    private(set) var revision: UInt64 = 0
    private(set) var undoLimit: Int

    private var undoStack: [[NativeScreenshotAnnotation]] = []
    private var redoStack: [[NativeScreenshotAnnotation]] = []

    init(canvasSize: CGSize, undoLimit: Int = 32) {
        self.canvasSize = canvasSize
        self.undoLimit = max(1, min(128, undoLimit))
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var nextNumber: Int {
        let values = annotations.compactMap { annotation -> Int? in
            if case let .number(_, value) = annotation.content { return value }
            return nil
        }
        return (values.max() ?? 0) + 1
    }

    @discardableResult
    mutating func insertNextNumber(
        at center: CGPoint,
        style: NativeScreenshotAnnotationStyle = .init()
    ) -> NativeScreenshotAnnotation {
        let annotation = NativeScreenshotAnnotation(
            content: .number(center: center, value: nextNumber), style: style)
        _ = insert(annotation)
        return annotation
    }

    /// Sampling is transient and never becomes part of a saved annotation document.
    @discardableResult
    mutating func insert(_ annotation: NativeScreenshotAnnotation) -> Bool {
        guard annotation.kind != .colorSampler,
              !annotations.contains(where: { $0.id == annotation.id }) else { return false }
        recordEdit()
        annotations.append(annotation)
        revision &+= 1
        return true
    }

    @discardableResult
    mutating func replace(_ annotation: NativeScreenshotAnnotation) -> Bool {
        guard annotation.kind != .colorSampler,
              let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return false }
        recordEdit()
        annotations[index] = annotation
        revision &+= 1
        return true
    }

    @discardableResult
    mutating func move(id: UUID, by offset: CGSize) -> Bool {
        guard offset.width.isFinite, offset.height.isFinite,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        guard offset != .zero else { return true }
        recordEdit()
        annotations[index].content = annotations[index].content.translated(by: offset)
        revision &+= 1
        return true
    }

    @discardableResult
    mutating func remove(id: UUID) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        recordEdit()
        annotations.remove(at: index)
        revision &+= 1
        return true
    }

    @discardableResult
    mutating func bringToFront(id: UUID) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        guard index != annotations.count - 1 else { return true }
        recordEdit()
        annotations.append(annotations.remove(at: index))
        revision &+= 1
        return true
    }

    mutating func clear() {
        guard !annotations.isEmpty else { return }
        recordEdit()
        annotations.removeAll()
        revision &+= 1
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        revision &+= 1
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(annotations)
        trimUndo()
        annotations = next
        revision &+= 1
        return true
    }

    /// Returns the uppermost visible annotation under a canvas point.
    func annotation(at point: CGPoint, tolerance: CGFloat = 6) -> NativeScreenshotAnnotation? {
        annotations.reversed().first { $0.hitTest(point, tolerance: tolerance) }
    }

    private mutating func recordEdit() {
        undoStack.append(annotations)
        trimUndo()
        redoStack.removeAll()
    }

    private mutating func trimUndo() {
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
    }
}
