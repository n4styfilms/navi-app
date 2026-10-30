import UIKit

@MainActor private enum FriendsUI {
  static func column(spacing: CGFloat = 12) -> UIStackView {
    let value = UIStackView(); value.axis = .vertical; value.spacing = spacing; return value
  }
  static func clear(_ stack: UIStackView) {
    for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
  }
  static func button(_ title: String, id: String, primary: Bool = false,
                     action: @escaping (UIButton) -> Void) -> UIButton {
    let template = NaviPalette.button(title, primary: primary) {}
    let button = UIButton(configuration: template.configuration ?? .filled())
    button.accessibilityIdentifier = id
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.addAction(UIAction { [weak button] _ in if let button { action(button) } }, for: .touchUpInside)
    return button
  }
  static func field(_ placeholder: String, id: String, secure: Bool = false) -> UITextField {
    let field = UITextField()
    field.accessibilityIdentifier = id; field.accessibilityLabel = placeholder; field.placeholder = placeholder
    field.textColor = NaviPalette.ink; field.tintColor = NaviPalette.ink
    field.backgroundColor = NaviPalette.field; field.layer.cornerRadius = 16
    field.font = UIFont.preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
    field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1)); field.leftViewMode = .always
    field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1)); field.rightViewMode = .always
    field.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    field.isSecureTextEntry = secure; field.autocorrectionType = .no; field.autocapitalizationType = .none
    return field
  }
  static func layout(_ stack: UIStackView, in view: UIView) -> UIScrollView {
    let scroll = UIScrollView(); scroll.keyboardDismissMode = .interactive
    scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll); scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
    ])
    return scroll
  }
  static func navigation(_ controller: UIViewController) {
    controller.view.backgroundColor = NaviPalette.paper; controller.view.tintColor = NaviPalette.ink
    let appearance = UINavigationBarAppearance(); appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = NaviPalette.paper
    appearance.titleTextAttributes = [.foregroundColor: NaviPalette.ink]
    appearance.largeTitleTextAttributes = [.foregroundColor: NaviPalette.ink]
    controller.navigationController?.navigationBar.standardAppearance = appearance
    controller.navigationController?.navigationBar.scrollEdgeAppearance = appearance
    controller.navigationController?.navigationBar.tintColor = NaviPalette.ink
  }
  static func error(_ error: Error) -> String {
    if let input = error as? FriendsInputError { return input.errorDescription ?? "" }
    return NaviPalette.text("Das hat nicht geklappt. Bitte prüfe deine Eingaben und die Verbindung.",
                            "That did not work. Check your details and connection.")
  }
  static func superseded(_ error: Error) -> Bool {
    if let value = error as? FriendsSharingController.SharingError, case .superseded = value { return true }
    if let value = error as? FriendsSignOutCoordinator.SignOutError, case .superseded = value { return true }
    return error is CancellationError
  }
}

private enum FriendsInputError: LocalizedError {
  case wrongGroup, credentials, name, configuration
  var errorDescription: String? {
    switch self {
    case .wrongGroup: return NaviPalette.text("Bitte verwende einen Freundescode aus deiner Gruppe.", "Use a friend code from your group.")
    case .credentials: return NaviPalette.text("Bitte gib E-Mail und Passwort ein.", "Enter your email and password.")
    case .name: return NaviPalette.text("Bitte gib einen Namen mit höchstens 40 Zeichen ein.", "Enter a name of up to 40 characters.")
    case .configuration: return NaviPalette.text("Die Gruppenkonfiguration ist ungültig.", "The group configuration is invalid.")
    }
  }
}

/// A view of the application-owned runtime. Dismissing it does not stop sharing.
final class FriendsSheetController: UIViewController {
  var onRequestLocation: (() -> Void)?
  private let runtime: FriendsRuntime
  private let now: () -> Int64
  private let content = FriendsUI.column(spacing: 16)
  private let message = NaviPalette.label(size: 15)
  private let pending = NaviPalette.label(size: 15)
  private let stateLabel = NaviPalette.label(size: 15)
  private let requestList = FriendsUI.column()
  private let friendList = FriendsUI.column(spacing: 16)
  private var observation: FriendsRuntime.Observation?
  private var timer: Timer?
  private var phase = ""
  private var nameField: UITextField?
  private var displayedName: String?
  private var shareButton: UIButton?
  private var rows: [String: FriendsPeerRow] = [:]
  private var busyPeers = Set<String>()
  private var lastRequests: [String]?

  init(runtime: FriendsRuntime, now: (() -> Int64)? = nil) {
    self.runtime = runtime; self.now = now ?? { runtime.serverNowMs }
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Use init(runtime:)") }
  override func viewDidLoad() {
    super.viewDidLoad()
    FriendsUI.navigation(self)
    title = NaviPalette.text("Deine Freunde", "Your friends")
    let close = FriendsUI.button("", id: "friends.close") { [weak self] _ in self?.closeSheet() }
    close.configuration?.image = UIImage(systemName: "xmark")
    close.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    close.accessibilityLabel = NaviPalette.text("Schließen", "Close")
    close.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    navigationItem.rightBarButtonItem = UIBarButtonItem(customView: close)
    navigationController?.sheetPresentationController?.detents = [.large()]
    navigationController?.sheetPresentationController?.prefersGrabberVisible = true
    navigationController?.sheetPresentationController?.preferredCornerRadius = 30
    let scroll = FriendsUI.layout(content, in: view); scroll.accessibilityIdentifier = "friends.scroll"
    message.accessibilityIdentifier = "friends.message"
    refresh()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if observation == nil { observation = runtime.observe { [weak self] _ in self?.refresh() } }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    observation?.close(); observation = nil; timer?.invalidate(); timer = nil
  }
  deinit { timer?.invalidate() }
  @objc private func closeSheet() { view.endEditing(true); dismiss(animated: true) }

  private func phaseKey(_ value: FriendsRuntime.Snapshot) -> String {
    if !value.configured { return "group" }
    if value.signingOut { return "closing" }
    if value.accountState == .ready && !value.uid.isEmpty { return "ready/" + value.uid }
    if value.accountState == .loading || value.accountState == .ready { return "loading" }
    if value.accountState == .error { return "error" }
    return "auth"
  }
  private func refresh() {
    guard isViewLoaded else { return }
    let value = runtime.snapshot, key = phaseKey(value)
    if key != phase {
      phase = key; rows.removeAll(); busyPeers.removeAll(); lastRequests = nil
      displayedName = nil; nameField = nil; shareButton = nil
      FriendsUI.clear(content); FriendsUI.clear(requestList); FriendsUI.clear(friendList)
      message.text = nil; message.isHidden = true
      if key == "group" { buildGroup() }
      else if key == "auth" { buildAuth() }
      else if key.hasPrefix("ready/") { buildReady() }
      else {
        content.addArrangedSubview(NaviPalette.label(key == "closing"
          ? NaviPalette.text("Du wirst abgemeldet …", "Signing out …")
          : key == "error" ? NaviPalette.text("Die Verbindung konnte nicht geöffnet werden.", "Could not open the connection.")
          : NaviPalette.text("Verbindung wird hergestellt …", "Connecting …"), size: 19))
        if key != "closing" { content.addArrangedSubview(logoutButton()) }
      }
      content.addArrangedSubview(pending); content.addArrangedSubview(message)
    }
    pending.isHidden = !value.pendingRevocations && value.sharingState != .revocationPending
    pending.text = value.accountState == .signedOut
      ? NaviPalette.text("Bitte melde dich zum Abschluss der ausstehenden Pause wieder an.", "Sign in again to finish the pending pause.")
      : NaviPalette.text("Die Pause wird beim Verbinden bestätigt.", "The pause will be confirmed when reconnected.")
    guard key.hasPrefix("ready/") else { return }
    if displayedName != value.ownName && nameField?.isFirstResponder != true {
      nameField?.text = value.ownName; displayedName = value.ownName
    }
    let desired = [FriendsSharingController.State.sharing, .enabling, .reconnecting].contains(value.sharingState)
    shareButton?.configuration?.title = desired ? NaviPalette.text("Standort pausieren", "Pause location sharing")
      : NaviPalette.text("Standort teilen", "Share location")
    switch value.sharingState {
    case .sharing: stateLabel.text = NaviPalette.text("Dein Standort wird geteilt.", "Your location is being shared.")
    case .enabling, .reconnecting: stateLabel.text = NaviPalette.text("Warte auf die Verbindung …", "Waiting for a connection …")
    case .revocationPending: stateLabel.text = NaviPalette.text("Auf diesem Gerät pausiert · Bestätigung ausstehend", "Paused on this device · Confirmation pending")
    case .error: stateLabel.text = NaviPalette.text("Freigabe angehalten. Bitte prüfe die Verbindung.", "Sharing stopped. Check the connection.")
    default: stateLabel.text = NaviPalette.text("Dein Standort ist pausiert.", "Your location is paused.")
    }
    updateRequests(value.requests)
    let retained = Set(value.peers.map(\.uid))
    for uid in Array(rows.keys) where !retained.contains(uid) {
      if let row = rows.removeValue(forKey: uid) { friendList.removeArrangedSubview(row); row.removeFromSuperview() }
    }
    for peer in value.peers {
      if rows[peer.uid] == nil {
        let row = FriendsPeerRow(uid: peer.uid, onGrant: { [weak self] grant in self?.changeGrant(peer.uid, grant) },
          onRemove: { [weak self] in self?.remove(peer.uid) })
        rows[peer.uid] = row; friendList.addArrangedSubview(row)
      }
      rows[peer.uid]?.update(peer, grant: value.grants[peer.uid] ?? .init(position: false, speed: false, trips: false),
                            now: now(), busy: busyPeers.contains(peer.uid))
    }
    friendList.accessibilityLabel = value.peers.isEmpty ? NaviPalette.text("Noch keine bestätigten Freunde", "No confirmed friends yet") : nil
  }

  private func show(_ error: Error) {
    guard !FriendsUI.superseded(error) else { return }
    message.text = FriendsUI.error(error); message.isHidden = false
  }
  private func run(on button: UIButton, action: @escaping () async throws -> Void) {
    button.isEnabled = false
    Task { [weak self, weak button] in
      do { try await action() } catch { self?.show(error) }
      button?.isEnabled = true; self?.refresh()
    }
  }
  private func buildGroup() {
    content.addArrangedSubview(NaviPalette.label(NaviPalette.text(
      "Richte die kostenlose private Verbindung eurer Gruppe einmal ein. Danach meldet sich jeder mit seinem eigenen Konto an.",
      "Set up your group's free private connection once. Then each friend signs in with their own account.")))
    content.addArrangedSubview(FriendsUI.button(NaviPalette.text("Gruppe einrichten", "Set up group"), id: "friends.group.setup") { [weak self] _ in
      guard let self else { return }
      let connection = self.runtime
      let editor = FriendsTextEditor(title: NaviPalette.text("Private Gruppe", "Private group"), multiline: true,
        inputID: "friends.group.json", saveID: "friends.group.save", placeholder: NaviPalette.text("Gruppenkonfiguration", "Group configuration")) { text in
          do { try connection.configure(json: Data(text.utf8)) } catch { throw FriendsInputError.configuration }
        }
      self.present(UINavigationController(rootViewController: editor), animated: true)
    })
  }
  private func buildAuth() {
    content.addArrangedSubview(NaviPalette.label(NaviPalette.text("Melde dich in eurer privaten Gruppe an.", "Sign in to your private group.")))
    let email = FriendsUI.field("E-Mail", id: "friends.auth.email"); email.keyboardType = .emailAddress; email.textContentType = .username
    let password = FriendsUI.field(NaviPalette.text("Passwort", "Password"), id: "friends.auth.password", secure: true)
    password.textContentType = .password
    content.addArrangedSubview(email); content.addArrangedSubview(password)
    for register in [false, true] {
      content.addArrangedSubview(FriendsUI.button(register ? NaviPalette.text("Konto erstellen", "Create account") : NaviPalette.text("Anmelden", "Sign in"),
        id: register ? "friends.auth.register" : "friends.auth.login", primary: !register) { [weak self, weak email, weak password] button in
          guard let self else { return }
          let address = email?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", secret = password?.text ?? ""
          guard !address.isEmpty, !secret.isEmpty else { self.show(FriendsInputError.credentials); return }
          password?.text = ""; self.view.endEditing(true)
          let connection = self.runtime
          self.run(on: button) {
            if register { try await connection.register(email: address, password: secret) }
            else { try await connection.signIn(email: address, password: secret) }
          }
        })
    }
  }
  private func buildReady() {
    let field = FriendsUI.field(NaviPalette.text("Anzeigename", "Display name"), id: "friends.profile.name")
    field.autocapitalizationType = .words; nameField = field
    content.addArrangedSubview(field)
    content.addArrangedSubview(FriendsUI.button(NaviPalette.text("Namen speichern", "Save name"), id: "friends.profile.save") { [weak self, weak field] button in
      guard let self else { return }
      let name = field?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !name.isEmpty, name.utf16.count <= 40 else { self.show(FriendsInputError.name); return }
      self.view.endEditing(true); let connection = self.runtime
      self.run(on: button) { try await connection.setName(name) }
    })
    content.addArrangedSubview(FriendsUI.button(NaviPalette.text("Deinen Code kopieren", "Copy your code"), id: "friends.code.copy") { [weak self] _ in
      guard let self, let group = self.runtime.projectID, !self.runtime.snapshot.uid.isEmpty else { return }
      UIPasteboard.general.string = group + "/" + self.runtime.snapshot.uid
      self.message.text = NaviPalette.text("Code kopiert", "Code copied"); self.message.isHidden = false
    })
    let share = FriendsUI.button(NaviPalette.text("Standort teilen", "Share location"), id: "friends.sharing", primary: true) { [weak self] button in
      guard let self else { return }
      let connection = self.runtime
      let enable = ![FriendsSharingController.State.sharing, .enabling, .reconnecting].contains(connection.snapshot.sharingState)
      if enable { self.onRequestLocation?() }
      self.run(on: button) { try await connection.setSharing(enable) }
    }
    shareButton = share; content.addArrangedSubview(share); content.addArrangedSubview(stateLabel)
    content.addArrangedSubview(FriendsUI.button(NaviPalette.text("Freund hinzufügen", "Add friend"), id: "friends.add") { [weak self] _ in self?.addFriend() })
    content.addArrangedSubview(requestList)
    content.addArrangedSubview(NaviPalette.label(NaviPalette.text("Freunde", "Friends"), size: 21, weight: .semibold))
    content.addArrangedSubview(NaviPalette.label(NaviPalette.text("Bestätigt euch gegenseitig. Jede Freigabe entscheidest du separat.", "Confirm each other. You choose each permission separately."), size: 15))
    content.addArrangedSubview(friendList); content.addArrangedSubview(logoutButton())
  }
  private func logoutButton() -> UIButton {
    FriendsUI.button(NaviPalette.text("Abmelden", "Sign out"), id: "friends.logout") { [weak self] button in
      guard let self else { return }; let connection = self.runtime
      self.run(on: button) { _ = try await connection.signOut() }
    }
  }
  private func addFriend() {
    let connection = runtime
    let editor = FriendsTextEditor(title: NaviPalette.text("Freund hinzufügen", "Add friend"), multiline: false,
      inputID: "friends.add.code", saveID: "friends.add.send", placeholder: NaviPalette.text("Freundescode", "Friend code")) { text in
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == connection.projectID else { throw FriendsInputError.wrongGroup }
        try await connection.request(String(parts[1]))
      }
    present(UINavigationController(rootViewController: editor), animated: true)
  }
  private func updateRequests(_ values: [String]) {
    guard lastRequests != values else { return }; lastRequests = values; FriendsUI.clear(requestList)
    for uid in values {
      requestList.addArrangedSubview(NaviPalette.label(NaviPalette.text("Anfrage · ", "Request · ") + String(uid.suffix(8)), weight: .semibold))
      requestList.addArrangedSubview(FriendsUI.button(NaviPalette.text("Annehmen", "Accept"), id: "friends.request.\(uid).confirm") { [weak self] button in
        guard let self else { return }; let connection = self.runtime
        self.run(on: button) { try await connection.confirm(uid) }
      })
      requestList.addArrangedSubview(FriendsUI.button(NaviPalette.text("Ablehnen", "Decline"), id: "friends.request.\(uid).decline") { [weak self] button in
        guard let self else { return }; let connection = self.runtime
        self.run(on: button) { try await connection.remove(uid) }
      })
    }
    requestList.isHidden = values.isEmpty
  }
  private func changeGrant(_ uid: String, _ grant: FriendsRepository.Grant) {
    guard !busyPeers.contains(uid) else { return }; busyPeers.insert(uid); refresh()
    let connection = runtime
    Task { [weak self] in
      do { try await connection.grant(uid, grant: grant) } catch { self?.show(error) }
      self?.busyPeers.remove(uid); self?.refresh()
    }
  }
  private func remove(_ uid: String) {
    guard !busyPeers.contains(uid) else { return }; busyPeers.insert(uid); refresh()
    let connection = runtime
    Task { [weak self] in
      do { try await connection.remove(uid) } catch { self?.show(error) }
      self?.busyPeers.remove(uid); self?.refresh()
    }
  }
}

private final class FriendsTextEditor: UIViewController {
  private let multiline: Bool
  private let inputID: String, saveID: String, placeholder: String
  private let operation: (String) async throws -> Void
  private let field = UITextField(), text = UITextView(), message = NaviPalette.label(size: 15)
  init(title: String, multiline: Bool, inputID: String, saveID: String, placeholder: String,
       operation: @escaping (String) async throws -> Void) {
    self.multiline = multiline; self.inputID = inputID; self.saveID = saveID
    self.placeholder = placeholder; self.operation = operation
    super.init(nibName: nil, bundle: nil); self.title = title
  }
  required init?(coder: NSCoder) { fatalError("Use init(title:)") }
  override func viewDidLoad() {
    super.viewDidLoad(); FriendsUI.navigation(self)
    message.accessibilityIdentifier = "friends.editor.message"
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    let stack = FriendsUI.column(); _ = FriendsUI.layout(stack, in: view)
    if multiline {
      stack.addArrangedSubview(NaviPalette.label(NaviPalette.text("Füge die öffentliche Konfiguration eurer Gruppe ein. Keine Passwörter oder privaten Schlüssel.", "Paste your group's public configuration. No passwords or private keys."), size: 15))
      text.accessibilityIdentifier = inputID; text.accessibilityLabel = placeholder
      text.font = UIFont.preferredFont(forTextStyle: .body); text.adjustsFontForContentSizeCategory = true
      text.textColor = NaviPalette.ink; text.backgroundColor = NaviPalette.field; text.layer.cornerRadius = 16
      text.autocapitalizationType = .none; text.autocorrectionType = .no
      text.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true; stack.addArrangedSubview(text)
    } else {
      field.accessibilityIdentifier = inputID; field.accessibilityLabel = placeholder; field.placeholder = placeholder
      field.textColor = NaviPalette.ink; field.backgroundColor = NaviPalette.field; field.layer.cornerRadius = 16
      field.font = UIFont.preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
      field.autocapitalizationType = .none; field.autocorrectionType = .no
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true; stack.addArrangedSubview(field)
    }
    let operation = self.operation
    stack.addArrangedSubview(FriendsUI.button(NaviPalette.text("Speichern", "Save"), id: saveID, primary: true) { [weak self] button in
      guard let self else { return }
      let value = self.multiline ? self.text.text ?? "" : self.field.text ?? ""
      self.view.endEditing(true); button.isEnabled = false
      Task { [weak self, weak button] in
        do { try await operation(value); self?.dismiss(animated: true) }
        catch { self?.message.text = FriendsUI.error(error) }
        button?.isEnabled = true
      }
    })
    stack.addArrangedSubview(message)
  }
  @objc private func cancel() { view.endEditing(true); dismiss(animated: true) }
}

private final class FriendsPeerRow: UIStackView {
  private let uid: String
  private let name = NaviPalette.label(size: 20, weight: .semibold)
  private let detail = NaviPalette.label(size: 15), speed = NaviPalette.label(size: 21, weight: .semibold)
  private let position = UISwitch(), velocity = UISwitch(), trips = UISwitch()
  private let onGrant: (FriendsRepository.Grant) -> Void
  init(uid: String, onGrant: @escaping (FriendsRepository.Grant) -> Void, onRemove: @escaping () -> Void) {
    self.uid = uid; self.onGrant = onGrant
    super.init(frame: .zero)
    axis = .vertical; spacing = 12; isLayoutMarginsRelativeArrangement = true
    directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    backgroundColor = NaviPalette.field; layer.cornerRadius = 22
    name.accessibilityIdentifier = "friends.peer.\(uid).name"; speed.accessibilityIdentifier = "friends.peer.\(uid).speed"
    addArrangedSubview(name); addArrangedSubview(detail); addArrangedSubview(speed)
    addArrangedSubview(NaviPalette.label(NaviPalette.text("Du teilst mit diesem Freund", "You share with this friend"), size: 15))
    for (control, title, key) in [(position, NaviPalette.text("Standort", "Location"), "position"),
      (velocity, NaviPalette.text("Geschwindigkeit", "Speed"), "speed"), (trips, NaviPalette.text("Fahrten", "Trips"), "trips")] {
      let line = UIStackView(arrangedSubviews: [NaviPalette.label(title), control]); line.spacing = 12; line.alignment = .center
      control.accessibilityIdentifier = "friends.peer.\(uid).grant.\(key)"; control.accessibilityLabel = title
      control.onTintColor = NaviPalette.ink; control.setContentHuggingPriority(.required, for: .horizontal)
      control.addTarget(self, action: #selector(changed), for: .valueChanged); addArrangedSubview(line)
    }
    addArrangedSubview(FriendsUI.button(NaviPalette.text("Entfernen", "Remove"), id: "friends.peer.\(uid).remove") { _ in onRemove() })
  }
  required init(coder: NSCoder) { fatalError("Use init(uid:)") }
  @objc private func changed() {
    for control in [position, velocity, trips] { control.thumbTintColor = control.isOn ? NaviPalette.paper : nil }
    onGrant(.init(position: position.isOn, speed: velocity.isOn, trips: trips.isOn))
  }
  func update(_ peer: FriendsRepository.Peer, grant: FriendsRepository.Grant, now: Int64, busy: Bool) {
    name.text = peer.displayName.isEmpty ? NaviPalette.text("Freund · ", "Friend · ") + String(uid.suffix(6)) : peer.displayName
    if let point = peer.position, now >= point.measuredAtMs {
      let seconds = (now - point.measuredAtMs) / 1000
      detail.text = NaviPalette.text("Messung vor ", "Measured ") + "\(seconds) s · ±" + String(format: "%.0f m", point.accuracyMeters ?? 0)
    } else {
      detail.text = !peer.positionAllowed ? NaviPalette.text("Standort nicht freigegeben", "Location not shared")
        : peer.awaitingFreshSample ? NaviPalette.text("Warte auf eine neue Messung", "Waiting for a new measurement")
        : NaviPalette.text("Kein aktueller Standort", "No current location")
    }
    if let value = peer.speedMetersPerSecond(at: now), (value * 3.6).isFinite {
      speed.text = String(format: "%.0f km/h", value * 3.6)
    } else {
      speed.text = peer.speedAllowed ? NaviPalette.text("Keine aktuelle Geschwindigkeit", "No current speed")
                                    : NaviPalette.text("Geschwindigkeit nicht freigegeben", "Speed not shared")
    }
    for (control, enabled) in [(position, grant.position), (velocity, grant.speed), (trips, grant.trips)] {
      control.isEnabled = !busy
      if !busy { control.isOn = enabled }
      control.thumbTintColor = control.isOn ? NaviPalette.paper : nil
    }
  }
}
