import Foundation

/// A dotted numeric version such as `26.1.26134.173934`, compared component by component.
struct BPTVersion: Comparable, CustomStringConvertible, Hashable {
    let components: [Int]

    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        self.components = components
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: BPTVersion, rhs: BPTVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: BPTVersion, rhs: BPTVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
