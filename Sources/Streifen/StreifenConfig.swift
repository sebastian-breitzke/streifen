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
        cycleWidths: [0.33, 0.50, 0.66],
        categories: [:],
        categoryOrder: ["other"],
        pinned: [:],
        bindings: [:]
    )
}
