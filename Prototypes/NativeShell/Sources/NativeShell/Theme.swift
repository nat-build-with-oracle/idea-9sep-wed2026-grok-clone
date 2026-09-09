import SwiftUI

enum ShellTheme {
  static let background = Color(hex: 0x070707)
  static let sidebar = Color(hex: 0x111111)
  static let bubble = Color(hex: 0x262626)
  static let selected = Color(hex: 0x353535)
  static let composer = Color(hex: 0x2d2d2d)
  static let secondary = Color(hex: 0xababab)
  static let foreground = Color(hex: 0xf3f3f3)
  static let separator = Color(hex: 0x292929)
  static let accent = Color(hex: 0x3295f6)
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
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
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
