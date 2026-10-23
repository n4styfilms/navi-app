import UIKit
import CoreLocation
import MapLibre

/// One visible map, fed by the app's existing location, search and routing services.
@objc(NaviViewController)
final class NaviViewController: MapViewController, MWMLocationObserver, MWMSearchObserver,
                                UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
  override var usesExternalMap: Bool { true }
  override var hasNavigationBar: Bool { false }
  private var map: NaviMapController!
  private var basemap: NaviBasemapMode = .street
  private var key = ""
  private var timer: Timer?
  private var attached = false
  private var restored = false
  private var searchWork: DispatchWorkItem?
  private var found: [SearchResult] = []
  private var destination = ""
  private var lastBuiltRevision: UInt64?
  private var lastErrorRevision: UInt64?
  private var profile: NaviVehicleProfile?
  private let searchField = UITextField()
  private let table = UITableView(frame: .zero, style: .plain)
  private let mapMessage = NaviPalette.button("") {}
  private let panelScroll = UIScrollView()
  private let panel = UIStackView()
  private let guidance = NaviPalette.label(size: 24, weight: .semibold)
  private let street = NaviPalette.label(size: 17, weight: .medium)
  private let lanes = NavigationLanesView(frame: .zero)
  private let metrics = NaviPalette.label(size: 25, weight: .semibold)
  private let arrival = NaviPalette.label(size: 15)
  private let fuel = NaviPalette.button("") {}
  private let speed = NaviPalette.label(size: 21, weight: .semibold)
  private let actions = UIStackView()
  private var modeButton: UIButton!
  private var goButton: UIButton!
  private var stopButton: UIButton!
  private var optionsButton: UIButton!

  init() { super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("Use init()") }
  override func loadView() { view = UIView(); view.backgroundColor = NaviPalette.paper }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.tintColor = NaviPalette.ink
    key = (try? NaviMapKeyStore.read()) ?? ""
    map = NaviMapController(frame: view.bounds, configuration: configuration())
    let canvas = map.view
    canvas.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(canvas)
    NSLayoutConstraint.activate([
      canvas.topAnchor.constraint(equalTo: view.topAnchor), canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])
    canvas.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:))))
    buildControls()
    map.onState = { [weak self] state in self?.showMapState(state) }
    map.onViewportChanged = { coordinate, zoom in
      guard zoom.isFinite, CLLocationCoordinate2DIsValid(coordinate) else { return }
      NaviRouteBridge.setSearchViewport(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                       zoom: Int(zoom.rounded()))
    }
    MWMRouter.subscribeToEvents()
    map.setFollowing(true)
    map.setBasemap(.street)
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: animated)
    guard !attached else { return }
    attached = true
    reloadProfile()
    Search.add(self)
    LocationManager.add(observer: self)
    LocationManager.start()
    if !restored { restored = true; MWMRouter.restoreRouteIfNeeded() }
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    refresh()
  }
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    detachUI()
    MWMRouter.saveRouteIfNeeded()
    UIApplication.shared.isIdleTimerDisabled = false
  }
  private func detachUI() {
    timer?.invalidate(); timer = nil
    searchWork?.cancel(); searchWork = nil
    if attached { Search.remove(self); LocationManager.remove(observer: self); attached = false }
  }
  deinit {
    timer?.invalidate()
    searchWork?.cancel()
    map?.close()
    MWMRouter.unsubscribeFromEvents()
  }
  override func onTerminate() { MWMRouter.saveRouteIfNeeded(); map?.close() }
  override var preferredStatusBarStyle: UIStatusBarStyle {
    traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard map != nil else { return }
    // Keep MapLibre's source attribution reachable above the navigation controls.
    map.view.attributionButtonPosition = .bottomLeft
    map.view.attributionButtonMargins = CGPoint(x: 104, y: view.bounds.height - panelScroll.frame.minY + 8)
    map.view.logoViewPosition = .bottomLeft
    map.view.logoViewMargins = CGPoint(x: 16, y: view.bounds.height - panelScroll.frame.minY + 8)
  }
  private func configuration() -> NaviEsriConfiguration {
    NaviEsriConfiguration(key: key, language: Locale.preferredLanguages.first ?? "en")
  }
  private func buildControls() {
    let top = UIStackView(); top.axis = .vertical; top.spacing = 10
    top.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(top)
    NSLayoutConstraint.activate([
      top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
      top.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      top.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
    ])
    let searchRow = UIStackView(); searchRow.spacing = 10
    let searchShell = UIView(); searchShell.backgroundColor = NaviPalette.paper
    searchShell.layer.cornerRadius = 28; searchShell.layer.cornerCurve = .continuous
    searchField.placeholder = NaviPalette.text("Wohin?", "Where to?")
    searchField.font = UIFont.preferredFont(forTextStyle: .body)
    searchField.adjustsFontForContentSizeCategory = true
    searchField.textColor = NaviPalette.ink; searchField.tintColor = NaviPalette.ink
    searchField.clearButtonMode = .whileEditing; searchField.returnKeyType = .search
    searchField.delegate = self; searchField.accessibilityIdentifier = "navi-search"
    searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchShell.addSubview(searchField)
    NSLayoutConstraint.activate([
      searchField.leadingAnchor.constraint(equalTo: searchShell.leadingAnchor, constant: 20),
      searchField.trailingAnchor.constraint(equalTo: searchShell.trailingAnchor, constant: -20),
      searchField.topAnchor.constraint(equalTo: searchShell.topAnchor, constant: 16),
      searchField.bottomAnchor.constraint(equalTo: searchShell.bottomAnchor, constant: -16),
      searchShell.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
    ])
    let profile = NaviPalette.button("") { [weak self] in self?.showSettings() }
    profile.setImage(UIImage(systemName: "person.crop.circle"), for: .normal)
    profile.accessibilityLabel = NaviPalette.text("Deine Einstellungen", "Your settings")
    profile.widthAnchor.constraint(equalToConstant: 56).isActive = true
    searchRow.addArrangedSubview(searchShell); searchRow.addArrangedSubview(profile)
    top.addArrangedSubview(searchRow)
    mapMessage.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      if self.map.state.snapshot.status == .configurationRequired || self.map.state.snapshot.status == .authError {
        self.showAccess()
      } else { self.map.retry() }
    }, for: .touchUpInside)
    mapMessage.titleLabel?.numberOfLines = 0
    top.addArrangedSubview(mapMessage)
    table.dataSource = self; table.delegate = self
    table.backgroundColor = NaviPalette.paper; table.layer.cornerRadius = 24
    table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 70
    table.keyboardDismissMode = .onDrag; table.isHidden = true
    table.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.3).isActive = true
    top.addArrangedSubview(table)

    panelScroll.translatesAutoresizingMaskIntoConstraints = false
    panelScroll.backgroundColor = NaviPalette.paper
    panelScroll.layer.cornerRadius = 28; panelScroll.layer.cornerCurve = .continuous
    panelScroll.showsVerticalScrollIndicator = true
    view.addSubview(panelScroll)
    panel.axis = .vertical; panel.spacing = 10; panel.translatesAutoresizingMaskIntoConstraints = false
    panelScroll.addSubview(panel)
    let contentHeight = panelScroll.heightAnchor.constraint(equalTo: panel.heightAnchor, constant: 32)
    contentHeight.priority = .defaultHigh
    NSLayoutConstraint.activate([
      panelScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      panelScroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      panelScroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10),
      panelScroll.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.58),
      contentHeight,
      panel.leadingAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.leadingAnchor, constant: 16),
      panel.trailingAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.trailingAnchor, constant: -16),
      panel.topAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.topAnchor, constant: 16),
      panel.bottomAnchor.constraint(equalTo: panelScroll.contentLayoutGuide.bottomAnchor, constant: -16),
      panel.widthAnchor.constraint(equalTo: panelScroll.frameLayoutGuide.widthAnchor, constant: -32)
    ])
    let dock = UIStackView(); dock.spacing = 8
    modeButton = NaviPalette.button(NaviPalette.text("Satellit", "Satellite")) { [weak self] in self?.switchMap() }
    dock.addArrangedSubview(modeButton)
    dock.addArrangedSubview(UIView())
    let position = NaviPalette.button("◎") { [weak self] in
      LocationManager.start(); self?.map.setFollowing(true)
    }
    position.accessibilityLabel = NaviPalette.text("Meinen Standort zentrieren", "Centre on my location")
    dock.addArrangedSubview(position); panel.addArrangedSubview(dock)
    panel.addArrangedSubview(speed)
    panel.addArrangedSubview(guidance); panel.addArrangedSubview(street)
    lanes.backgroundColor = UIColor(red: 0.16, green: 0.17, blue: 0.16, alpha: 1)
    lanes.layer.cornerRadius = 18
    lanes.heightAnchor.constraint(equalToConstant: 56).isActive = true
    panel.addArrangedSubview(lanes)
    panel.addArrangedSubview(metrics); panel.addArrangedSubview(arrival)
    fuel.addAction(UIAction { [weak self] _ in self?.showVehicle() }, for: .touchUpInside)
    fuel.titleLabel?.numberOfLines = 0; panel.addArrangedSubview(fuel)
    actions.axis = .vertical; actions.spacing = 8
    optionsButton = NaviPalette.button(NaviPalette.text("Routenoptionen", "Route preferences")) { [weak self] in self?.showOptions() }
    goButton = NaviPalette.button(NaviPalette.text("Losfahren", "Start navigation"), primary: true) { [weak self] in
      guard let self, self.freshLocation() != nil else { self?.locationNeeded(); return }
      MWMRouter.startRouting(); LocationManager.setMyPositionMode(.follow)
      LocationManager.refreshBackgroundLocationPolicy(); self.map.setFollowing(true); self.refresh()
    }
    stopButton = NaviPalette.button(NaviPalette.text("Route beenden", "End route")) { [weak self] in self?.stopRoute() }
    actions.addArrangedSubview(optionsButton); actions.addArrangedSubview(goButton); actions.addArrangedSubview(stopButton)
    panel.addArrangedSubview(actions)
  }
  private func showMapState(_ state: NaviMapLoadState.Snapshot) {
    mapMessage.isHidden = state.status == .ready || state.status == .detached
    let text: String
    switch state.status {
    case .loading: text = NaviPalette.text("Karte wird geladen …", "Loading map…")
    case .configurationRequired: text = NaviPalette.text("Satellitenzugang einrichten", "Set up satellite access")
    case .authError: text = NaviPalette.text("Satellitenschlüssel prüfen", "Check satellite key")
    case .quotaReached: text = NaviPalette.text("Kartenkontingent erreicht · später erneut versuchen", "Map allowance reached · retry later")
    case .networkError, .styleError: text = NaviPalette.text("Karte nicht erreichbar · erneut versuchen", "Map unavailable · tap to retry")
    default: text = ""
    }
    mapMessage.setTitle(text, for: .normal)
  }
  private func freshLocation() -> CLLocation? {
    guard let value = LocationManager.lastLocation(), value.horizontalAccuracy >= 0,
          abs(value.timestamp.timeIntervalSinceNow) <= 15,
          CLLocationCoordinate2DIsValid(value.coordinate), !LocationManager.isLocationProhibited() else { return nil }
    return value
  }
  private func refresh() {
    guard isViewLoaded, map != nil else { return }
    let snapshot = NaviRouteBridge.snapshot(withKnownGeometryRevision: map.geometryRevision)
    map.render(snapshot)
    let location = freshLocation()
    map.setLocation(location)
    let navigating = snapshot.state == .navigating
    let ready = navigating || snapshot.state == .preview
    UIApplication.shared.isIdleTimerDisabled = navigating && attached
    if navigating && MWMRouter.isRouteFinished() {
      stopRoute(); showMessage(NaviPalette.text("Du bist angekommen.", "You have arrived.")); return
    }
    if ready && lastBuiltRevision != snapshot.revision {
      lastBuiltRevision = snapshot.revision
      if !navigating { map.fitRoute() }
    }
    guidance.isHidden = !navigating; street.isHidden = !navigating
    lanes.setLanes(navigating ? NaviRouteBridge.lanes : [])
    guidance.text = Self.turnText(snapshot.nextTurn) + " · " + Self.distance(snapshot.distanceToTurnMeters?.doubleValue)
    street.text = snapshot.nextStreet.isEmpty ? snapshot.street : snapshot.nextStreet
    metrics.isHidden = snapshot.state == .none
    arrival.isHidden = !ready; fuel.isHidden = !ready
    actions.isHidden = snapshot.state == .none
    goButton.isHidden = snapshot.state != .preview
    optionsButton.isHidden = snapshot.state == .building
    stopButton.isHidden = snapshot.state == .none
    let distance = navigating ? snapshot.remainingDistanceMeters?.doubleValue : snapshot.totalDistanceMeters?.doubleValue
    let seconds = navigating ? snapshot.remainingTimeSeconds?.doubleValue : snapshot.totalTimeSeconds?.doubleValue
    if ready {
      metrics.text = Self.duration(seconds) + " · " + Self.distance(distance)
      if let seconds, seconds.isFinite, seconds >= 0 {
        arrival.text = NaviPalette.text("Ankunft ", "Arrive ") + Date(timeIntervalSinceNow: seconds).formatted(date: .omitted, time: .shortened)
      } else { arrival.text = nil }
      updateFuel(distance, remaining: navigating)
    } else {
      metrics.text = snapshot.state == .building ? NaviPalette.text("Route wird berechnet …", "Calculating route…")
        : NaviPalette.text("Keine Route · Offline-Karten und Optionen prüfen", "No route · check offline maps and preferences")
    }
    speed.isHidden = location == nil
    if let location {
      let speedText = location.speed >= 0 ? String(format: "%.0f km/h", location.speed * 3.6) : "— km/h"
      if navigating, let limit = snapshot.speedLimitKmh?.doubleValue, limit.isFinite, limit > 0 {
        speed.text = speedText + "   ·   " + NaviPalette.text("Limit ", "Limit ") + String(format: "%.0f", limit)
      } else { speed.text = speedText }
    }
    if snapshot.state == .failed && lastErrorRevision != snapshot.revision {
      lastErrorRevision = snapshot.revision
      // Keep the error inline; settings provide the existing map downloader.
      arrival.isHidden = false
      arrival.text = NaviPalette.text("Offline-Karten findest du in deinen Einstellungen.", "Find offline maps in your settings.")
    }
  }
  private func updateFuel(_ distance: Double?, remaining: Bool) {
    guard let distance else { fuel.setTitle("—", for: .normal); return }
    let estimate = NaviFuelCalculator.estimate(distanceMeters: distance, profile: profile)
    guard estimate.status == .ready, let euros = estimate.euros, let liters = estimate.liters else {
      fuel.setTitle(NaviPalette.text("Fahrzeug für Spritkosten einrichten", "Set vehicle for fuel estimate"), for: .normal); return
    }
    let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = "EUR"
    let amount = formatter.string(from: NSNumber(value: euros)) ?? "—"
    let source = estimate.source == .personal ? NaviPalette.text("eigener Verbrauch", "own average") : "WLTP"
    let label = remaining ? NaviPalette.text("Sprit verbleibend: ca. ", "Fuel remaining: approx. ")
      : NaviPalette.text("Sprit gesamt: ca. ", "Total fuel: approx. ")
    fuel.setTitle(label + amount + " · " + String(format: "%.2f l", liters) + " · " + source, for: .normal)
  }
  private func stopRoute() {
    MWMRouter.stopRouting(); LocationManager.refreshBackgroundLocationPolicy()
    map.setFollowing(false); map.setTarget(nil); destination = ""; refresh()
  }
  private func choose(_ coordinate: CLLocationCoordinate2D, title: String) {
    guard freshLocation() != nil else { locationNeeded(); return }
    searchWork?.cancel(); Search.clear(); found = []; table.reloadData(); table.isHidden = true
    searchField.resignFirstResponder(); searchField.text = title; destination = title
    if NaviRouteBridge.buildRoute(toLatitude: coordinate.latitude, longitude: coordinate.longitude, title: title) {
      map.setTarget(coordinate); lastBuiltRevision = nil; refresh()
    }
  }
  @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }
    let coordinate = map.view.convert(gesture.location(in: map.view), toCoordinateFrom: map.view)
    choose(coordinate, title: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
  }
  override func searchNaviText(_ text: String) {
    loadViewIfNeeded(); searchField.text = text; queryChanged()
  }
  @objc private func queryChanged() {
    searchWork?.cancel(); Search.clear(); found = []; table.reloadData()
    let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    table.isHidden = query.isEmpty
    guard !query.isEmpty else { return }
    let work = DispatchWorkItem { Search.searchQuery(SearchQuery(query, source: .typedText)) }
    searchWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool { queryChanged(); textField.resignFirstResponder(); return true }
  func onSearchResultsUpdated() {
    guard attached, !table.isHidden else { return }
    found = Search.getResults(); table.reloadData()
  }
  func onSearchCompleted() { onSearchResultsUpdated() }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { found.count }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "result") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "result")
    let result = found[indexPath.row]
    cell.backgroundColor = NaviPalette.paper
    cell.textLabel?.text = result.titleText; cell.textLabel?.textColor = NaviPalette.ink; cell.textLabel?.numberOfLines = 0
    cell.detailTextLabel?.text = result.addressText; cell.detailTextLabel?.numberOfLines = 0
    cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
    cell.detailTextLabel?.font = UIFont.preferredFont(forTextStyle: .caption1)
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let result = found[indexPath.row]
    if result.isPureSuggest || result.itemType == .suggestion {
      searchField.text = result.suggestion; queryChanged()
    } else { choose(result.coordinate, title: result.titleText) }
  }
  func onLocationUpdate(_ location: CLLocation) { refresh() }
  func onLocationError(_ locationError: MWMLocationStatus) { refresh() }
  private func locationNeeded() {
    LocationManager.start()
    showMessage(NaviPalette.text("Für den Routenstart wird dein aktueller Standort benötigt. Prüfe die Standortfreigabe.", "A current location is needed to start a route. Check location access."))
  }
  private func switchMap() {
    if basemap == .street && !configuration().isConfigured { showAccess(); return }
    basemap = basemap == .street ? .satellite : .street
    modeButton.setTitle(basemap == .street ? NaviPalette.text("Satellit", "Satellite") : NaviPalette.text("Straße", "Street"), for: .normal)
    map.setBasemap(basemap)
  }
  private func showVehicle() {
    do {
      let editor = NaviVehicleViewController(store: try NaviVehicleStore.local())
      editor.onChange = { [weak self] in self?.reloadProfile(); self?.refresh() }
      let navigation = UINavigationController(rootViewController: editor)
      navigation.view.tintColor = NaviPalette.ink
      present(navigation, animated: true)
    } catch { showMessage(NaviPalette.text("Fahrzeugdaten konnten nicht geöffnet werden.", "Vehicle data could not be opened.")) }
  }
  private func reloadProfile() { profile = (try? NaviVehicleStore.local().load())?.profile }
  private func showSettings() {
    let sheet = UIAlertController(title: NaviPalette.text("Deine Einstellungen", "Your settings"), message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: NaviPalette.text("Mein Fahrzeug", "My vehicle"), style: .default) { [weak self] _ in self?.showVehicle() })
    sheet.addAction(UIAlertAction(title: NaviPalette.text("Offline-Karten", "Offline maps"), style: .default) { [weak self] _ in self?.openMapsDownloader(.downloaded) })
    sheet.addAction(UIAlertAction(title: NaviPalette.text("Satellitenzugang", "Satellite access"), style: .default) { [weak self] _ in self?.showAccess() })
    sheet.addAction(UIAlertAction(title: NaviPalette.text("Schließen", "Close"), style: .cancel))
    presentSheet(sheet)
  }
  private func showAccess() {
    let alert = UIAlertController(title: NaviPalette.text("Satellitenzugang", "Satellite access"),
      message: NaviPalette.text("Die Straßenkarte funktioniert ohne Konto. Für Satellit kannst du später deinen eigenen Esri-Schlüssel eintragen.", "Street maps work without an account. Add your own Esri key later for satellite imagery."), preferredStyle: .alert)
    alert.addTextField { field in field.isSecureTextEntry = true; field.autocorrectionType = .no; field.autocapitalizationType = .none; field.placeholder = "Esri API key" }
    alert.addAction(UIAlertAction(title: NaviPalette.text("Abbrechen", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: NaviPalette.text("Speichern", "Save"), style: .default) { [weak self, weak alert] _ in
      guard let self else { return }
      let candidate = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard candidate.isEmpty || NaviEsriConfiguration(key: candidate, language: "en").isConfigured else {
        self.showMessage(NaviPalette.text("Schlüssel prüfen.", "Check the key.")); return
      }
      do {
        try NaviMapKeyStore.save(candidate); self.key = candidate
        if candidate.isEmpty { self.basemap = .street; self.map.setBasemap(.street) }
        self.map.setConfiguration(self.configuration())
      } catch { self.showMessage(NaviPalette.text("Zugang konnte nicht gespeichert werden.", "Access could not be saved.")) }
    })
    present(alert, animated: true)
  }
  private func showOptions() {
    let options = RoutingOptions()
    let sheet = UIAlertController(title: NaviPalette.text("Vermeiden", "Avoid"), message: nil, preferredStyle: .actionSheet)
    let items: [(String, ReferenceWritableKeyPath<RoutingOptions, Bool>)] = [
      (NaviPalette.text("Maut", "Tolls"), \.avoidToll), (NaviPalette.text("Autobahnen", "Motorways"), \.avoidMotorway),
      (NaviPalette.text("Fähren", "Ferries"), \.avoidFerry), (NaviPalette.text("Unbefestigte Straßen", "Unpaved roads"), \.avoidDirty)]
    for (title, path) in items {
      sheet.addAction(UIAlertAction(title: (options[keyPath: path] ? "✓ " : "") + title, style: .default) { [weak self] _ in
        options[keyPath: path].toggle(); options.save()
        MWMRouter.rebuild(withBestRouter: false); self?.refresh()
      })
    }
    sheet.addAction(UIAlertAction(title: NaviPalette.text("Schließen", "Close"), style: .cancel)); presentSheet(sheet)
  }
  private func presentSheet(_ sheet: UIAlertController) {
    sheet.view.tintColor = NaviPalette.ink
    sheet.popoverPresentationController?.sourceView = panelScroll
    sheet.popoverPresentationController?.sourceRect = panelScroll.bounds
    present(sheet, animated: true)
  }
  private func showMessage(_ message: String) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: "Navi", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default)); alert.view.tintColor = NaviPalette.ink
    present(alert, animated: true)
  }
  private static func distance(_ meters: Double?) -> String {
    guard let meters, meters.isFinite, meters >= 0 else { return "—" }
    return meters < 1000 ? String(format: "%.0f m", meters) : String(format: "%.1f km", meters / 1000)
  }
  private static func duration(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
    let minutes = Int(ceil(seconds / 60))
    return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
  }
  private static func turnText(_ turn: Int) -> String {
    switch turn {
    case 2, 3, 4, 16: return NaviPalette.text("Rechts abbiegen", "Turn right")
    case 5, 6, 7, 15: return NaviPalette.text("Links abbiegen", "Turn left")
    case 8, 9: return NaviPalette.text("Wenden", "Make a U-turn")
    case 10, 11, 12: return NaviPalette.text("Kreisverkehr", "Roundabout")
    case 14: return NaviPalette.text("Ziel erreicht", "Destination")
    case 1: return NaviPalette.text("Geradeaus", "Continue straight")
    case 13: return NaviPalette.text("Der Route folgen", "Follow the route")
    default: return NaviPalette.text("Der Route folgen", "Follow the route")
    }
  }
}
