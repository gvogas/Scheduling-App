// CarPlayImages — the three images a CarPlay row draws for itself.
//
// A CPListItem is exactly text + detailText + image + one accessory, so
// anything richer than two strings has to be rendered. All three are drawn
// with UIGraphicsImageRenderer at the CarPlay image slot size.
//
// The crew colours mirror `crewColorOf` and `avatarForegroundFor`
// (lib/core/theme/design_tokens.dart) — the snapshot stores the LIGHT-theme
// ARGB and the car does the dark lift, never the other way round.
//
// This file is compiled only on macOS/Xcode.

import CarPlay
import UIKit

enum CarPlayImages {
    /// The head unit's own image slot, which is what sizes the time tile's
    /// text. Read from `CPListItem` rather than assumed, because the slot is
    /// per-vehicle and a wrong box means illegible times.
    static var slotSize: CGSize {
        let maximum = CPListItem.maximumImageSize
        guard maximum.width >= 1, maximum.height >= 1 else {
            return fallbackSlotSize
        }
        return maximum
    }

    /// Used only when the framework reports no maximum, which it should never
    /// do; it is the size this file assumed before it asked.
    private static let fallbackSlotSize = CGSize(width: 44, height: 44)

    // MARK: - Crew avatar (admin rows)

    /// Initials on the lead assignee's stored colour, a white ring when the
    /// viewer is on the job, and a `+N` badge for a multi-crew job. Nil for a
    /// job with no crew, which is what a v3 snapshot still on disk gives.
    static func crewAvatar(
        crew: [SnapshotCrewMember],
        isOwn: Bool,
        style: UIUserInterfaceStyle
    ) -> UIImage? {
        guard let lead = crew.first else { return nil }
        let size = slotSize
        let key = """
        avatar|\(lead.name)|\(lead.storedColor)|\(crew.count)|\(isOwn)\
        |\(style.rawValue)|\(size.width)x\(size.height)
        """
        return cached(key) {
            let background = crewColor(lead.storedColor, style: style)
            let foreground = avatarForeground(on: background, style: style)
            let bounds = CGRect(origin: .zero, size: size)
            return render(size: size) {
                let circle = bounds.insetBy(dx: isOwn ? 2 : 0, dy: isOwn ? 2 : 0)
                if isOwn {
                    UIColor.white.setStroke()
                    let ring = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
                    ring.lineWidth = 2
                    ring.stroke()
                }
                background.setFill()
                UIBezierPath(ovalIn: circle).fill()
                draw(
                    text: initials(of: lead.name),
                    in: circle,
                    color: foreground,
                    maxFontSize: 17,
                    weight: .bold)
                guard crew.count > 1 else { return }
                drawBadge("+\(crew.count - 1)", in: bounds, style: style)
            }
        }
    }

    // MARK: - Time tile (technician rows)

    /// The start time in a rounded square, tinted by the job's clock state.
    static func timeTile(
        _ text: String,
        state: CarPlayJobState,
        style: UIUserInterfaceStyle
    ) -> UIImage {
        let size = slotSize
        let key = """
        tile|\(text)|\(state.rawValue)|\(style.rawValue)\
        |\(size.width)x\(size.height)
        """
        if let hit = cache[key] { return hit }
        let tint = stateColor(state, style: style)
        let tile = render(size: size) {
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 5)
            tint.withAlphaComponent(0.18).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 8).fill()
            draw(
                text: text,
                in: box,
                color: tint,
                maxFontSize: 15,
                weight: .semibold)
        }
        remember(key, tile)
        return tile
    }

    // MARK: - State accessory

    /// The state's glyph — clock for overdue, play for in progress — tinted and
    /// drawn at the same slot size the framework reports for a row image, which
    /// is the only size CarPlay publishes. Nil for a state the row does not
    /// call out; the word itself lives on the section header and the detail.
    static func stateAccessory(
        _ state: CarPlayJobState,
        style: UIUserInterfaceStyle
    ) -> UIImage? {
        guard let glyphName = glyph(for: state) else { return nil }
        let size = slotSize
        let key = """
        state|\(state.rawValue)|\(style.rawValue)|\(size.width)x\(size.height)
        """
        return cached(key) {
            let tint = stateColor(state, style: style)
            let configuration = UIImage.SymbolConfiguration(
                pointSize: min(size.height * 0.45, 22), weight: .semibold)
            guard
                let glyph = UIImage(
                    systemName: glyphName, withConfiguration: configuration)?
                    .withTintColor(tint, renderingMode: .alwaysOriginal)
            else { return nil }
            return render(size: size) {
                glyph.draw(in: centered(glyph.size, in: size))
            }
        }
    }

    // MARK: - Colours

    /// Mirrors `crewColorOf`: the canonical hues hit an exact dark
    /// counterpart, anything custom-picked takes the generic HSL lift.
    private static func crewColor(
        _ storedArgb: Int, style: UIUserInterfaceStyle
    ) -> UIColor {
        let stored = color(fromArgb: storedArgb)
        guard style == .dark else { return stored }
        if let mapped = darkCrewOverride[storedArgb] {
            return color(fromArgb: mapped)
        }
        var lifted = hsl(of: stored)
        lifted.lightness = min(lifted.lightness + 0.18, 0.92)
        lifted.saturation = min(lifted.saturation * 0.9, 1)
        return color(from: lifted)
    }

    /// Mirrors `avatarForegroundFor`: plain contrast in light, a near-black
    /// tint of the surface's own hue in dark.
    private static func avatarForeground(
        on background: UIColor, style: UIUserInterfaceStyle
    ) -> UIColor {
        guard style == .dark else {
            return isLight(background) ? .black : .white
        }
        var ink = hsl(of: background)
        ink.saturation = min(ink.saturation * 0.7, 1)
        ink.lightness = 0.07
        return color(from: ink)
    }

    private static func stateColor(
        _ state: CarPlayJobState, style: UIUserInterfaceStyle
    ) -> UIColor {
        let dark = style == .dark
        switch state {
        case .overdue:
            return color(fromArgb: dark ? 0xFFFF_8A4C : 0xFFF5_4A00)
        case .inProgress:
            return color(fromArgb: dark ? 0xFF1F_A97A : 0xFF0E_9B6E)
        case .scheduled, .done, .cancelled:
            return color(fromArgb: dark ? 0xFFEE_F2F8 : 0xFF0B_1A33)
        }
    }

    private static func glyph(for state: CarPlayJobState) -> String? {
        switch state {
        case .overdue: return "clock.fill"
        case .inProgress: return "play.fill"
        case .scheduled, .done, .cancelled: return nil
        }
    }

    private static let darkCrewOverride: [Int: Int] = [
        0xFF00_5CC8: 0xFF4B_90F7,
        0xFF7A_3FF2: 0xFF9B_6BFF,
        0xFF0E_9B6E: 0xFF2B_C48E,
        0xFFE0_8A00: 0xFFF1_A83C,
        0xFF00_A5C4: 0xFF35_C2DE,
        0xFFC4_3F8E: 0xFFE4_5FA8,
        0xFFD6_1F3A: 0xFFFF_6076,
        0xFF5A_6B85: 0xFF85_93A9,
        0xFF8A_5A2B: 0xFFC9_985A,
        0xFF7A_8F1F: 0xFFB9_CC45,
    ]

    // MARK: - Render cache

    /// Every visible row is re-rendered on each 60 s re-rank, and a day is a
    /// handful of distinct tiles and avatars — so the same images come back.
    /// Main-queue only, like every other CarPlay callback.
    private static var cache: [String: UIImage] = [:]

    private static let cacheLimit = 64

    /// Dropped on scene disconnect: the images are sized to THAT head unit.
    static func clearCache() {
        cache.removeAll()
    }

    private static func cached(_ key: String, _ make: () -> UIImage?) -> UIImage? {
        if let hit = cache[key] { return hit }
        guard let made = make() else { return nil }
        remember(key, made)
        return made
    }

    private static func remember(_ key: String, _ image: UIImage) {
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = image
    }

    // MARK: - Drawing helpers

    private static func render(
        size: CGSize, _ body: () -> Void
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in body() }
            .withRenderingMode(.alwaysOriginal)
    }

    private static func draw(
        text: String,
        in rect: CGRect,
        color: UIColor,
        maxFontSize: CGFloat,
        weight: UIFont.Weight
    ) {
        let string = text as NSString
        var font = UIFont.systemFont(ofSize: maxFontSize, weight: weight)
        var measured = string.size(withAttributes: [.font: font])
        // Shrink rather than truncate: "13:30" has to survive a 44 pt slot.
        while measured.width > rect.width - 4, font.pointSize > 8 {
            font = UIFont.systemFont(ofSize: font.pointSize - 1, weight: weight)
            measured = string.size(withAttributes: [.font: font])
        }
        string.draw(
            at: CGPoint(
                x: rect.midX - measured.width / 2,
                y: rect.midY - measured.height / 2),
            withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func drawBadge(
        _ text: String, in bounds: CGRect, style: UIUserInterfaceStyle
    ) {
        let string = text as NSString
        let fill = style == .dark ? UIColor.white : UIColor.black
        let ink = style == .dark ? UIColor.black : UIColor.white
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: ink,
        ]
        let measured = string.size(withAttributes: attributes)
        let pill = CGRect(
            x: bounds.maxX - measured.width - 9,
            y: bounds.maxY - measured.height - 3,
            width: measured.width + 6,
            height: measured.height + 2)
        fill.setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
        string.draw(
            at: CGPoint(x: pill.minX + 3, y: pill.minY + 1),
            withAttributes: attributes)
    }

    private static func centered(_ inner: CGSize, in outer: CGSize) -> CGRect {
        CGRect(
            x: (outer.width - inner.width) / 2,
            y: (outer.height - inner.height) / 2,
            width: inner.width,
            height: inner.height)
    }

    /// Two-letter initials from the first and last word, mirroring
    /// `nameInitials` — first GRAPHEME of each word, never `word[0]`.
    private static func initials(of name: String) -> String {
        let words = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else {
            return String(first).uppercased()
        }
        return "\(first)\(last)".uppercased()
    }

    // MARK: - Colour maths

    private struct HSLColor {
        var hue: Double
        var saturation: Double
        var lightness: Double
    }

    private static func color(fromArgb argb: Int) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }

    /// Mirrors `ThemeData.estimateBrightnessForColor` — WCAG relative
    /// luminance against Flutter's own 0.15 threshold, not a naive average.
    private static func isLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0
        var blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance =
            0.2126 * linearize(Double(red))
            + 0.7152 * linearize(Double(green))
            + 0.0722 * linearize(Double(blue))
        return (luminance + 0.05) * (luminance + 0.05) > 0.15
    }

    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.03928
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func hsl(of source: UIColor) -> HSLColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        source.getRed(&r, green: &g, blue: &b, alpha: &a)
        let red = Double(r), green = Double(g), blue = Double(b)
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard delta > 0 else {
            return HSLColor(hue: 0, saturation: 0, lightness: lightness)
        }
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)
        var hue: Double
        if maximum == red {
            hue = (green - blue) / delta + (green < blue ? 6 : 0)
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        return HSLColor(
            hue: hue * 60, saturation: saturation, lightness: lightness)
    }

    private static func color(from hsl: HSLColor) -> UIColor {
        let chroma = (1 - abs(2 * hsl.lightness - 1)) * hsl.saturation
        let sector = hsl.hue / 60
        let second = chroma
            * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let match = hsl.lightness - chroma / 2
        var red = 0.0, green = 0.0, blue = 0.0
        switch sector {
        case ..<1: (red, green, blue) = (chroma, second, 0)
        case ..<2: (red, green, blue) = (second, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, second)
        case ..<4: (red, green, blue) = (0, second, chroma)
        case ..<5: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        return UIColor(
            red: CGFloat(red + match),
            green: CGFloat(green + match),
            blue: CGFloat(blue + match),
            alpha: 1)
    }
}
