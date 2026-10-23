# Kartenwechsel und Spritkosten Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Neue native Straßen-/Satellitenkarte auf Android und iOS mit erhaltener Navigation, bestätigtem UI und fahrzeugbezogener Spritkostenschätzung als neue geprüfte APK/IPA ausliefern.

**Architecture:** MapLibre Native übernimmt die sichtbare Karte, Esri die authentifizierten Basemap-Daten. Der bestehende C++-Router liefert kopierte Snapshots über JNI beziehungsweise Objective-C++; Drape wird nicht als unsichtbare zweite Karte betrieben. Fahrzeugdaten bleiben lokal.

**Tech Stack:** C++ im bestehenden CoMaps-Fork; Android Java/Kotlin, MapLibre Android OpenGL 13.7.1; iOS Swift/Objective-C++, MapLibre Swift Package 6.31.0; bestehende Gradle-/Xcode-/GitHub-Builds. Diese stabilen SDK-Releases wurden am 18.10.2026 anhand der offiziellen Release-Seiten geprüft; Versionen exakt pinnen, keine Vorabversion oder dynamische Versionsspanne.

**Spec:** `docs/superpowers/specs/2026-10-18-kartenwechsel-design.md`, vom Nutzer mit „Passt“ freigegeben. **Ausführungsplan und Umsetzung in dieser Sitzung am 18.10.2026 ausdrücklich freigegeben: „Plan freigeben und hier umsetzen“.** Ausführung durch denselben Agenten, ohne Implementierungs-Subagenten pro Aufgabe.

## Global Constraints

- „ausschließlich mit kostenlosen Werkzeugen und kostenlosen Dienstkontingenten“; kein PAYG, keine Zahlungsmethode und kein Cloud-Billing aktivieren.
- „Android wird als APK, iOS als Geräte-IPA für einen kostenlosen Sideloader ausgeliefert“; keine neue Apple-Mitgliedschaft, kein eigener Mac vorausgesetzt.
- „Es werden nicht dauerhaft zwei Karten übereinander gerendert. Ein unsichtbarer zweiter Renderer ist kein akzeptierter Dauerbetrieb.“
- „UI/Karte erhalten keine veränderlichen Router-Referenzen.“
- „Kameraänderungen berechnen keine neue Route.“
- „Ein Standortstrom versorgt Router, sichtbare Position und Aufzeichnung“.
- „Rundung erst zur Anzeige“; keine erfundenen Fahrweise-Multiplikatoren oder geratenen Tempolimits.
- Bisherige Pakete unter `outputs/builds/Basis-01` unverändert aufbewahren. Ein Paketbuild ersetzt keinen Geräte- oder Fahrnachweis.
- Freundesfreigaben, Fahrtverläufe und kalibrierte Ereignisse bleiben Gesamtziel und nachfolgende Etappen. Dieser Plan liefert Karten-/Kostenetappe, nicht die gesamte App. Die leere Karte bekommt keine erfundenen Freunde.

## Review Focus

1. Routenabbruch oder neue Route während eines alten asynchronen Ergebnisses: alte Geometrie und Kosten dürfen nicht wieder erscheinen (Aufgabe 1/2).
2. Stilwechsel während einer laufenden Route und vor Kartenbereitschaft: Kamera und Overlays nach erfolgreichem Laden genau einmal wiederherstellen (Aufgabe 3/4).
3. Kein Netz, abgelaufener Schlüssel, Kontingent erschöpft: kein endloser Wiederholungszyklus, keine Schlüssel in Meldungen; laufende Navigation erhalten (Aufgabe 3/4).
4. Deutsche Dezimalwerte, leeres optionales Verbrauchsfeld, extrem große oder nicht endliche Zahlen: niemals falsche Geldzahl oder stilles Speichern ungültiger Werte (Aufgabe 5).
5. Standortberechtigung entzogen, App im Hintergrund und Rückkehr: kein zweiter GPS-Dienst, keine alte Geschwindigkeit als aktuelle Messung (Aufgabe 2/6).

## Reihenfolge und Nachweise

Aufgabe 1 und ihr realer Routendatentest sind Voraussetzung für den Kartenumbau. Aufgabe 2 verbindet die Brücken. Aufgaben 3/4 bilden dieselbe Kartenlogik auf beiden Plattformen ab. Aufgabe 5 nutzt die numerische Distanz aus 1/2. Aufgabe 6 verbindet das bestätigte Design; Aufgabe 7 liefert die tatsächlich gebauten Pakete. Für jede fachliche Änderung zunächst einen fehlschlagenden Verhaltenstest ausführen, danach implementieren und die betroffene Suite ausführen. Logs und Entscheidungen unter `work/kartenwechsel/progress.md` aufbewahren, nicht mit dem Ledger von Bauplan 01 vermischen.

## Aufgabe 1: Navigation von Darstellung trennen und Snapshot liefern

**Files:** Neu `libs/map/navi_route_snapshot.hpp`, `libs/map/navi_route_snapshot.cpp`, `libs/map/map_tests/navi_route_snapshot_tests.cpp`, `libs/map/map_tests/navi_headless_routing_tests.cpp`, `tools/private/test-native.sh`; ändern `libs/map/routing_manager.hpp`, `.cpp`, `libs/map/CMakeLists.txt`, `libs/map/map_tests/CMakeLists.txt`.

**Interfaces:** `navi::RouteSnapshot RoutingManager::GetRouteSnapshot() const` liefert eine Kopie auf dem GUI-Thread. Snapshot: `uint64_t revision`, `RouteState state` (None/Building/Preview/Navigating/Failed), Geometrie als `vector<LatLon>`, optionale Gesamt-/Restdistanz in Metern und Gesamt-/Restdauer in Sekunden, nächstes Manöver, Straße, optionales Tempolimit in km/h und fachliche Straßenwarnungen. `LatLon` besitzt benannte `latitude`/`longitude`-Doubles. Fehlende Route hat keine Distanz. Geometrie wird nur bei neuer Revision neu an die Plattform übertragen; Folgepositionen aktualisieren Fortschritt.

- [ ] Verhaltenstests schreiben: keine Route ist keine Null-Meter-Route; gespeicherter Snapshot ändert sich nicht nach Kernänderung; Meter bleiben ungerundet; Koordinaten korrekt aus Mercator umrechnen; Abbruch invalidiert Revision und Geometrie; spätes Ergebnis einer alten Routen-ID wird verworfen. Tests ausführen und erwartetes Fehlschlagen protokollieren.
- [ ] `InsertRoute` aufteilen: fachliche Sammlung von Straßenwarnungen/Ampeln vor beziehungsweise unabhängig von der Drape-Abfrage durchführen; Grafikobjekte nur mit vorhandenem Renderer anlegen. Identische Segmente mit/ohne Renderer müssen identische fachliche Warnungen liefern. Bestehende Drape-Darstellung bis zur Umschaltung unverändert prüfen.
- [ ] Snapshot auf dem bestehenden GUI-/Router-Lebenszyklus erzeugen; Routen-ID und Revision bei Build/Neuberechnung/Abbruch berücksichtigen. Keine Verwendung von `GetRouteForTests()` als neue öffentlich veränderliche Plattform-API. Interne Route beim Kopieren gegen vorhandene Threadverträge prüfen.
- [ ] `tools/private/test-native.sh BUILD_DIR DATA_DIR` erstellt mit dem bestehenden CMake-Projekt `map_tests` und `routing_tests`, führt beide mit `--data_path`/`--user_resource_path` aus und propagiert jeden Fehler. Kein stiller Erfolg bei null passenden Tests. Linux-Abhängigkeiten aus `docs/INSTALL.md` verwenden; kein kostenpflichtiger Runner.
- [ ] Reale Monaco-Routendaten über den bestehenden offiziellen Kartendownload beziehen, Datenversion und SHA-256 protokollieren. Im rendererlosen Test Autoroute von (43.7295, 7.4208) nach (43.7450, 7.4270) berechnen, gültige Geometrie/Distanz prüfen, eine Positionsfolge auf der berechneten Route wiedergeben, Abweichung und Neuberechnung sowie Abbruch prüfen. Manöver/Ansagen gegen den tatsächlich berechneten Verlauf abgleichen; keine erwartete Kartenlänge ohne Datenbeleg festschreiben. Synthetische Warnsegmente ergänzen den realen Routenfall, ersetzen ihn nicht.
- [ ] Ausführen: `bash tools/private/test-native.sh "$RUNNER_TEMP/navi-native" "$RUNNER_TEMP/navi-map-data"`. Erwartet: beide Testprogramme erfolgreich, neue Tests tatsächlich ausgeführt, rendererloser Routennachweis vorhanden. Erst dann Kartenumbau beginnen. Änderungen gezielt committen.

## Aufgabe 2: Android-/iOS-Brücken und Lebenszyklus

**Files:** Neu `android/sdk/src/main/java/app/organicmaps/sdk/routing/NaviRouteSnapshot.java`, `android/sdk/src/main/cpp/app/organicmaps/sdk/routing/NaviRouteSnapshot.hpp`, `.cpp`, `iphone/Maps/Model/Navigation/NaviRouteBridge.h`, `.mm`; ändern `android/sdk/src/main/java/app/organicmaps/sdk/Framework.java`, `android/sdk/src/main/cpp/app/organicmaps/sdk/Framework.cpp` und vorhandene CMake-/Xcode-Dateilisten.

**Interfaces:** Android `Framework.nativeGetNaviRouteSnapshot()` liefert `NaviRouteSnapshot`; iOS `NaviRouteBridge.snapshot` liefert ein unveränderliches Objective-C-DTO mit denselben benannten Einheiten und Nullable-Feldern. Beide rufen Aufgabe 1 ausschließlich auf dem vorgesehenen GUI-Thread ab. Darstellung vergleicht `revision`; Abbruch löscht Overlays und Kosten.

- [ ] Tests für vollständige Feldübertragung, Lat/Lon-Reihenfolge, fehlendes Tempolimit, fehlende Route, alte Revision nach Abbruch und doppelte Start-/Stop-Aufrufe schreiben und fehlschlagen sehen. Keine Tests, die nur eine kopierte JNI-Signatur als Text suchen.
- [ ] DTOs, JNI-Konstruktion und Objective-C++-Abbildung implementieren. Standortquelle und bestehende TTS-/Routingdienste erhalten. Renderer-Lebenszyklus von der Router-Initialisierung trennen, keinen zusätzlichen Standortanbieter starten.
- [ ] Android-Brücke mit ARM64-Gerätebuild, iOS-Brücke mit Gerätebuild kompilieren. Instrumentierte Android-/iOS-Tests müssen Snapshot-Verhalten aus dem tatsächlichen Kern prüfen; reine DTO-Unit-Tests als solche kennzeichnen.
- [ ] Berechtigungsentzug, Hintergrund/Rückkehr und Routenabbruch mit Positionswiedergabe prüfen; Logs zeigen einen Standortstrom. Änderungen committen. Fehlende physische Geräte bleiben als offener Nachweis geführt.

## Aufgabe 3: Android-Straßen-/Satellitenkarte

**Files:** Neu unter `android/app/src/main/java/app/organicmaps/navi/map/`: `NaviMapController.java`, `BasemapMode.java`, `EsriMapConfiguration.java`, `MapLoadState.java`; passende Verhaltenstests unter `android/app/src/test/java/app/organicmaps/navi/map/`. Ändern `android/app/build.gradle.kts`, `android/gradle/libs.versions.toml`, `android/app/src/main/java/app/organicmaps/MwmActivity.java`, `android/app/src/main/res/layout/activity_map.xml` sowie die bisherigen Renderer-/Kameraaufrufe in `android/sdk/src/main/java/app/organicmaps/sdk/Map.java` und `MapView.java`.

**Interfaces:** `NaviMapController.setBasemap(BasemapMode)`, `render(NaviRouteSnapshot)`, `setLocation(Location)`, `retry()`; Modus STREET/SATELLITE. `EsriMapConfiguration` hält lokal den Kartenschlüssel und liefert nur dokumentierte HTTPS-Style-URLs. Kein Standardschlüssel. Abfragezähler erfassen Anfragen ohne Token/URL-Inhalte.

- [ ] Stabile MapLibre-OpenGL-Abhängigkeit exakt auf `org.maplibre.gl:android-sdk-opengl:13.7.1` pinnen; Lizenzhinweise übernehmen. Vorher Artefakt/ABI-Verfügbarkeit prüfen. Keine Installation vor Planfreigabe.
- [ ] Fehlschlagende Verhaltenstests für Moduswechsel mit erhaltener Kamera/Route/Ziel, Stilantworten in falscher Reihenfolge, fehlende Konfiguration, 401/403/429/Netzfehler und expliziten Retry schreiben. Ein neuer Modus invalidiert ältere Ladevorgänge. Fehlertext darf einen vorgegebenen Testschlüssel nie enthalten.
- [ ] Kartencontroller und Esri-Zugriff über die offiziellen Basemap-Style-Endpunkte implementieren; authentifizierte Unteranfragen und native Style-Kompatibilität prüfen. Attribution anhand geladener Metadaten anzeigen. STREET nutzt die farbige Navigationskarte, SATELLITE das Imagery-/Hybrid-Angebot mit Beschriftung. Keine undokumentierten anonymen Tile-URLs.
- [ ] MapLibre als einzige sichtbare Karte einbinden; Drape-Surface nicht erstellen. Vorhandene Suche, Downloadanzeige, Zielauswahl und Routenschritte mit Karte/Controller verbinden. Route als Graphitlinie mit hellem Rand, Position aus vorhandener Standortquelle.
- [ ] `android/gradlew :app:testWebBetaUnitTest -Parm64` ausführen; danach echten Android-Start und Stilwechsel mit gültigem eigenem Schlüssel prüfen. Ohne Schlüssel kann der Einrichtungspfad fertig sein, die echte Kartendarstellung bleibt unbestätigt. Änderungen committen.

## Aufgabe 4: iOS-Straßen-/Satellitenkarte

**Files:** Neu `iphone/Maps/UI/NaviMap/NaviMapController.swift`, `EsriMapConfiguration.swift`, `MapLoadState.swift`, `NaviMapControllerTests.swift` unter `iphone/Maps/Tests/UI/NaviMap/`; ändern `iphone/Maps/Classes/MapViewController.mm`, `iphone/Maps/UI/Map/MapView.swift`, `iphone/Maps/Maps.xcodeproj/project.pbxproj` und Package-Resolution.

**Interfaces:** Swift `setBasemap(_ mode: BasemapMode)`, `render(_ snapshot: NaviRouteSnapshot)`, `setLocation(_ location: CLLocation)`, `retry()`. Zustände, Einheiten und Revisionen entsprechen Aufgabe 3; Plattformtypen werden nicht über C++ exportiert.

- [ ] MapLibre über `https://github.com/maplibre/maplibre-gl-native-distribution` exakt auf 6.31.0 pinnen; Package-Resolution und Prüfsumme des XCFrameworks festhalten. Bestehendes iOS-Minimum 15.6 erhalten und Geräte-ARM64-Slice prüfen.
- [ ] Dieselben Verhaltenstests wie Android zuerst fehlschlagen sehen, zusätzlich View-Detach während eines Stil-Ladevorgangs und anschließenden Wiederaufbau prüfen.
- [ ] Controller, Konfiguration und MapLibre-View mit der vorhandenen Navigation verbinden. Drape nicht unsichtbar weiterlaufen lassen; Zielauswahl, Suche und Kartendownload bleiben erreichbar. Einen CLLocation-Strom beibehalten.
- [ ] Auf kostenlosem Standard-macOS-Runner die Tests im Scheme `CoMaps` mit verfügbarem iPhone-Simulator ausführen; konkreten Destination-Identifier aus `xcrun simctl list devices available` wählen und protokollieren, nicht raten. Anschließend Gerätebuild durch bestehendes privates Buildskript prüfen. Echte Esri-Bilder nur mit eigenem gültigem Schlüssel abnehmen.
- [ ] Attribution, Moduswechsel, Hintergrund/Rückkehr und Speicherfreigabe prüfen; Änderungen committen.

## Aufgabe 5: Lokales Fahrzeug und Spritkosten

**Files:** Neu `testing/private/fuel-cases.json`; Android `android/app/src/main/java/app/organicmaps/fuel/` mit `VehicleProfile.java`, `FuelEstimate.java`, `FuelCalculator.java`, `VehicleStore.java` und Formular; Swift entsprechende Typen unter `iphone/Maps/Model/Fuel/` sowie Formular unter `iphone/Maps/UI/Vehicle/`. Tests in den vorhandenen Android-/iOS-Testverzeichnissen ergänzen.

**Interfaces:** Android `FuelCalculator.estimate(double distanceMeters, VehicleProfile profile)` und Swift `FuelCalculator.estimate(distanceMeters: Double, profile: VehicleProfile)` liefern validiertes Ergebnis oder benannten Ergänzungsbedarf. Ergebnisse enthalten Liter, ungerundete Euro und Verbrauchsquelle WLTP/PERSONAL. Profile speichern lokal mit Schema-Version; keine Cloud und keine Fahrzeugdatenbank.

- [ ] Gemeinsame fachliche Fälle anlegen: 120000 m/6/1,80 ergibt 7,2 l und 12,96 €; persönlicher Verbrauch hat Vorrang; 0 m; kleine ungerundete Distanz; leeres optionales Feld; deutsche Kommaeingabe; NaN/Infinity/negative Werte; ungültiger Kraftstoff; Überlauf bei großer Distanz; Speichern/Neustart/Löschen. Tests vor Implementierung ausführen.
- [ ] Parser, Validierung, Rechner und Speicherung implementieren. Verbrauch positiv; Preis endlich und nicht negativ; Ergebnis ebenfalls endlich. Unvollständige Eingaben nicht speichern. Leerer persönlicher Verbrauch setzt Quelle wieder auf WLTP.
- [ ] Formular von Profil/Einstellungen erreichbar machen; Felder für Marke, Modell, Motor, Baujahr, Benzin/Diesel, WLTP und Literpreis. Abbrechen verändert keine gespeicherten Werte.
- [ ] Vorschau nur für fertige Autoroute an numerische Gesamtdistanz aus Aufgabe 2 binden: „ca. … € Sprit“. Details nennen Quelle und Literpreis. Bei Profiländerung/Neuberechnung aktualisieren, bei Abbruch ausblenden; bei Navigation ausdrücklich verbleibende Kosten aus Restdistanz. Einheitenwechsel Kilometer/Meilen ändert Kosten nicht.
- [ ] Beide Plattform-Suites ausführen und Profil-Neustart/Routenwechsel im laufenden UI prüfen. Änderungen committen.

## Aufgabe 6: Bestätigtes UI und echte Funktionsprüfung

**Files:** Android `res/values`, `res/values-night`, Karten-/Routen-/Navigationslayouts und Controller aus Bauplan 02; iOS `iphone/Maps/Core/Theme`, `Classes/CustomViews/MapViewControls/`, `Classes/CustomViews/NavigationDashboard/` und neue `UI/NaviMap/`-Ansicht.

- [ ] Fassung 03 als unveränderte visuelle Referenz heranziehen. 12ui-Skill anwenden, aber keine kostenpflichtigen Generierungs-/Hostingdienste aufrufen: die ausdrückliche 0-€-Vorgabe hat Vorrang. Bestehende Referenz direkt in nativen Komponenten umsetzen.
- [ ] UI zentral gestalten: Graphit `#292C28`, Elfenbein `#FAF9F5`, Blatt-Radius 34–36 logische Pixel, runde Such-/Hauptaktionen, mindestens 48 × 48 Bedienflächen. Systemschrift und Safe Areas erhalten; Karte farbig belassen.
- [ ] Drei Ansichten vervollständigen: freie Karte mit „Wohin?“, Profil, Positionsknopf und Moduswahl; Vorschau mit Zeit/Distanz/Ankunft/Kosten/Optionen und „Losfahren“; Navigation mit Manöver/Straße, Restwerten, Geschwindigkeit und bekanntem Tempolimit. Keine dauerhafte zusätzliche Tab-Leiste.
- [ ] Verhalten testen: Routenstart erst nach fertiger Route; unbekanntes Limit und fehlende Geschwindigkeit zeigen keine geratene Zahl; Berechtigungsentzug, Standortalter, Suchabbruch, fehlende Offline-Daten und erneute Berechnung korrekt anzeigen. Vorhandene Ansagen/Spurhinweise/Abbruch erhalten.
- [ ] Laufende Android-/iOS-Ansichten in Hell/Dunkel, kleinem Display, Querformat, großer Schrift und mit Tastatur prüfen. Screenshots der tatsächlichen App gegen Referenz vergleichen. Satellit/Hybrid an Berlin, San Francisco und Tokio authentifiziert prüfen; Bildqualität nicht weltweit gleichsetzen.
- [ ] Fehlenden Esri-Zugang beziehungsweise fehlende Geräte als konkrete offene Nachweise melden; Kontoanmeldung/Passwort/Einwilligungen nicht erfinden. Fehlende Zugänge verhindern keine unabhängige lokale Implementierung, aber die Kartenetappe bleibt bis zur tatsächlichen Abnahme offen. Änderungen committen.

## Aufgabe 7: Neue APK/IPA, Review und Auslieferung

**Files:** Bestehende `tools/private/build-android.sh`, `build-ios.sh`, `verify_artifacts.py`, `create_manifest.py`, `.github/workflows/private-android.yml`, `private-ios.yml`; ergänzen `docs/private-map-status.md` und `outputs/Installation.md`.

- [ ] Alle neuen Tests sowie `python -m unittest discover -s tools/private/tests -v` und `git diff --check` ausführen; Ergebnis und Einschränkungen lesen. Vor jeder Cloud-Ausführung Gratisrestkontingent und 0-€-Mehrnutzungsblock verifizieren. Nur manuelle Standardrunner, Timeout maximal 120 Minuten, keine kostenpflichtigen Sonderrunner.
- [ ] Einmalige frische Gesamtprüfung der Implementierung gemäß executing-plans/requesting-code-review veranlassen; keine Implementierungsdelegation pro Aufgabe. Wichtige Befunde mit reproduzierendem Test beheben und Suite erneut ausführen. Review bewertet auch die fünf Review-Focus-Fälle.
- [ ] Private App-ID/Name „Navi“ setzen und Android mit eigenem lokalen Entwicklungsschlüssel statt veröffentlichtem Upstream-Schlüssel paketieren; Schlüssel nicht committen oder in Artefakte hochladen. Die vorhandene Test-APK darf nicht still als aktualisierbar ausgegeben werden, wenn App-ID/Signatur wechseln. iOS bleibt ohne privilegierte Fähigkeiten sideloadbar.
- [ ] Neue Gerätepakete über die vorhandenen Skripte bauen. Neue Ausgabe `outputs/builds/Karte-02/`; Herkunftscommit, SHA-256, tatsächliche Lauf-IDs und beide Paketberichte erfassen. Keine alten Pakete umbenennen, um neue Funktionen vorzutäuschen. Bestehende Prüfer um reale MapLibre-Geräteframeworks und Konfigurationsfreiheit der Pakete prüfen, nicht nur um Textmarker.
- [ ] Frische APK mit aapt2/apksigner, IPA samt eingebetteten Framework-Slices und Entitlements prüfen. Einen realen Installations-/Sideload- und Fahrtest durchführen, sobald Geräte verfügbar sind. Manifestfelder bleiben andernfalls `installed_on_device=false`/`navigation_tested=false`.
- [ ] Bericht nennt implementierte Funktionen, tatsächlich geprüfte Kartenmodi, offene Nachweise und die unverändert ausstehende Freundes-/Analyseetappe. Anschließend deren eigenen Implementierungsplan erstellen; Gesamtziel nicht als erreicht markieren, solange Freunde/Fahrten oder Nachweise fehlen.

## Plan-Selbstprüfung und Übergabe

Die Karten-/Kostenanforderungen des freigegebenen Entwurfs sind Aufgaben 1–7 zugeordnet. Die im Entwurf ausdrücklich nachfolgende Freundes-/Fahrtetappe bleibt offen und wird nicht durch diese Aufgaben ersetzt. Reale Kartendarstellung benötigt einen eigenen Esri-Schlüssel; echte Hintergrund-/Fahrtests benötigen Geräte. Keine Testsimulation oder Paketprüfung wird als Ersatz ausgegeben.

Vor Ausführung: Nutzer prüft diesen konkreten Plan und bestätigt die Ausführung in derselben Sitzung. Danach kontinuierlich ausführen; Routineentscheidungen innerhalb dieses Plans protokollieren, keine erneute Freigabe pro Aufgabe verlangen.
