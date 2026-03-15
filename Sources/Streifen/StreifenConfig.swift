import Foundation

struct StreifenConfig: Sendable {
    var gap: CGFloat
    var cycleWidths: [CGFloat]
    var categories: [String: [String]]
    var categoryOrder: [String]
    var pinned: [Int: [String]]
    var bindings: [String: String]

    static let `default` = StreifenConfig(
        gap: 10,
        cycleWidths: [0.25, 1.0/3.0, 0.50, 2.0/3.0, 0.75, 1.0],
        categories: [:],
        categoryOrder: ["other"],
        pinned: [:],
        bindings: [:]
    )
}
