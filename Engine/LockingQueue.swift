import Foundation
import Dispatch

// A relatively inefficient queue type for low-contention multithreaded operation.
// All peek/pop operations block the calling thread until all previous writes have
// been resolved. Concurrent enqueues are resolved in the order of insertion.
class LockingQueue<Element: Sendable> : @unchecked Sendable {
    private let queue = DispatchQueue(label: "concurrent-read-write-queue", attributes: .concurrent)

    private var _elements: [Element] = []

    func enqueue(_ element: Element) {
        queue.async(flags: .barrier) {
            self._elements.append(element)
        }
    }

    func enqueue(_ elements: [Element]) {
        queue.async(flags: .barrier) {
            self._elements.append(contentsOf: elements)
        }
    }

    func peek() -> Element? {
        return queue.sync {
            return _elements.first
        }
    }

    func pop() -> Element? {
        return queue.sync {
            return _elements.removeFirst()
        }
    }

    func popAll() -> [Element] {
        return queue.sync {
            let result = _elements
            _elements.removeAll()
            return result
        }
    }
}
