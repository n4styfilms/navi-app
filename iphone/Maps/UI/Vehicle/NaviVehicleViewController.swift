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

/// A draft stays in the fields until explicit save. Cancel and validation never write the profile.
final class NaviVehicleViewController: UIViewController {
  var onChange: (() -> Void)?
  private let store: NaviVehicleStore
  private var fields: [NaviVehicleInput.Field: UITextField] = [:]
  private var errors: [NaviVehicleInput.Field: UILabel] = [:]
  private let fuel = UISegmentedControl(items: [NaviPalette.text("Benzin", "Petrol"), "Diesel"])
  private let message = NaviPalette.label(size: 14)
  private var blocked = false
  private var saveButton: UIButton!

  init(store: NaviVehicleStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Use init(store:)") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = NaviPalette.paper
    view.tintColor = NaviPalette.ink
    title = NaviPalette.text("Dein Fahrzeug", "Your vehicle")
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: NaviPalette.text("Abbrechen", "Cancel"),
      style: .plain, target: self, action: #selector(cancel))
    let scroll = UIScrollView()
    scroll.keyboardDismissMode = .interactive
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
    ])
    stack.addArrangedSubview(NaviPalette.label(NaviPalette.text(
      "WLTP ist ein Richtwert. Dein eigener Durchschnitt macht die Schätzung persönlicher.",
      "WLTP is a reference value. Your own average makes the estimate more personal."), size: 15))
    for (field, title) in [(NaviVehicleInput.Field.make, NaviPalette.text("Marke", "Make")),
                           (.model, NaviPalette.text("Modell", "Model")),
                           (.engine, NaviPalette.text("Motor", "Engine")),
                           (.year, NaviPalette.text("Baujahr", "Year")),
                           (.fuel, NaviPalette.text("Kraftstoff", "Fuel")),
                           (.wltp, "WLTP · l/100 km"),
                           (.price, NaviPalette.text("Literpreis · €", "Price per liter · €")),
                           (.personal, NaviPalette.text("Eigener Durchschnitt · l/100 km (optional)",
                                                       "Your average · l/100 km (optional)"))] {
      stack.addArrangedSubview(NaviPalette.label(title, size: 14, weight: .medium))
      if field == .fuel {
        fuel.selectedSegmentIndex = UISegmentedControl.noSegment
        fuel.selectedSegmentTintColor = NaviPalette.paper
        fuel.backgroundColor = NaviPalette.field
        fuel.setTitleTextAttributes([.foregroundColor: NaviPalette.ink], for: .normal)
        fuel.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        fuel.accessibilityLabel = title
        stack.addArrangedSubview(fuel)
      } else {
        let input = UITextField()
        input.accessibilityLabel = title
        input.backgroundColor = NaviPalette.field
        input.textColor = NaviPalette.ink
        input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true
        input.layer.cornerRadius = 18
        input.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 48))
        input.leftViewMode = .always
        input.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 48))
        input.rightViewMode = .always
        input.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        if field == .year { input.keyboardType = .numberPad }
        if [.wltp, .price, .personal].contains(field) { input.keyboardType = .decimalPad }
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
          UIBarButtonItem(title: NaviPalette.text("Fertig", "Done"), style: .done,
                          target: self, action: #selector(finishEditing))]
        toolbar.sizeToFit()
        input.inputAccessoryView = toolbar
        fields[field] = input
        stack.addArrangedSubview(input)
      }
      let error = NaviPalette.label(size: 13)
      error.textColor = .systemRed
      error.isHidden = true
      errors[field] = error
      stack.addArrangedSubview(error)
    }
    stack.addArrangedSubview(message)
    saveButton = NaviPalette.button(NaviPalette.text("Speichern", "Save"), primary: true) { [weak self] in self?.save() }
    stack.addArrangedSubview(saveButton)
    stack.addArrangedSubview(NaviPalette.button(NaviPalette.text("Fahrzeug löschen", "Delete vehicle")) { [weak self] in self?.confirmDelete() })
    load()
  }

  private func load() {
    do {
      let result = try store.load()
      blocked = result.status == .invalid || result.status == .unsupportedSchema
      saveButton.isEnabled = !blocked
      message.text = blocked ? NaviPalette.text(
        "Gespeicherte Daten können nicht gelesen werden. Sie bleiben erhalten. Lösche sie ausdrücklich, um neu anzufangen.",
        "Stored data cannot be read and is preserved. Explicitly delete it to start again.") : nil
      let p = result.profile
      fields[.make]?.text = p?.make
      fields[.model]?.text = p?.model
      fields[.engine]?.text = p?.engine
      fields[.year]?.text = p?.year.map { String($0) }
      fields[.wltp]?.text = p?.wltpLitersPer100Km.map { String($0) }
      fields[.price]?.text = p?.pricePerLiter.map { String($0) }
      fields[.personal]?.text = p?.personalLitersPer100Km.map { String($0) }
      fuel.selectedSegmentIndex = p?.fuelType.map { $0 == .petrol ? 0 : 1 } ?? UISegmentedControl.noSegment
    } catch {
      blocked = true
      saveButton.isEnabled = false
      message.text = NaviPalette.text("Fahrzeug konnte nicht geladen werden.", "Could not load vehicle.")
    }
  }

  private func save() {
    guard !blocked else { return }
    func text(_ field: NaviVehicleInput.Field) -> String { fields[field]?.text ?? "" }
    let result = NaviVehicleInput.parse(make: text(.make), model: text(.model), engine: text(.engine),
      year: text(.year), fuel: fuel.selectedSegmentIndex == 0 ? "PETROL" : fuel.selectedSegmentIndex == 1 ? "DIESEL" : "",
      wltp: text(.wltp), price: text(.price), personal: text(.personal))
    for field in NaviVehicleInput.Field.allCases {
      errors[field]?.isHidden = result.errors[field] == nil
      errors[field]?.text = result.errors[field] == .required
        ? NaviPalette.text("Bitte ausfüllen.", "Required.")
        : NaviPalette.text("Bitte einen gültigen Wert eingeben.", "Enter a valid value.")
    }
    guard let profile = result.profile else {
      if let first = NaviVehicleInput.Field.allCases.first(where: { result.errors[$0] != nil }) {
        fields[first]?.becomeFirstResponder()
      }
      return
    }
    do {
      try store.save(profile)
      onChange?()
      dismiss(animated: true)
    } catch { message.text = NaviPalette.text("Speichern fehlgeschlagen. Bitte erneut versuchen.", "Save failed. Please try again.") }
  }

  private func confirmDelete() {
    let alert = UIAlertController(title: NaviPalette.text("Fahrzeug löschen?", "Delete vehicle?"),
      message: NaviPalette.text("Die lokal gespeicherten Fahrzeugdaten werden entfernt.", "This removes the locally stored vehicle data."),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: NaviPalette.text("Abbrechen", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: NaviPalette.text("Löschen", "Delete"), style: .destructive) { [weak self] _ in
      guard let self else { return }
      do {
        try self.store.delete()
        self.onChange?()
        self.load()
      } catch { self.message.text = NaviPalette.text("Löschen fehlgeschlagen.", "Delete failed.") }
    })
    present(alert, animated: true)
  }
  @objc private func cancel() { dismiss(animated: true) }
  @objc private func finishEditing() { view.endEditing(true) }
}
