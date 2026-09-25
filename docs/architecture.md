# Implementierungsstand

Die erste lauffähige Version verwendet SwiftUI/AppKit und SQLite unter macOS 14+. Der folgende ursprüngliche Entwurf beschreibt auch spätere Ausbaustufen; für tatsächlich verfügbare Funktionen und Grenzen gilt die [README](../README.md). Insbesondere sind Windows/Linux, ein generisches Plugin-Ladesystem, automatische Adapter-Reparaturen, vollständig isolierte Anbieter-Helfer und zusätzliche Sonderregeln zur Nachtruhe noch nicht implementiert.

# Juicebar: Architekturvorschlag

Stand: 25. September 2026. Entwurf, noch keine implementierte App. Die Modulstruktur ist unabhängig vom Stack. Tauri ist eine vorläufige Variante; Swift und Wails werden in [technology-choice.md](technology-choice.md) dagegen abgewogen.

## Ziel und Reihenfolge

Juicebar zeigt Kontoverbrauch in der Menüleiste oder im Tray und warnt rechtzeitig vor Limits. Zuerst ChatGPT/Codex und Claude-Abos, danach OpenCode Go, Zen und API-Abrechnung. Eine Nutzungsansicht ergänzt später die Kontolimits um lokale Session-, Projekt- und Modellstatistiken.

macOS ist die erste Zielplattform. Windows und Linux sind erwünschte, bisher optionale Erweiterungen. Bei Wahl eines gemeinsamen Desktop-Stacks erhalten sie früh Build-Prüfungen, gelten aber erst nach Tests ihrer installierten Pakete als unterstützt. Bei einer nativen Swift-App benötigen sie eine eigene Oberfläche und Betriebssystemintegration.

## Module und Interfaces

```text
Anbietermodule                Lokale Nutzungsquellen
Codex, Claude, Go, Zen, ...   Codex, Claude Code, OpenCode
          |                            |
     Kontostände                  Session-Nutzung
          |                            |
          +---- Speicherung und Zuordnung ----+
                         |
                Auswertung und Warnregeln
                         |
          Tray, Detailansicht, Benachrichtigungen
```

Die Trennung ist fachlich: Ein Konto kann in mehreren Programmen verwendet werden, ein Programm kann mehrere Anbieter nutzen. Kontoprozentwerte dürfen niemals über Sessions oder Programme summiert werden. Lokale Nutzung und kontoweite Abrechnung haben unterschiedliche Abdeckung und bleiben erkennbar.

Ein Anbietermodul versteckt Transport, Authentifizierung, Versionsunterschiede und Parsing hinter einem kleinen Interface:

- `describe()` liefert Anbieterkennung, Anzeigename und unterstützte Fähigkeiten.
- `connect(action)` führt eine ausdrücklich gestartete Verbindung oder Reparatur durch und liefert einen opaken Kontoverweis.
- `read(account, deadline)` liefert einen normalisierten Kontostand oder einen typisierten Fehler.
- `watch(account)` liefert optional Änderungen; fehlt diese Fähigkeit, plant der Kern Abfragen.
- `close()` beendet eigene Verbindungen und Helfer.

Das Interface definiert auch Abbruch, maximale Antwortgröße und Ereignissemantik. Ein Ereignis kann einen vollständigen Kontostand oder eine explizite Teilaktualisierung liefern. Das Fehlen eines Limits in einer Teilaktualisierung löscht es nicht. Zugangsdaten bleiben im Modul beziehungsweise im Betriebssystemspeicher und gelangen nicht in UI oder Verlaufsdaten.

Der zentrale Scheduler verhindert überlappende Abfragen, berücksichtigt Anbieter-Mindestintervalle und `Retry-After`, setzt Zeitlimits und begrenzt Wiederholungen. Anbieterfehler stoppen keine anderen Module. Transportdetails und Login-Interaktionen bleiben im jeweiligen Modul.

Für den Anfang liegen Anbieter als eingebaute Module im Repository. Neue Anbieter ergänzen ein Modul, seine Registrierung und Vertragsfixtures. Ein Laufzeit-Plugin-System ist für diese Erweiterbarkeit nicht erforderlich.

## Gemeinsames Datenmodell

Ein Kontostand enthält `providerId`, eine stabile `accountId`, `observedAt`, Datenquelle, Aktualitätsstatus und eine Liste von Messwerten. Anzeigenamen sind keine Identitäten. Automatische Zusammenführung erfolgt nur bei belegbarer Kontozuordnung; andernfalls bleiben Quellen getrennt oder werden vom Nutzer zugeordnet.

Die Messwerte sind unterschiedliche Typen:

| Typ | Inhalt | Darstellung |
| --- | --- | --- |
| `quota` | Prozent verbraucht, optional absoluter Verbrauch und Limit, Zeitfenster, Reset, Geltungsbereich | Limitbalken und Reset |
| `balance` | Verfügbares Guthaben und Währung | Geldbetrag |
| `spend` | Ausgaben, Währung, Zeitraum, gemessen oder geschätzt | Kosten und optional eigenes Budget |
| `activity` | Tokens oder Requests, Zeitraum, Programm/Projekt/Modell soweit bekannt | Nutzungshistorie |

Jeder Messwert hat eine stabile ID, Herkunft und Abdeckung. Zeitfenster tragen ihre Semantik, etwa fester Zeitraum, echtes gleitendes Fenster oder unbekannt. Ein Reset-Zeitpunkt allein beweist keinen festen Fensterbeginn. Modellgruppen sind optionale Geltungsbereiche, keine fest eingebauten Modellnamen.

Fähigkeiten werden pro Konto und Messwert ausgewiesen. Fehlende Werte bedeuten unbekannt oder nicht unterstützt, niemals automatisch null Verbrauch. API-Keys erlauben nicht bei jedem Anbieter kontoweite Abfragen. Lokal berechnete Listenpreiskosten bleiben Schätzungen und sind bei Abos keine zusätzliche Rechnung.

Ein selbst gesetztes Budget ist ein eigenes Objekt mit Zeitraum, Betrag und Währung. Es wird weder mit einem Anbieterlimit noch mit einem Guthaben verwechselt.

## Angesparte Resets und zeitlich begrenzte Vorteile

Kontostände enthalten zusätzlich eine optionale Liste von Vorteilen, zunächst angesparte Resets. Sie sind keine Verbrauchsmesswerte. Jeder Eintrag beschreibt Anbieter, Konto, stabile Vorteils-ID, Typ, Status, betroffene Limits und die belegte Wirkung. Ein Reset kann beispielsweise nur ein Kurzzeitlimit oder ein Wochenlimit betreffen. Die App leitet seine Wirkung nicht allein aus dem Namen ab.

Zeitangaben werden getrennt modelliert: Vergabe, mögliche Einlösung, Ablauf und nächste Verfügbarkeit. Eine nächste Verfügbarkeit ist kein Ablaufdatum. Ablauf hat drei Zustände: konkreter Zeitpunkt, ausdrücklich unbegrenzt oder unbekannt. Zusätzlich werden Datenquelle, letzter Prüfzeitpunkt und Vollständigkeit des Bestands gespeichert. Eine gemeldete Gesamtzahl kann größer als die Liste gelieferter Einzelheiten sein.

Codex liefert im dokumentierten App Server optionale `rateLimitResetCredits` mit Gesamtzahl und gegebenenfalls einzelnen IDs, Status und `expiresAt`. Fehlende Einzelheiten erlauben eine Bestandsanzeige, aber keine erfundenen Ablaufwarnungen. Claude bestätigt zeitlich begrenzte Reset-Angebote mit unterschiedlichem Geltungsbereich; eine geeignete automatisch lesbare Quelle für deren Ablaufdaten ist noch offen. Details stehen in [usage-research.md](usage-research.md).

Für einen neuen Anbieter mit bekanntem Vorteilsformat übernimmt die gemeinsame Oberfläche Darstellung und Ablaufwarnungen. Neue Bedeutung oder Einlöseregeln erfordern weiterhin eine explizite Abbildung im Anbietermodul. Fähigkeiten für Vorteilsbestand und Ablaufdaten werden unabhängig von normalen Kontolimits ausgewiesen.

Die erste Version erinnert an die Einlösung und öffnet die passende Anbieterseite. Sie verbraucht keinen Reset automatisch. Falls ein Anbieter noch keine lesbaren Ablaufdaten liefert, kann ein ausdrücklich als manuell markierter Eintrag mit Datum und Uhrzeit dieselben Erinnerungen nutzen. Er darf nicht als aktuell vom Anbieter bestätigter Bestand erscheinen.

## Änderungen erkennen und abbilden

| Änderung | Verhalten |
| --- | --- |
| Neues Limit in einer bekannten Liste | Adapter normalisiert es; UI erzeugt eine zusätzliche Zeile ohne eigenen Frontend-Code. |
| Andere Dauer, Reset-Zeit oder Modellbezeichnung | Datengetriebene Darstellung; Identität bleibt unabhängig vom Label. |
| Neues optionales Feld | Parser toleriert es. Nur bekannte Bedeutung wird ausgewertet. |
| Erforderliches Feld fehlt oder hat falschen Typ | Betroffenen Messwert als inkompatibel markieren; letzten Stand mit Alter behalten. |
| Neues Feld ersetzt ein altes | Explizite Versionsabbildung im betreffenden Adapter, mit Fixture. |
| Neue Authentifizierung oder geänderte Semantik | Adapter aktualisieren; keine automatische Interpretation erfinden. |

Automatische Erkennung ist keine automatische Reparatur beliebiger Schnittstellenänderungen. Prozent und Bruchteil, Sekunden und Millisekunden sowie verbraucht und verbleibend lassen sich nicht zuverlässig allein aus Feldwerten erraten. Ein formal gültiger Wert kann trotzdem eine andere Bedeutung bekommen.

Jeder Adapter validiert erforderliche Felder, Einheiten und plausible Zusammenhänge. Unbekannte Zusatzfelder werden toleriert; bekannte Limit-Sammlungen sind offen erweiterbar. Ein Schemafehler betrifft möglichst nur den beschädigten Messwert. Die Diagnose enthält Feldpfade, Typen, Modulversion und Fehlerklasse, keine Tokens, Cookies, Prompts oder ungefilterten Antworten.

Vertragsfixtures prüfen echte normalisierte Ergebnisse, fehlende Werte, mehrere Limits, Reset-Wechsel und fehlerhafte Antworten. CI kann Änderungen veröffentlichter SDK-Schemata prüfen und einen Prüfbedarf melden. Provider-Livechecks benötigen freiwillig bereitgestellte Testkonten; öffentliche CI kann private Abo-Endpunkte nicht vollständig testen. Adapterkorrekturen kommen zunächst mit normalen App-Releases.

## Warnungen

- Bei Überschreiten von 50 Prozent Verbrauch einmal pro Konto, Messwert und Reset-Periode benachrichtigen. Schwellen sind konfigurierbar.
- Gleichmäßiger Verbrauch: Bei bekanntem festem Zeitraum gilt `Soll = 100 × vergangene Zeit / Gesamtdauer`. Beispiel: 40 Prozent der Zeit vergangen und 55 Prozent verbraucht bedeutet 15 Prozentpunkte über Soll. Eine einstellbare Toleranz und Startphase verhindern sofortige Warnungen bei kleinen ersten Verbrauchssprüngen. Arbeitszeiten und Wochentage können später die Sollkurve ersetzen.
- Prognose: Aus mehreren aktuellen Messungen im selben Fenster eine geglättete Verbrauchsrate ableiten. Warnen, wenn das Limit voraussichtlich innerhalb des konfigurierten Horizonts, zunächst zwei Stunden, und vor dem nächsten Reset erreicht wird. Optional kann derselbe Ansatz vor einer künftigen Überschreitung der Sollkurve warnen.
- Bei unklaren gleitenden Fenstern, veralteten Daten, zu wenigen Messungen oder fehlender Aktivität keine scheinpräzise Prognose ausgeben. Reset und Planwechsel unterbrechen die bisherige Zeitreihe.
- Warnzustand über Neustarts speichern. Zusammenfallende Warnungen bündeln; erneute Tempo-Warnungen erst nach Erholung und einer Wartezeit. Ton, Systembenachrichtigung, Ruhezeiten und Snooze sind einstellbar.
- Ablaufwarnungen für angesparte Resets: konfigurierbare Vorlaufzeiten, als Vorschlag drei Tage, ein Tag und ein letzter Hinweis vor dem Ablauf. Meldungen nennen Konto, Wirkung und den genauen lokalen Ablaufzeitpunkt, etwa "Claude-Wochenreset läuft morgen um 09:00 ab". "Heute Nacht" ist eine Anzeigetext-Variante, keine Annahme über Mitternacht.
- Ablaufwarnungen laufen auch ohne neue Verbrauchsmessung über einen lokalen Zeitplan. Vor Zustellung den Bestand nach Möglichkeit aktualisieren. Bei unbekanntem aktuellem Bestand nur eine als letzter bekannter Stand gekennzeichnete Erinnerung; bestätigte Einlösung oder Rücknahme entfernt geplante Erinnerungen. Fehlende optionale Daten allein belegen keine Einlösung.
- Erinnerungen nach Anbieter, Konto, Vorteils-ID, Ablaufrevision und Warnstufe deduplizieren. Nach Ruhezustand nur den dringendsten noch sinnvollen Hinweis senden. Zeitzonenwechsel und Sommerzeit verändern die lokale Anzeige, nicht den gespeicherten Ablaufzeitpunkt. Bei ausdrücklich bestätigter Verlängerung den Zeitplan neu berechnen. Ruhezeiten sollen den letzten Hinweis bei Bedarf auf einen früheren erlaubten Zeitpunkt verschieben, nicht unbemerkt hinter den Ablauf.

Die Auswertung ist ein Modul ohne Netzwerkzugriff. Sie erhält Kontostände samt Vorteilen, Verlauf, Regeln, bisherigen Warnzustand und aktuelle Zeit. Sie liefert Anzeigezustand, Warnereignisse, nächste Auswertungszeit und neuen Warnzustand. So lassen sich Reset, Ablauf, Offline-Zeiten und Neustarts gezielt testen. Der Scheduler übernimmt erforderliche Aktualisierungen, das Betriebssystemmodul die Zustellung unter Beachtung der Benachrichtigungseinstellungen.

## Laufzeit und Oberfläche

Die zunächst vorgeschlagene plattformübergreifende Variante verwendet Tauri 2, Rust für Hintergrundarbeit und Auswertung, React/TypeScript für Popover und Nutzungsansicht sowie SQLite für begrenzte lokale Historie. Darin verwaltet der Rust-Kern das Tray; Webviews entstehen erst bei Bedarf und können nach Schließen freigegeben werden. Die native Mac-Alternative verwendet SwiftUI/AppKit ohne Webview. Die Auswahl bleibt bis zur Anbieter- und Laufzeitprüfung offen. Anbieter-Helfer werden in allen Varianten in Ressourcenmessungen mitgezählt.

Als Ausgangswert für geeignete Quellen dienen Abfragen etwa alle 60 Sekunden bei Aktivität und alle fünf Minuten im Leerlauf. Dokumentierte Anbietergrenzen gehen vor. Ereignisse ergänzen das Polling, wenn die Quelle sie tatsächlich liefert. Ereignisse eines Prozesses ersetzen keine kontoweite Aktualisierung aus anderen Programmen. Jede Anzeige zeigt ihre letzte erfolgreiche Aktualisierung.

Die Übersicht ordnet nach Konto. Darunter stehen Limits mit Sollmarkierung, Reset und optionaler Prognose sowie Guthaben und Ausgaben. Verfügbare Resets erscheinen mit Wirkung und Ablauf, nach Dringlichkeit sortiert. Das Tray zeigt einen gewählten Messwert oder das aktuell kritischste Limit mit erkennbarer Zuordnung. Prozentwerte verschiedener Konten werden nicht zu einem Gesamtverbrauch verrechnet.

macOS kann zusätzlich Prozenttext neben dem Icon zeigen. Windows verwendet ein dynamisches Icon mit Tooltip und Menü. Linux benötigt ein Menü als verlässlichen Zugang zur Detailansicht, da Tauri dort keine Tray-Mausereignisse liefert; die konkrete Desktop-Umgebung muss getestet werden. Native Benachrichtigungen und Ton werden auf installierten Paketen geprüft.

## Erste Umsetzungsschritte

1. Codex- und Claude-Abfragen als kleine Machbarkeitsprüfung: Authentifizierung, Aktualität, Nutzung aus anderen Programmen, Versionen und Ressourcenverbrauch. Keine Modellanfragen nur zur Messung auslösen.
2. Gemeinsames Interface mit beiden realen Adaptern prüfen. Claude-Zugriff ohne laufende Sitzung ist eine explizite Prüffrage, kein bereits belegtes Versprechen.
3. Tray, Kontokarten und Warnregeln implementieren. Einen längeren Lauf mit Offline/Online, Ruhezustand, Reset und wiederholtem Öffnen/Schließen prüfen; CPU, Speicher, Prozesszahl und Abfragezahl messen.
4. OpenCode Go und Zen ergänzen, danach API-Budgets und lokale Nutzungshistorie. Den Umfang der verfügbaren Zen-Kontodaten separat verifizieren.
5. Öffentliche Beispiele, Adapteranleitung, synthetische Demodaten und Plattformtests ergänzen. Eine permissive Open-Source-Lizenz ist vorgesehen, aber noch nicht festgelegt.

Quellen und Integrationsbefunde stehen in [usage-research.md](usage-research.md). Plattformgrundlagen: [Tauri-Prozessmodell](https://v2.tauri.app/concept/process-model/), [Tray-API](https://v2.tauri.app/reference/javascript/api/namespacetray/), [Tray-Ereignisse](https://v2.tauri.app/learn/system-tray/), [Benachrichtigungen](https://v2.tauri.app/plugin/notification/).
