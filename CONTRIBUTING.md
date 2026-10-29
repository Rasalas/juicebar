# Beitragen

`swift test` prüft Normalisierung, Warnregeln, lokale Speicherung und begrenzte Prozessabfragen. `bash scripts/build-app.sh debug` baut das App-Bundle; `--demo` erlaubt UI-Arbeit ohne Konten. Die Tests verwenden ausschließlich synthetische Werte.

## Neuen Anbieter ergänzen

1. Datenquelle, Authentifizierung, Einheiten, Reset-Semantik und Nutzungserlaubnis anhand der Anbieterquellen prüfen. Befund mit Datum unter `docs/` festhalten.
2. Anbieter in `ProviderKind` mit Name, kurzer Menüleistenkennung und Kontoseite ergänzen.
3. `UsageProvider` implementieren und in `ProviderRegistry` registrieren. Strukturprüfung in eine reine Parserfunktion auslagern. Keine Modellanfragen zur Verbrauchsermittlung verwenden.
4. Nur belegte Werte als `QuotaWindow`, `ResetBenefit`, `MoneyMetric` oder `UsageDay` ausgeben. Prozent, Tokens und Geld nicht vermischen. Bei unbekannter Fenstersemantik `supportsPace` deaktivieren.
5. Synthetische Fixtures für normale Antwort, fehlende Werte, zusätzliche Felder und Schemaänderungen testen. Keine echten Tokens, Konto-IDs, E-Mails oder Rohantworten einchecken.
6. Bestehende Warnlogik und Ansichten verwenden. Eigene Sonderfälle gehören in den Adapter, nicht in die Ansichten.

`QuotaWindow.kind` und `scope` beschreiben Zeitfenster und Geltungsbereich unabhängig vom Anzeigetext. Neue Adapter setzen sie aus bekannten Anbieterfeldern. Alte Snapshots erhalten diese Angaben aus stabilen IDs und bekannter Dauer, niemals aus übersetzten Namen. Unbekannte Scopes behalten die höhere Evidenzschwelle für Wochenprognosen.

`QuotaNumbers` akzeptiert endliche, nichtnegative Prozentwerte auch oberhalb von 100 %. Reset-Anzahlen müssen ganzzahlig und als `Int` darstellbar sein. Fensterdauern außerhalb von einer Sekunde bis zehn Jahren sowie Zeitstempel außerhalb der Jahre 1970 bis 9999 bleiben unbekannt. Nicht darstellbare Budgetprozente und überlaufende Kostensummen liefern einen Anbieterfehler. Cache-Decoding prüft Quoten ebenfalls; Formatierung verwendet keine ungeprüfte Umwandlung nach `Int`.

## Grenzen und Fehler

Ein fehlgeschlagener Abruf ersetzt keinen letzten Wert durch null. Neue Transportwege brauchen Timeout, Größenlimit, Abbruch und nachvollziehbare Fehler. Credentials dürfen weder in Fehlermeldungen noch Diagnoseausgaben erscheinen. Schlüsselbund-Zugriffe dürfen im Hintergrund keine Dialoge auslösen; `LAContext` allein reicht beim alten macOS-Login-Schlüsselbund nicht aus. Der ergänzende Legacy-Schalter ist deshalb bewusst vorhanden.

API-Adapter ohne verfügbare Testanmeldung müssen als nicht live verifiziert dokumentiert bleiben. Eine unbekannte Einheit, Kontozuordnung oder Reset-Semantik ist kein Anlass, Werte zu raten.

## Veröffentlichung

CI erzeugt ein ad-hoc signiertes Archiv. Für reguläre Downloads sind stabile Developer-ID-Signierung, Notarisierung und Tests auf den tatsächlich unterstützten macOS-Versionen nötig. Eigene gespeicherte Keys können bei wechselnder ad-hoc Signatur erneut eingegeben werden müssen. Kein Release behauptet getestete Plattformen oder einen Langzeit-Leak-Test, die tatsächlich nicht geprüft wurden.

Details zu kostenlosen Updates, Store-Varianten und Plattformen stehen im [Vertriebsplan](docs/distribution.md). Der [Release-Ablauf](docs/releasing.md) trennt lokale Entwicklungsartefakte von signierten Downloads.
