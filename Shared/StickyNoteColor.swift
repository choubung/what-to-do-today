import Foundation

/// Opaque sRGB color shared by persistence and the app, with a canonical #RRGGBB representation.
struct StickyNoteColor: Equatable, Sendable {
    let hex: String
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.utf8.count == 6,
              digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              let value = UInt32(digits, radix: 16) else { return nil }
        self.hex = "#" + digits
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }

    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Choose the higher-contrast black or white foreground for arbitrary custom colors.
    var usesDarkText: Bool {
        (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
    }
}
