/// Design spec v4 §1 and §1.1. Dark is the only appearance; there is no light palette.
enum Palette {
    static let ground = ColorToken(0x09090B)
    static let surface = ColorToken(0x131316)
    static let surfaceRaised = ColorToken(0x1C1D20)
    static let surfaceRaised2 = ColorToken(0x28292D)

    static let ink = ColorToken(0xF1F1EF)
    static let inkMuted = ColorToken(0x8A8C91)
    static let inkFaint = ColorToken(0x55575C)

    /// The single accent. Selection, primary buttons, focus — never "needs attention" (that is `alert`).
    static let accent = ColorToken(0x8B93F8)
    static let accentInk = ColorToken(0x0C0D1A)
    static let accentSoft = ColorToken(0x8B93F8, opacity: 0.13)

    static let alert = ColorToken(0xE8695C)
    /// The unread count's red, as WeChat has it (user 2026-09-15) — never for anything else.
    static let unread = ColorToken(0xFA5151)
    static let alertInk = ColorToken(0x1A0B08)
    static let alertSoft = ColorToken(0xE8695C, opacity: 0.13)
    static let alertLine = ColorToken(0xE8695C, opacity: 0.38)

    static let success = ColorToken(0x3FCB8E)
    static let successSoft = ColorToken(0x3FCB8E, opacity: 0.13)
    static let successLine = ColorToken(0x3FCB8E, opacity: 0.34)

    static let line = ColorToken(0x201F23)
    static let lineStrong = ColorToken(0x322F35)

    static let railGround = ColorToken(0x050506)
    static let railInk = ColorToken(0xC6C6C9)
    static let railInkDim = ColorToken(0x55565B)
    static let railLine = ColorToken(0x17171A)
    static let railHover = ColorToken(0xFFFFFF, opacity: 0.06)

    static let scrim = ColorToken(0x050506, opacity: 0.72)
}
