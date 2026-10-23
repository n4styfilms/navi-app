# Navi: neue Karte, Satellit und erhaltene Navigation

Stand: 18. Oktober 2026. **Architekturentwurf vom Nutzer mit „Passt“ freigegeben; noch nicht implementiert.** Der konkrete Implementierungsplan folgt als separater Ausführungsschritt.

Dieser Entwurf ersetzt die Kartenentscheidung im bisherigen Konzept und den davon abhängigen Teil von Bauplan 02. Die bestätigte Gestaltung in `outputs/Navi-Ansichten-v3.png` bleibt maßgeblich. Die vorhandenen Basis-Pakete werden nicht als fertige Navi-App bezeichnet oder überschrieben.

## Ziel und vollständiger Produktumfang

Private Android-/iOS-App für ungefähr fünf Personen, ausschließlich mit kostenlosen Werkzeugen und kostenlosen Dienstkontingenten. Android wird als APK, iOS als Geräte-IPA für einen kostenlosen Sideloader ausgeliefert. Kein eigener Mac und kein kostenpflichtiger Apple-Entwickleraccount. Der Nutzer akzeptiert den regelmäßigen Signatur-Refresh.

Die App muss eine hochwertige farbige Straßenkarte und weltweite Satellitenbilder anbieten. Bedienflächen bleiben neutral, gerundet und einfach. Die Karte ohne Route zeigt freiwillig freigegebene Freunde samt gültiger Geschwindigkeit. Navigation umfasst Suche, unterstützte Vermeidungsoptionen, Sprachansagen, Neuberechnung und bekannte Tempolimits. Fahrzeug und Motorisierung, WLTP, Literpreis und optional eigener Verbrauch ergeben eine gekennzeichnete Spritkostenschätzung. Freigegebene Fahrten enthalten Verlauf und nachvollziehbare, qualitätsabhängige Fahrereignisse.

Die Umsetzung erfolgt in überprüfbaren Etappen. Dieser Kartenentwurf erklärt die nächste technische Änderung; er erklärt die übrigen Funktionen nicht für erledigt und streicht sie nicht aus dem Ziel.

## Geprüfter Ausgangszustand

- Produkt-Checkout: `outputs/navi`, HEAD vor diesem Dokument `62ec80172f4f9dc3dcf745c89d9dd82a668437ed`; Arbeitsbaum bei Prüfung sauber.
- Basis-APK und Geräte-IPA liegen unter `outputs/builds/Basis-01`. Beide enthalten noch die CoMaps-Oberfläche. Keine eigene Sprit-, Freundes- oder Analysefunktion ist implementiert. Keine Installation auf einem echten Handy wurde nachgewiesen.
- Die vorhandene Android-Java-/iOS-Swift-/Objective-C++-Oberfläche verwendet den gemeinsamen C++-Kern. Es gibt in den untersuchten Karten-/Frontend-Verzeichnissen keine fertige MapLibre-, ArcGIS-, Satelliten- oder Rastertile-Anbindung.
- `libs/map/framework.cpp`, `Framework::OnLocationUpdate`, leitet Positionen an den Router weiter. Aufbau und Lebenszyklus des Drape-Renderers sind eigene Methoden. Das spricht für eine trennbare Darstellung, beweist aber noch keinen vollständig funktionsfähigen Router ohne Drape.
- `libs/map/routing_manager.hpp` stellt Navigation, Ansagen und Routenschritte bereit. Der vorhandene `GetRoutePolyline()` greift auf `GetRouteForTests()` zu. Er wird nicht ungeprüft zur öffentlichen, nebenläufigen Produktionsschnittstelle erklärt.
- Vertiefte Quellprüfung: `RoutingManager::OnExtrapolatedLocationUpdate` berechnet den Routenabgleich auch ohne Drape; nur die Weitergabe an die Darstellung ist abgesichert. GPS-Navigation ist an dieser Stelle also nicht durch einen fehlenden Renderer gesperrt. `RoutingManager::InsertRoute` beendet sich dagegen ohne Drape vor `CollectRoadWarnings` und `CollectTrafficLights`. Diese fachliche Auswertung muss von der Darstellung getrennt werden, damit Warnungen beim Rendererwechsel erhalten bleiben. Das ist ein konkreter Integrationsbedarf, kein bereits bestandener Laufzeittest.

## Ansätze und Entscheidungsvorschlag

1. **MapLibre Native + Esri-Kartendienste + vorhandener Navigationskern (empfohlen).** Neue Kartenansicht und frei gestaltbares natives UI, vorhandene Offline-Suche und Routenlogik bleiben. Größter Aufwand ist die verlässliche Trennung von Router und Darstellung.
2. **MapTiler-eigenes Mobil-SDK + vorhandener Navigationskern.** Gute Karten einschließlich Satellit; Sitzungszählung mit aktuell 5.000 kostenlosen Kartensitzungen monatlich. Die Kernintegration bleibt genauso erforderlich. Alternative, falls die Esri-Stile qualitativ nicht überzeugen.
3. **Kompletter Wechsel zu einem Online-Router.** Einfachere Verbindung von neuer Karte und Route, aber zusätzliche externe Kontingente und Abhängigkeit bei jeder Routenberechnung. Verwirft einen bereits gebauten Navigationskern; deshalb zunächst nicht gewählt.

Vorgeschlagen ist Ansatz 1. Es werden nicht dauerhaft zwei Karten übereinander gerendert. Ein unsichtbarer zweiter Renderer ist kein akzeptierter Dauerbetrieb.

## Architektur und Datenfluss

### Native Kartenansicht

MapLibre Native übernimmt Android-/iOS-Kamera, Gesten, Position, Routenlinie, Zielmarkierung und später Freundesmarker. Esri liefert authentifizierte Kartenstile für die Straßenansicht und Satellit/Hybrid. Stil und Abhängigkeiten müssen auf beiden nativen Plattformen praktisch geprüft werden; ein JavaScript-Beispiel beweist keine native Integration.

Der Wechsel Straße/Satellit erhält Mittelpunkt, Zoom und Richtung sowie Route, Ziel, Position und Freunde. Graphitfarbene Route mit hellem Rand bleibt auch auf Satellitenbildern erkennbar. Die UI folgt Hell/Dunkel unabhängig vom Kartenmodus. Anbieter- und Datenquellenangaben bleiben sichtbar und erreichbar, auch bei geöffnetem Routenblatt.

Esri-Stile werden über die dokumentierten, authentifizierten APIs eingebunden. Keine fremden Beispielschlüssel und kein anonymer World-Imagery-Link als Umgehung. Keine heruntergeladenen Satellitenpakete oder Server-Proxies ohne nachgewiesene Erlaubnis. Offline-Kartendarstellung mit Esri wird nicht versprochen.

### Navigation und Brücke

Ein gemeinsamer C++-Adapter liefert unveränderliche Routensnapshots an JNI beziehungsweise Objective-C++:

- monotone Routenrevision und Zustand: keine Route, Aufbau, Vorschau, Navigation, Fehler;
- Geometrie als Längen-/Breitengrad, gesamte und verbleibende Distanz in ungerundeten Metern;
- gesamte/verbleibende Dauer, nächstes Manöver, Straße und Ansagetexte;
- Kartenabgleich der eigenen Position sowie Tempolimit nur bei vorhandenem gültigem Kernwert;
- Fehler bei fehlenden Offline-Karten mit Zugang zum Kartendownload.

Aufbau und Neuberechnung publizieren neue Revisionen. Veraltete asynchrone Antworten dürfen eine neuere Route oder einen Routenabbruch nicht überschreiben. UI/Karte erhalten keine veränderlichen Router-Referenzen. Kameraänderungen berechnen keine neue Route. Ein Standortstrom versorgt Router, sichtbare Position und Aufzeichnung; kein doppelter GPS-Dienst pro Renderer.

**Erster technischer Nachweis vor dem Oberflächenumbau:** Mit tatsächlich heruntergeladenen Routendaten ohne Drape-Renderer Route berechnen, Positionen wiedergeben, Ansage und Neuberechnung auslösen und vollständigen Snapshot auslesen. Kartenpunkte, Routendistanz und Abbruch müssen korrekt bleiben. Die bekannte Abhängigkeit der Straßenwarnungen in `InsertRoute` wird vorher entkoppelt; derselbe Routenfall muss mit und ohne Renderer dieselben fachlichen Warnungen ergeben. Falls der Test weitere Abhängigkeiten zeigt, werden diese vor dem UI-Umbau gezielt entkoppelt. Eine bloße Kompilierung oder Quellcodeinspektion erfüllt diesen Nachweis nicht.

### Spritkosten

Lokales Profil: Marke, Modell, Motor, Baujahr, Benzin/Diesel, WLTP, Literpreis und optional eigener Durchschnitt. Eigener Durchschnitt hat Vorrang. Kosten = Distanz in Metern / 100000 × Verbrauch in l/100 km × Preis in €/l. Rundung erst zur Anzeige; Beispiel 120 km, 6 l/100 km und 1,80 €/l = 12,96 €.

Nur fertige Autorouten und gültige Profile erhalten eine Geldzahl. Fehlende Werte führen zu einer konkreten Ergänzungsaktion. Deutsche Dezimalzeichen werden unterstützt; negative/nicht endliche Werte abgewiesen. Verbleibende Kosten werden entsprechend beschriftet. Fahrweise-Multiplikatoren werden ohne Kalibrierung nicht erfunden; die spätere Anpassung muss gegen tatsächlichen Verbrauch geprüft werden.

### Freunde und Fahrten

Die nachfolgende Freundesetappe nutzt die neue Kartenansicht. Vorgesehene Grundlage bleibt Firebase Spark ohne Cloud-Billing, mit bestätigten Freigaben und serverseitigem Zugriffsschutz. Position, Geschwindigkeit und Verlauf werden getrennt freigegeben. Eine leere Freundesliste enthält keine erfundenen Personen.

Messwerte enthalten Messzeitpunkt, Genauigkeit und gültige optionale Geschwindigkeit. Bis 15 Sekunden werden sie als aktuell dargestellt; danach als letzter bekannter Stand. Fehlende Geschwindigkeit ist kein Stillstand. Widerruf verhindert weiteren Zugriff durch Datenbankregeln. Standortfreigabe bleibt sichtbar pausierbar. Hintergrundverhalten, erneuter App-Start, Netzverlust und Wiederverbindung benötigen Zwei-Geräte-Nachweise für beide Betriebssysteme.

Lokale Fahrten und freigegebene Verläufe bleiben Teil des Ziels. Brems-/Beschleunigungshinweise benötigen geeignete Sensorqualität und reale Kalibrierung. Ein bewegtes Handy oder schlechter GPS-Empfang darf nicht zu einer scheinbar gesicherten Bewertung „unsicher“ führen. Keine Unfall-/Notrufversprechen.

## Kostenkontrolle und Einrichtung

Aktuell umfasst Esri Location Platform 2 Millionen kostenlose Basemap-Kacheln pro Abrechnungsmonat. Für diese Integration bleibt Pay-as-you-go ausgeschaltet; es werden keine Zahlungsmittel hinterlegt. Ohne PAYG werden Kartendienste nach erschöpftem Gratisvolumen bis zum nächsten Zyklus gesperrt. Routing, Geocoding und Hosting sind andere Kontingente und werden durch die Kartenanzahl nicht abgedeckt. Unsere Kernrouten bleiben lokal.

Ein eigener Esri-Account und ein auf die benötigten Kartendienste beschränkter Schlüssel sind für authentische Straßen-/Satellitentests erforderlich. Es existiert bisher kein eingerichteter Schlüssel im Projekt. Kein Zugang oder Schlüssel wird erfunden oder aus fremden Projekten kopiert. App-Konfiguration nimmt den Schlüssel entgegen; er wird nicht in Repository, Screenshots, Protokolle oder Fehlermeldungen geschrieben. Ein Schlüssel in einer mobilen App ist grundsätzlich auslesbar; Berechtigungsbegrenzung und Austausch bleiben notwendig.

Bei fehlender Konfiguration erscheint eine verständliche Einrichtungsmeldung. Bei Authentifizierungsfehlern, fehlendem Netz, ausgeschöpftem Kontingent oder nicht verfügbaren Bildern zeigt die App den tatsächlichen Zustand und beendet wiederholte Fehlanfragen. Eine aktive Navigation darf dabei ihre letzte Route und Ansagen behalten. Eine leere Kartengrafik wird nicht als geladene Karte dargestellt.

App-seitige Anfragezähler dienen der Messung, nicht als verbindlicher Kontostand; maßgeblich ist das Anbieter-Dashboard. Keine weltweiten Vorabdownloads. GitHub-Builds bleiben manuell und innerhalb des kostenlosen Kontingents mit gesperrter Mehrnutzung.

## Überprüfbare Abnahme

| Anforderung | Erforderlicher Nachweis | Jetzt |
|---|---|---|
| Farbige hochwertige Straße | Laufende Android-/iOS-Ansicht, reale Orte, verständliche Beschriftung und geprüfte Attribution | Offen |
| Satellit weltweit, Hybrid | Authentifizierte Bilder an Orten in Europa, Nordamerika und einer weiteren Weltregion; Unterschiede in Alter/Auflösung sichtbar dokumentiert | Offen |
| Moduswechsel | Kamera, Route, Ziel, Position erhalten; kein doppelter Renderer | Offen |
| Navigation bleibt funktional | Echte Daten: Route, Simulation, Ansage, Abweichung/Neuberechnung, Abbruch; anschließend reale Fahrt | Offen |
| Tempolimit | Bekannter Kernwert korrekt; unbekannt bleibt unbekannt | Offen |
| Rundes neutrales UI | Laufende Ansichten ohne Route, Vorschau, Navigation gegen bestätigte Fassung 03; kleine Displays, große Schrift, Tastatur, Hell/Dunkel | Offen |
| Fahrzeug und Spritkosten | Gemeinsame fachliche Fälle auf Android/iOS, Speicherung nach Neustart, echte numerische Routendistanz | Offen |
| Freunde ohne Route | Zwei echte angemeldete Geräte, bestätigte Freigabe, Geschwindigkeit und Alter; unbekannte Nutzer abgewiesen | Offen, Folgeetappe |
| Dauerfreigabe und Widerruf | Zwei-Geräte-Tests mit Bildschirm aus, Netzverlust, Neustart und Regeltests | Offen, Folgeetappe |
| Fahrtverlauf und Fahrweise | Aufnahme/Löschung/Freigabe, Mitfahrerstatus, reale Ereignisse und Sensorstörungen | Offen, Folgeetappe |
| APK und IPA | Beide aus tatsächlichem Stand gebaut, Paketprüfer und Herkunft/Hash, Sideloader-Installation | Nur alte Basispakete vorhanden |
| Ausschließlich 0 € | Kein PAYG/Cloud-Billing; tatsächlicher Gratis-Kontingentstand vor Cloudbuilds; Limittest ohne Nachbelastung | Für neue Integration offen |

Tests mit lokalen Antworten sind geeignet, Fehlzustände und Adapter zu prüfen. Sie ersetzen weder authentifizierte Bildabrufe noch Geräte- und Fahrtests. Keine der offenen Zeilen wird allein durch dieses Dokument abgeschlossen.

## Grenzen und nächster Übergang

Diese Änderung ist architektonisch: Sie ersetzt die sichtbare Kartenkomponente und ergänzt eine neue Router-Schnittstelle. Nach Freigabe dieses Entwurfs folgt der konkrete Implementierungsplan mit Dateipfaden, Testbefehlen, Abhängigkeiten und Paketnachweisen. Danach wird in der bestehenden Sitzung ausgeführt. Die echte Kartenabnahme benötigt den eigenen Esri-Zugang; die Arbeit an Adapter und Kostenfunktion kann unabhängig von einem Schlüssel beginnen.

## Aktuell geprüfte Primärquellen

- Esri Kontingente: https://developers.arcgis.com/pricing/
- Esri PAYG standardmäßig aus; Zugriffe nur innerhalb Gratisvolumen: https://location.arcgis.com/help/billing/
- Esri Basemap Styles, v8-Styles, Attribution: https://developers.arcgis.com/rest/basemap-styles/
- Esri Static Basemap Tiles, Koordinaten und Metadaten: https://developers.arcgis.com/rest/static-basemap-tiles/
- MapTiler Mobil-SDK mit Sitzungen: https://www.maptiler.com/mobile-maps-sdk/
- MapTiler Free und Sperre beim Limit: https://www.maptiler.com/cloud/pricing/

Selbstprüfung: Status und offene Nachweise sind ausdrücklich angegeben; keine Satellitenqualität oder native SDK-Kompatibilität ungeprüft garantiert; keine Begrenzung des Gesamtziels auf die Kartenetappe. Keine Produktimplementierung vor der Entwurfsfreigabe.

## Freigegebene Ergänzung vom 20. Oktober 2026

Der Nutzer hat ausdrücklich „Ja, Straßenkarte sofort ohne Konto“ gewählt. Diese Entscheidung ersetzt die Esri-Straßenkarte im ursprünglichen Entwurf: MapLibre lädt für Straßen **immer OpenFreeMap Liberty**, auch wenn später ein Esri-Schlüssel hinterlegt ist. Satellit bleibt beim bisherigen Esri-Zugang; ohne Schlüssel bleibt die Straßenkarte nutzbar. Die bestätigte Gestaltung und der vorhandene Offline-Router bleiben maßgeblich.

Offizieller Stil: `https://tiles.openfreemap.org/styles/liberty`. OpenFreeMap unterstützt MapLibre Native und bietet den öffentlichen Online-Dienst ohne Anmeldung, API-Schlüssel oder Mapview-/Anfragelimit an. Ein Verfügbarkeits-SLA besteht nicht. Quellen: [Anbieter](https://openfreemap.org/), [Integration und Mobilregeln](https://openfreemap.org/quick_start/).

Der HTTP-Transport erlaubt öffentliche Kartenressourcen ausschließlich über HTTPS auf `tiles.openfreemap.org`, entfernt Authentifizierungsheader für diesen Host und kennzeichnet die App mit eigenem User-Agent. Esri-Header bleiben auf die bestehenden vertrauenswürdigen Esri-Hosts begrenzt. MapLibre zeigt die Quellennachweise weiterhin an. Es wird kein unbeschränkter Download von OpenFreeMap-Kartenregionen eingebaut; die bereits vorhandenen Offline-Routingdateien sind ein eigener Datenbestand.

Prüfung: echte Java-Konfiguration und OkHttp-Transport testen Straßenbetrieb ohne Schlüssel, Straßenbetrieb mit hinterlegtem Satellitenschlüssel, entfernte öffentliche Authentifizierung und unveränderte Fehler-/Generationsgrenzen. Sichtbarer Android-/iOS-Nachweis erfolgt erst mit neuem Build; die ältere signierte APK enthält diese Ergänzung noch nicht.
