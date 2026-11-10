import CoreApi
import CoreLocation
import UIKit

final class NaviTripsViewController: UITableViewController {
  private struct Trip {
    let id: String
    let passenger: Bool
    let startedAtMs: Int64
    let endedAtMs: Int64

    init?(_ value: [String: Any]) {
      guard let id = value["id"] as? String, let passenger = value["passenger"] as? Bool,
            let start = value["startedAtMs"] as? NSNumber, let end = value["endedAtMs"] as? NSNumber else { return nil }
      self.id = id
      self.passenger = passenger
      startedAtMs = start.int64Value
      endedAtMs = end.int64Value
    }

    var date: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
    var duration: TimeInterval { Double(endedAtMs - startedAtMs) / 1000 }
    var role: String { passenger ? NaviPalette.text("Mitfahrer", "Passenger") : NaviPalette.text("Fahrer", "Driver") }
  }

  private var trips: [Trip] = []
  private var pending: Trip?
  private var saving = false

  override func viewDidLoad() {
    super.viewDidLoad()
    title = NaviPalette.text("Meine Fahrten", "My trips")
    tableView.backgroundColor = NaviPalette.paper
    tableView.tintColor = NaviPalette.ink
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
    navigationItem.leftBarButtonItem?.accessibilityLabel = NaviPalette.text("Schließen", "Close")
    reloadTrips()
  }

  @objc private func close() { dismiss(animated: true) }

  private func reloadTrips() {
    let state = FrameworkHelper.naviTripState()
    trips = (state?["trips"] as? [[String: Any]] ?? []).compactMap(Trip.init)
    pending = (state?["pending"] as? [String: Any]).flatMap(Trip.init)
    let recording = pending?.endedAtMs == 0 && FrameworkHelper.isTrackRecordingEnabled()
    let buttonTitle = saving ? NaviPalette.text("Speichert …", "Saving…") :
      (recording ? NaviPalette.text("Stoppen", "Stop") :
        (pending == nil ? NaviPalette.text("Aufnehmen", "Record") : NaviPalette.text("Speichern", "Save")))
    let button = UIBarButtonItem(title: buttonTitle, style: .done, target: self, action: #selector(recordAction))
    button.isEnabled = !saving && state != nil
    button.accessibilityIdentifier = "navi-trips-record"
    navigationItem.rightBarButtonItem = button

    let label = UILabel()
    label.textAlignment = .center
    label.numberOfLines = 0
    label.font = .preferredFont(forTextStyle: .body)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = NaviPalette.ink
    if state == nil { label.text = NaviPalette.text("Fahrten konnten nicht geladen werden.", "Trips could not be loaded.") }
    else if trips.isEmpty {
      label.text = recording ? NaviPalette.text("Aufnahme läuft.", "Recording in progress.") :
        NaviPalette.text("Noch keine gespeicherten Fahrten.", "No saved trips yet.")
    }
    tableView.backgroundView = label.text == nil ? nil : label
    tableView.reloadData()
  }

  @objc private func recordAction() {
    guard !saving else { return }
    if pending != nil {
      saving = true
      reloadTrips()
      FrameworkHelper.stopNaviTrip(endedAtMs: nowMs) { [weak self] status in
        guard let self else { return }
        self.saving = false
        self.reloadTrips()
        if status == .empty { self.message(NaviPalette.text("Keine GPS-Punkte gespeichert.", "No GPS points recorded.")) }
        if status == .failed { self.message(NaviPalette.text("Speichern fehlgeschlagen. Du kannst es erneut versuchen.", "Could not save. You can try again.")) }
      }
      LocationManager.refreshBackgroundLocationPolicy()
      return
    }
    let authorization = CLLocationManager.authorizationStatus()
    guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else {
      LocationManager.checkLocationStatus()
      message(NaviPalette.text("Erlaube den Standortzugriff und tippe erneut auf Aufnehmen.", "Allow location access, then tap Record again."))
      return
    }
    let prompt = UIAlertController(title: NaviPalette.text("Fahrt aufnehmen", "Record a trip"),
      message: NaviPalette.text("Die Fahrt wird auf diesem Gerät gespeichert.", "The trip is saved on this device."), preferredStyle: .alert)
    prompt.addAction(UIAlertAction(title: NaviPalette.text("Fahrer", "Driver"), style: .default) { [weak self] _ in self?.start(passenger: false) })
    prompt.addAction(UIAlertAction(title: NaviPalette.text("Mitfahrer", "Passenger"), style: .default) { [weak self] _ in self?.start(passenger: true) })
    prompt.addAction(UIAlertAction(title: NaviPalette.text("Abbrechen", "Cancel"), style: .cancel))
    presentPrompt(prompt)
  }

  private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

  private func start(passenger: Bool) {
    guard FrameworkHelper.startNaviTrip(id: UUID().uuidString.lowercased(), passenger: passenger, startedAtMs: nowMs) else {
      message(NaviPalette.text("Aufnahme konnte nicht gestartet werden.", "Could not start recording."))
      return
    }
    LocationManager.start()
    LocationManager.refreshBackgroundLocationPolicy()
    reloadTrips()
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { trips.count }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let trip = trips[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "trip") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "trip")
    cell.backgroundColor = NaviPalette.paper
    cell.accessoryType = .disclosureIndicator
    cell.textLabel?.text = DateFormatter.localizedString(from: trip.date, dateStyle: .medium, timeStyle: .short)
    cell.textLabel?.textColor = NaviPalette.ink
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    let duration = formatter.string(from: trip.duration) ?? ""
    cell.detailTextLabel?.text = [trip.role, duration].filter { !$0.isEmpty }.joined(separator: " · ")
    cell.textLabel?.adjustsFontForContentSizeCategory = true
    cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let trip = trips[indexPath.row]
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let stats = FrameworkHelper.naviTripStatistics(id: trip.id)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.view.window != nil, self.presentedViewController == nil else { return }
        self.showDetails(trip, stats: stats)
      }
    }
  }

  private func showDetails(_ trip: Trip, stats: [String: Any]?) {
    guard let stats else {
      message(NaviPalette.text("Diese Fahrt konnte nicht gelesen werden.", "Could not read this trip."))
      return
    }
    let distance = (stats["distanceMeters"] as? Double ?? 0) / 1000
    let maximum = (stats["maximumSpeedMetersPerSecond"] as? Double).map { String(format: "%.0f km/h", $0 * 3.6) }
      ?? NaviPalette.text("unbekannt", "unknown")
    let gaps = stats["gapCount"] as? Int ?? 0
    let rejected = stats["rejectedCount"] as? Int ?? 0
    let raw = stats["rawCount"] as? Int ?? 0
    let distanceText = raw > rejected ? String(format: "%.1f km", distance) : NaviPalette.text("unbekannt", "unknown")
    let detail = NaviPalette.text("Erfasste Strecke \(distanceText)\nHöchsttempo \(maximum)\n\(gaps) GPS-Lücken · \(rejected) verworfene Punkte",
      "Recorded distance \(distanceText)\nTop speed \(maximum)\n\(gaps) GPS gaps · \(rejected) excluded points")
    let prompt = UIAlertController(title: trip.role, message: detail, preferredStyle: .alert)
    prompt.addAction(UIAlertAction(title: trip.passenger ? NaviPalette.text("Als Fahrer markieren", "Mark as driver") :
      NaviPalette.text("Als Mitfahrer markieren", "Mark as passenger"), style: .default) { [weak self] _ in
      if !FrameworkHelper.setNaviTripPassenger(!trip.passenger, id: trip.id) {
        self?.message(NaviPalette.text("Rolle konnte nicht geändert werden.", "Could not change the role."))
      }
      self?.reloadTrips()
    })
    prompt.addAction(UIAlertAction(title: NaviPalette.text("Löschen …", "Delete…"), style: .destructive) { [weak self] _ in self?.confirmDelete(trip) })
    prompt.addAction(UIAlertAction(title: NaviPalette.text("Schließen", "Close"), style: .cancel))
    presentPrompt(prompt)
  }

  private func confirmDelete(_ trip: Trip) {
    let title = NaviPalette.text("Diese Fahrt löschen?", "Delete this trip?")
    let prompt = UIAlertController(title: title, message: nil, preferredStyle: .alert)
    prompt.addAction(UIAlertAction(title: NaviPalette.text("Löschen", "Delete"), style: .destructive) { [weak self] _ in
      if !FrameworkHelper.deleteNaviTrip(id: trip.id) {
        self?.message(NaviPalette.text("Fahrt konnte nicht gelöscht werden.", "Could not delete the trip."))
      }
      self?.reloadTrips()
    })
    prompt.addAction(UIAlertAction(title: NaviPalette.text("Abbrechen", "Cancel"), style: .cancel))
    presentPrompt(prompt)
  }

  private func message(_ title: String) {
    let prompt = UIAlertController(title: title, message: nil, preferredStyle: .alert)
    prompt.addAction(UIAlertAction(title: "OK", style: .cancel))
    presentPrompt(prompt)
  }

  private func presentPrompt(_ prompt: UIAlertController) {
    prompt.view.tintColor = NaviPalette.ink
    present(prompt, animated: true)
  }
}
