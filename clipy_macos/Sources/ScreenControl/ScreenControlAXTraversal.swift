// Adapted from VibePier (MIT). See LICENSE.VIBEPIER.MIT.
import ApplicationServices
import Foundation

/// A bounded, complete snapshot of the scope used to prove a native control is unique.
/// A truncated or unreadable subtree never supplies partial candidates to a mutation.
enum ScreenControlAXTraversal {
    struct Identity: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    static func collect<Node, ID: Hashable>(
        _ root: Node, limit: Int, withinDeadline: () -> Bool, depthFirst: Bool = false,
        identity: (Node) -> ID, children: (Node, Int) -> [Node]?,
        descend: (Node) -> Bool = { _ in true }
    ) -> [Node]? {
        guard limit > 0 else { return nil }
        var pending = [root]
        var nodes: [Node] = []
        var seen: Set<ID> = [identity(root)]
        var index = 0
        while depthFirst ? !pending.isEmpty : index < pending.count {
            guard withinDeadline() else { return nil }
            let node: Node
            if depthFirst {
                node = pending.removeLast()
            } else {
                node = pending[index]
                index += 1
            }
            nodes.append(node)
            if !descend(node) { continue }
            let remaining = limit - seen.count
            guard let next = children(node, remaining), next.count <= remaining else { return nil }
            for child in depthFirst ? Array(next.reversed()) : next where seen.insert(identity(child)).inserted {
                pending.append(child)
            }
        }
        return withinDeadline() ? nodes : nil
    }

    static func elements(
        _ root: AXUIElement, limit: Int = 6000, timeout: Double = 3, depthFirst: Bool = false,
        descend: (AXUIElement) -> Bool = { _ in true }
    ) -> [AXUIElement]? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return collect(
            root, limit: limit, withinDeadline: { ProcessInfo.processInfo.systemUptime < deadline },
            depthFirst: depthFirst,
            identity: { Identity(element: $0) },
            children: { element, remaining in
                AXUIElementSetMessagingTimeout(element, 0.1)
                var count: CFIndex = 0
                let status = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
                if status == .noValue || status == .attributeUnsupported { return [] }
                guard status == .success, count >= 0, count <= remaining else { return nil }
                if count == 0 { return [] }
                var values: CFArray?
                guard
                    AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values)
                        == .success,
                    let children = values as? [AXUIElement], children.count == count
                else { return nil }
                return children
            },
            descend: { element in
                AXUIElementSetMessagingTimeout(element, 0.1)
                return descend(element)
            })
    }
}
