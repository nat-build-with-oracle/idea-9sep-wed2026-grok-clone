import AppKit
import SwiftUI

enum ShellTheme {
  static let backgroundNSColor = adaptive(dark: 0x070707, light: 0xfafafa)
  static let sidebarNSColor = adaptive(dark: 0x111111, light: 0xf1f2f4)
  static let bubbleNSColor = adaptive(dark: 0x262626, light: 0xe8e9eb)
  static let selectedNSColor = adaptive(dark: 0x353535, light: 0xd8dadf)
  static let composerNSColor = adaptive(dark: 0x2d2d2d, light: 0xe7e8ea)
  static let secondaryNSColor = adaptive(dark: 0xababab, light: 0x5c6066)
  static let foregroundNSColor = adaptive(dark: 0xf3f3f3, light: 0x1b1c1e)
  static let separatorNSColor = adaptive(dark: 0x292929, light: 0xcdd0d5)
  static let accentNSColor = adaptive(dark: 0x3295f6, light: 0x0068d9)

  static let pickerHighlightNSColor = adaptive(dark: 0x454545, light: 0xd8dadf)
  static let panelNSColor = adaptive(dark: 0x2d2d2d, light: 0xffffff)
  static let decorativeFillNSColor = adaptive(
    dark: 0xffffff, light: 0x000000, darkAlpha: 0.05, lightAlpha: 0.05)
  static let outlineNSColor = adaptive(
    dark: 0xffffff, light: 0x000000, darkAlpha: 0.11, lightAlpha: 0.14)
  static let menuShadowNSColor = adaptive(
    dark: 0x000000, light: 0x000000, darkAlpha: 0.30, lightAlpha: 0.16)
  static let avatarSelectionRingNSColor = adaptive(dark: 0xffffff, light: 0x1b1c1e)
  static let contrastNSColor = adaptive(dark: 0xffffff, light: 0x000000)
  static let userBubbleNSColor = adaptive(dark: 0x5a5a5a, light: 0xd9e8fc)
  static let disconnectedPanelNSColor = adaptive(dark: 0x191919, light: 0xe8e9eb)
  static let sendButtonNSColor = adaptive(dark: 0xffffff, light: 0x1b1c1e)
  static let profileIconNSColor = adaptive(dark: 0x7aaef0, light: 0x0068d9)
  static let warningNSColor = adaptive(dark: 0xff9f0a, light: 0x924600)

  static let background = Color(nsColor: backgroundNSColor)
  static let sidebar = Color(nsColor: sidebarNSColor)
  static let bubble = Color(nsColor: bubbleNSColor)
  static let selected = Color(nsColor: selectedNSColor)
  static let composer = Color(nsColor: composerNSColor)
  static let secondary = Color(nsColor: secondaryNSColor)
  static let foreground = Color(nsColor: foregroundNSColor)
  static let separator = Color(nsColor: separatorNSColor)
  static let accent = Color(nsColor: accentNSColor)
  static let pickerHighlight = Color(nsColor: pickerHighlightNSColor)
  static let panel = Color(nsColor: panelNSColor)
  static let decorativeFill = Color(nsColor: decorativeFillNSColor)
  static let outline = Color(nsColor: outlineNSColor)
  static let menuShadow = Color(nsColor: menuShadowNSColor)
  static let avatarSelectionRing = Color(nsColor: avatarSelectionRingNSColor)
  static let contrast = Color(nsColor: contrastNSColor)
  static let userBubble = Color(nsColor: userBubbleNSColor)
  static let disconnectedPanel = Color(nsColor: disconnectedPanelNSColor)
  static let sendButton = Color(nsColor: sendButtonNSColor)
  static let profileIcon = Color(nsColor: profileIconNSColor)
  static let warning = Color(nsColor: warningNSColor)

  static let colors: [String] = ["green", "magenta", "gray", "violet", "blue", "orange"]
  static func avatarColor(_ name: String) -> Color {
    switch name {
    case "magenta": Color(hex: 0xe02a88)
    case "gray": Color(hex: 0x777777)
    case "violet": Color(hex: 0x804ee0)
    case "blue": Color(hex: 0x0e74e0)
    case "orange": Color(hex: 0xff6700)
    default: Color(hex: 0x009957)
    }
  }

  private static func adaptive(
    dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1
  ) -> NSColor {
    NSColor(name: nil) { appearance in
      let useDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return NSColor(hex: useDark ? dark : light, alpha: useDark ? darkAlpha : lightAlpha)
    }
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
  }
}

extension NSColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 255) / 255,
      green: CGFloat((hex >> 8) & 255) / 255,
      blue: CGFloat(hex & 255) / 255,
      alpha: alpha)
  }
}

struct BotContour: Shape {
  var kind: AvatarKind
  func path(in rect: CGRect) -> Path {
    switch kind {
    case .circle:
      return Path(ellipseIn: rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.05))
    case .square:
      return Path(
        roundedRect: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.07),
        cornerRadius: rect.width * 0.22)
    case .capsule:
      return Path(
        roundedRect: rect.insetBy(dx: 0, dy: rect.height * 0.18), cornerRadius: rect.height * 0.4)
    case .drop:
      var p = Path()
      let w = rect.width
      let h = rect.height
      p.move(to: CGPoint(x: w * 0.50, y: h * 0.02))
      p.addCurve(
        to: CGPoint(x: w * 0.93, y: h * 0.65), control1: CGPoint(x: w * 0.62, y: h * 0.15),
        control2: CGPoint(x: w * 0.93, y: h * 0.48))
      p.addCurve(
        to: CGPoint(x: w * 0.49, y: h * 0.99), control1: CGPoint(x: w, y: h * 0.87),
        control2: CGPoint(x: w * 0.72, y: h))
      p.addCurve(
        to: CGPoint(x: w * 0.09, y: h * 0.63), control1: CGPoint(x: w * 0.25, y: h),
        control2: CGPoint(x: w * 0.04, y: h * 0.84))
      p.addCurve(
        to: CGPoint(x: w * 0.50, y: h * 0.02), control1: CGPoint(x: w * 0.12, y: h * 0.44),
        control2: CGPoint(x: w * 0.41, y: h * 0.11))
      return p
    }
  }
}

struct BotAvatar: View {
  var color: String = "green"
  var shape: AvatarKind = .circle
  var size: CGFloat = 42
  var body: some View {
    ZStack {
      BotContour(kind: shape).fill(ShellTheme.avatarColor(color))
      HStack(spacing: size * 0.15) {
        Capsule().frame(width: size * 0.072, height: size * 0.16)
        Capsule().frame(width: size * 0.072, height: size * 0.16)
      }
      .foregroundStyle(Color.black.opacity(0.85))
      .rotationEffect(.degrees(-18)).offset(x: size * 0.07, y: -size * 0.065)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct ShellIconButton: View {
  let symbol: String
  let label: String
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(
        width: 32, height: 32)
    }
    .buttonStyle(.plain).foregroundStyle(ShellTheme.secondary)
    .help(label).accessibilityLabel(label)
  }
}
