import UIKit

enum NaviPalette {
  static let ink = UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0.96, green: 0.96, blue: 0.93, alpha: 1)
    : UIColor(red: 0.16, green: 0.17, blue: 0.16, alpha: 1) }
  static let paper = UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0.10, green: 0.11, blue: 0.10, alpha: 1)
    : UIColor(red: 0.98, green: 0.976, blue: 0.96, alpha: 1) }
  static let field = UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(white: 0.17, alpha: 1) : UIColor(white: 0.93, alpha: 1) }
  static func text(_ de: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("de") == true ? de : en
  }
  static func label(_ text: String = "", size: CGFloat = 17, weight: UIFont.Weight = .regular) -> UILabel {
    let label = UILabel()
    label.text = text
    label.textColor = ink
    label.numberOfLines = 0
    label.font = UIFontMetrics.default.scaledFont(for: .systemFont(ofSize: size, weight: weight))
    label.adjustsFontForContentSizeCategory = true
    return label
  }
  static func button(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> UIButton {
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.baseBackgroundColor = primary ? ink : field
    configuration.baseForegroundColor = primary ? paper : ink
    configuration.cornerStyle = .capsule
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
    let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    return button
  }
}

