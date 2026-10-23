# Karten- und Kostenetappe – Stand 21.10.2026

Die neue Android-Oberfläche läuft mit MapLibre und einer echten farbigen Straßenkarte von OpenFreeMap Liberty. Dafür sind kein Konto und kein API-Schlüssel nötig. Satellit bleibt über einen späteren eigenen Esri-Zugang vorgesehen; echte Satellitenbilder sind bisher nicht geprüft. [OpenFreeMap](https://openfreemap.org/), [native Integration](https://openfreemap.org/quick_start/).

## Nachgewiesen

- Der native Linux-Lauf [39150684145](https://github.com/n4styfilms/navi-private/actions/runs/39150684145) bestand 108 Karten- und 283 Routingtests. Ein zusätzlicher Test mit echten Monaco-Kartendaten prüft Navigation ohne zweiten Renderer, 77 synthetische GPS-Updates, Ansagen, Neuberechnung und Abbruch. Der Routenstart vom aktuellen Standort wurde mit einem zuvor fehlschlagenden Test korrigiert.
- Die vollständig gebaute und lokal signierte Android-APK aus [39387507262](https://github.com/n4styfilms/navi-private/actions/runs/39387507262), Quelle `811e7ba`, ist im Emulator installiert. Tatsächlich geprüft: Kartenstart, gespeichertes Fahrzeugprofil, Koordinatensuche, Route vom aktuellen Standort, Routenstart, Geschwindigkeit, vorhandenes Tempolimit, Hintergrund/Rückkehr und Stopp des Navigationsdiensts. Die installierte App zeigte für eine Route von 3,8 km bei 6,0 l/100 km und 1,80 €/l rund 0,41 €; mit dem Fortschritt sank die Restkostenschätzung.
- Diese APK hat einen bekannten Fehler beim Abbrechen überholter Kartenanfragen und ist deshalb ein Zwischenstand. Der Fehler wurde im echten HTTP-Client reproduziert und korrigiert. Das neue Paket muss die Korrektur noch im App-Betrieb bestätigen.
- Der Android-Build `39433657477` (Quelle `5ddf44b`) bestand einschließlich 21 Gradle-Tests. Das lokal signierte Paket unter `Karte-04` bleibt ein Zwischenstand. Der neuere Build `39438431764` (Quelle `86ef4b2`, Kamera-Folgemodus nach Drehung) bestand ebenfalls; sein kurz gespeichertes Cloud-Artefakt ist inzwischen abgelaufen und wurde nicht als neues Paket ausgegeben.
- Der tatsächliche Produktions-HTTP-Client verwarf HTTP 304 und pausierte damit die Karte bei einer normalen Cache-Bestätigung. Der Test schlug zunächst fehl und besteht nach der Korrektur in `5b6d489`; Umleitungen und echte Fehler bleiben abgelehnt. OpenFreeMap lieferte für eine echte bedingt angefragte Schriftdatei HTTP 304. Der lokale Hostlauf bestand 37 ausgeführte von 42 Tests; drei Apple- und zwei mangels konfiguriertem C++-Compiler nicht ausführbare Prüfungen wurden ausdrücklich übersprungen.
- Ein separates Android-Testprogramm mit den tatsächlichen Kartenklassen und MapLibre 13.7.1 lädt OpenFreeMap ohne Konto. Die fehlenden Texte wurden mit derselben APK und denselben zwischengespeicherten Kartendaten auf den SwiftShader-Grafikmodus des Emulators eingegrenzt: Mit der NVIDIA-GPU erscheinen Ortsnamen, Straßennamen und Symbole korrekt. Dies ist ein Komponenten-Nachweis, noch keine Abnahme des neuen vollständigen App-Pakets. [Bekannter Emulatorfehler](https://github.com/maplibre/maplibre-native/issues/3648).
- Der Mac-Lauf `39435785482` (Quelle `08b9993`) bestand die tatsächlichen Swift-Hostprüfungen und kompilierte die vollständige Simulator-App. Der Testhost stürzte danach vor der XCTest-Verbindung mit SIGTRAP ab. Es wurde keine neue IPA erzeugt; die Ursache wird aus den erhaltenen Xcode-Diagnosen ermittelt.

## Laufende Builds

Beide Läufe verwenden Quelle `57a7f99b42239786d336bed62245d165d215cc62`:

- [Android 39667390554](https://github.com/n4styfilms/navi-private/actions/runs/39667390554): vollständige APK einschließlich HTTP-304-, Kamera- und Navigationskorrekturen.
- [iOS-Diagnose 39666655523](https://github.com/n4styfilms/navi-private/actions/runs/39666655523): Auswertung der gespeicherten Absturzdaten, kein App-Neubau. Der vorausgegangene Diagnoselauf konnte den privaten Release-Entwurf mit seinen eingeschränkten Leserechten nicht abrufen. Die unveränderten Testdaten liegen deshalb auf einem separaten privaten Diagnose-Branch; Build-Berechtigungen wurden nicht erweitert.

## Grenzen und nächste Etappen

Die Tests liefen auf einem Android-Emulator mit ARM64-Übersetzung beziehungsweise einem separaten x86_64-Kartentest und synthetischen Standorten. Ein physisches Android-Handy oder iPhone und ein echter Fahrtest sind nicht geprüft. Norton ersetzte die HTTPS-Zertifikate und verhinderte zunächst den aktuellen Emulator-Netzzugriff. Später wurde das reguläre Google-Trust-Services-Zertifikat und erfolgreicher HTTPS-Kartenzugriff beobachtet. Der Agent hat weder Norton-Einstellungen geändert noch ein Stammzertifikat importiert oder die Zertifikatsvalidierung abgeschaltet. Der Nutzer wurde nach dem Verbindungstest darauf hingewiesen, eine gegebenenfalls pausierte HTTPS-Prüfung wieder einzuschalten.

Freundesfreigaben, Fahrtverläufe und Fahranalysen sind weiterhin Teil des Gesamtziels und noch nicht implementiert. Verbrauchskosten sind Schätzungen anhand des eingetragenen WLTP- oder eigenen Durchschnittsverbrauchs und der tatsächlichen Routendistanz. Es gibt keine erfundenen Fahrstilfaktoren oder geratenen Tempolimits.

Die alten Pakete unter `builds/Basis-01`, `Karte-02`, `Karte-03` und `Karte-04` bleiben erhalten. Kein alter Build wird als neuer Nachweis ausgegeben. Android benötigt mindestens Android 6/API23; das iOS-Ziel bleibt iOS 15.6 oder neuer. Installation der Geräte-IPA erfordert später Signieren durch einen kostenlosen Sideloader.

GitHub-Kostenprüfung vor dem aktuellen vollständigen Android-Build: 1.624,3 von 2.000 enthaltenen Actions-Minuten genutzt; 0 USD abrechenbare Nutzung; Speicheranzeige 0 GB von 0,5 GB. Das Actions-Budget steht weiterhin auf 0 USD mit gesperrter Mehrnutzung. Keine Zahlungs- oder Abrechnungseinstellungen geändert. Detaillierte Nachweise und Entscheidungen stehen außerhalb des Repositories unter `work/kartenwechsel/progress.md`.
