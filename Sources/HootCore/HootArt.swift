import Foundation

/// One cell of Hoot's 18x18 pixel grid.
public enum HootPixel: Sendable, Equatable {
    case empty, body, lid, belly, eye, pupil, beak, feet

    /// Whether the cell is opaque in the monochrome menu-bar template.
    /// Eyes and beak are cut out so the face still reads at 18pt.
    public var isFilledInTemplate: Bool {
        switch self {
        case .body, .lid, .belly, .pupil, .feet: true
        case .empty, .eye, .beak: false
        }
    }
}

public enum HootEyes: Sendable, Equatable {
    /// Idle: round eyes.
    case normal
    /// Alert: eyes stretched taller and wider.
    case wide
    /// Mid-blink.
    case closed
}

/// Hoot, the Hoot owl. The single source of truth for every rendering of the mascot.
public enum HootArt {
    public static let size = 18

    // Legend: . empty, # body, f belly, w eye white, p pupil, b beak, y feet
    static let base: [String] = [
        "..................",
        "..##..........##..",
        "..###........###..",
        "..##############..",
        ".################.",
        ".##wwww####wwww##.",
        ".#wwwwww##wwwwww#.",
        ".#wwppww##wwppww#.",
        ".#wwppww##wwppww#.",
        ".#wwwwww##wwwwww#.",
        ".##wwww#bb#wwww##.",
        ".#######bb#######.",
        ".####ffffffff####.",
        ".###ffffffffff###.",
        "..##ffffffffff##..",
        "...###ffffff###...",
        ".....yy....yy.....",
        "..................",
    ]

    /// Extra eye-white cells for the wide (alert) state: raised brows and squared-off top corners.
    static let wideEyeCells: Set<[Int]> = [
        [4, 3], [4, 4], [4, 5], [4, 6], [4, 11], [4, 12], [4, 13], [4, 14],
        [5, 2], [5, 7], [5, 10], [5, 15],
    ]

    public static func grid(eyes: HootEyes) -> [[HootPixel]] {
        base.enumerated().map { row, line in
            line.enumerated().map { col, ch in
                let px = pixel(for: ch)
                switch eyes {
                case .normal:
                    return px
                case .wide:
                    return wideEyeCells.contains([row, col]) ? .eye : px
                case .closed:
                    return px == .eye || px == .pupil ? .lid : px
                }
            }
        }
    }

    static func pixel(for ch: Character) -> HootPixel {
        switch ch {
        case "#": .body
        case "f": .belly
        case "w": .eye
        case "p": .pupil
        case "b": .beak
        case "y": .feet
        default: .empty
        }
    }
}

public struct RGBA: Sendable, Equatable {
    public let r, g, b, a: Double

    public init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }
}

/// Full-color palette: slate-indigo owl, cream belly, amber beak, on a teal tile.
public enum HootPalette {
    public static let backgroundTop = RGBA(hex: 0x7FD1C7)
    public static let backgroundBottom = RGBA(hex: 0x2F8F9D)

    public static func color(for px: HootPixel) -> RGBA? {
        switch px {
        case .empty: nil
        case .body: RGBA(hex: 0x3E4C7A)
        case .lid: RGBA(hex: 0x2B365C)
        case .belly: RGBA(hex: 0xEBDDBE)
        case .eye: RGBA(hex: 0xFFFFFF)
        case .pupil: RGBA(hex: 0x141826)
        case .beak, .feet: RGBA(hex: 0xF4A93B)
        }
    }
}
