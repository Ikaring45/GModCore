/// Deterministic panel-ID ordering without rescanning all pending panels for
/// every layout callback. Membership remains a set; the heap is only an index.
struct GMLuaVGUILayoutWorklist {
    private var members: Set<Int> = []
    private var heap: [Int] = []

    var isEmpty: Bool { members.isEmpty }

    mutating func insert(_ identifier: Int) {
        guard members.insert(identifier).inserted else { return }
        heap.append(identifier)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child] < heap[parent] else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func remove(_ identifier: Int) {
        members.remove(identifier)
        // Scoped rendering can remove non-minimum entries. Bound those stale
        // index entries even if the remaining minimum never changes.
        if heap.count > members.count * 2 + 64 {
            heap = members.sorted()
        }
    }

    mutating func minimum() -> Int? {
        while let first = heap.first {
            if members.contains(first) { return first }
            let last = heap.removeLast()
            guard !heap.isEmpty else { continue }
            heap[0] = last
            var parent = 0
            while parent * 2 + 1 < heap.count {
                let left = parent * 2 + 1
                let right = left + 1
                let child = right < heap.count && heap[right] < heap[left] ? right : left
                guard heap[child] < heap[parent] else { break }
                heap.swapAt(child, parent)
                parent = child
            }
        }
        return nil
    }

    func filter(_ predicate: (Int) -> Bool) -> [Int] {
        members.filter(predicate)
    }

    func contains(where predicate: (Int) -> Bool) -> Bool {
        members.contains(where: predicate)
    }
}
