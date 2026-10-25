# Private Gruppe einmalig einrichten

Die Straßenkarte braucht kein Konto. Für die Freundeskarte verwenden alle fünf Personen dasselbe eigene Firebase-Projekt und jeweils ein eigenes Konto. Im Quellcode und in den Builds ist kein fremder Projektzugang enthalten.

Diese Anleitung gehört zum neuen Android-Quellstand. Die bisher ausgegebene Karte05-APK enthält die Freundesoberfläche noch nicht. Ein neuer vollständiger App-Build ist noch zu prüfen.

1. In der [Firebase-Konsole](https://console.firebase.google.com/) ein Projekt im **Spark-Tarif** anlegen. Keine Abrechnung verbinden und nicht auf Blaze wechseln. Analytics ist für Navi nicht nötig.
2. Unter **Authentication → Anmeldemethode** E-Mail/Passwort einschalten. Die App verwendet keine SMS-Anmeldung.
3. Unter **Realtime Database** eine Datenbank im gesperrten Modus anlegen. Unter **Regeln** den vollständigen Inhalt von [`backend/firebase/database.rules.json`](../backend/firebase/database.rules.json) einsetzen und veröffentlichen. Keine offenen Testregeln verwenden. Die bereits ausgeführten lokalen Tests sind kein Cloud-Deployment.
4. Unter **Projekteinstellungen → Deine Apps** eine Android-App mit dem Paketnamen `app.navi.private` hinzufügen. Den Client-Zugang aus der Projektkonfiguration entnehmen; die HTTPS-Datenbankadresse steht in Realtime Database.
5. Folgenden Block mit den eigenen Werten ausfüllen. Er enthält Client-Konfiguration, **kein** Dienstkonto und **keinen** privaten Signierschlüssel:

```json
{
  "projectId": "eure-projekt-id",
  "applicationId": "WERT_AUS_MOBILESDK_APP_ID",
  "apiKey": "EIGENER_CLIENT_API_KEY",
  "databaseUrl": "https://EURE_DATENBANK.firebasedatabase.app"
}
```

6. In der neuen App **Freunde → Gruppe einrichten** diesen Block einsetzen. Alle verwenden dieselbe Gruppe. Danach erstellt jede Person ihr eigenes Konto in der App. Passwörter werden vom Auth-SDK verwaltet.
7. Den eigenen Freundecode kopieren und privat austauschen. Eine Person sendet eine Anfrage, die andere nimmt sie an. Anschließend unter dem jeweiligen Freund ausdrücklich Standort, Geschwindigkeit und später Fahrten auswählen. Eine bestätigte Anfrage allein erteilt keine Leserechte.
8. **Standort teilen** aktiviert die Freigabe und den sichtbaren Android-Dienst. **Pausieren** stoppt lokale Veröffentlichungen. Ohne Netz bleibt die Serverbestätigung ausstehend; ein bereits sichtbarer alter Standort kann bis zum Widerruf auf dem Server lesbar bleiben. Die andere App zeigt Messalter und keine gültige Geschwindigkeit für veraltete Daten.

Stand 25.10.2026 nennt Firebase für Spark 100 gleichzeitige Datenbankverbindungen, 1 GB gespeicherte Daten und 10 GB Downloads pro Monat; Spark benötigt keine Zahlungsmethode. Das ist ein begrenztes kostenloses Kontingent. Der konkrete monatliche Verbrauch dieser App mit fünf Personen ist noch nicht gemessen. Quelle: [Firebase-Preise](https://firebase.google.com/pricing), [Datenbanklimits](https://firebase.google.com/docs/database/usage/limits).

Noch offen: echte Prüfung mit eurem Projekt und zwei Geräten, Hintergrundbetrieb auf echten Handys, Fahrtenaufzeichnung/-analyse und entsprechende iOS-Integration. Die Auswahl eines Fahrtenrechts allein implementiert noch keine Historie. Satellitenzugang ist davon unabhängig und benötigt weiterhin den eigenen Esri-Zugang.
