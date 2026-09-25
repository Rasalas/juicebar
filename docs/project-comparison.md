# Projekte, von denen Juicebar lernen kann

Stand: 25. September 2026. Geprüft wurden konkrete Quellcodedateien, keine laufenden Installationen oder Zugangsdaten. Die genannten Tests wurden gelesen, nicht ausgeführt. Aussagen über niedrigen Ressourcenverbrauch wären erst nach Messungen belastbar.

| Projekt | Besonders hilfreich für Juicebar | Einordnung |
| --- | --- | --- |
| Quotio | Rust-Collector, echte Kontingente, Timeouts, Reset-Guthaben | Direktes technisches Vorbild für den Collector |
| Claude Code Usage Monitor | Quellenqualität, Datenalter, Statusline, Prognosetests | Vorbild für nachvollziehbare Messwerte |
| ccusage | Lokale Nutzungsparser, Deduplizierung, OpenCode-Schemawechsel | Vorbild für die spätere Nutzungsansicht |
| CodexBar | Vorhandene Ablaufwarnungen für Codex-Resets | Einzelne robuste Mechanismen trotz unerwünschtem Gesamtverhalten |

## Quotio

Der aktuelle Stand enthält neben der macOS-Anwendung eine Rust-CLI. Ihr `ProviderAdapter` kapselt Quelle, Konto, Cacheidentität und Abruf. Uhr, HTTP-Client und Zugangsdatenquelle werden übergeben. Das erleichtert Tests ohne echte Anmeldung. Der Adaptervertrag fordert, dass Abbruch auch Netzwerk und Kindprozesse beendet. [Adaptervertrag](https://github.com/nguyenphutrong/quotio/blob/86284d9ed3979e7213fb8085848a7701ac2c7df5/apps/cli/src/providers/mod.rs)

Der Collector setzt ein Gesamtzeitbudget pro Anbieter, einschließlich Wiederholungen und Wartezeiten. Vorübergehende Fehler werden nur für als idempotent markierte Adapter wiederholt, höchstens dreimal insgesamt. Fehler eines Anbieters landen getrennt von erfolgreichen Messwerten im Bericht. [Collector](https://github.com/nguyenphutrong/quotio/blob/86284d9ed3979e7213fb8085848a7701ac2c7df5/apps/cli/src/fetch.rs)

Der gemeinsame HTTP-Code berücksichtigt `Retry-After`, begrenzt Antwortgrößen und unterscheidet Authentifizierung, Drosselung und vorübergehende Fehler. Die Datei enthält Regressionstests auch für fehlerhafte Header. [HTTP-Code und Tests](https://github.com/nguyenphutrong/quotio/blob/86284d9ed3979e7213fb8085848a7701ac2c7df5/apps/cli/src/providers/http.rs)

Codex verwendet `account/rateLimits/read`; zusätzliche private HTTP-Abfragen sind möglich. Claude verwendet den OAuth-Usage-Endpunkt. Diese beiden Zugänge haben unterschiedliche Stabilitäts- und Anmeldeeigenschaften. [Codex-Adapter](https://github.com/nguyenphutrong/quotio/blob/86284d9ed3979e7213fb8085848a7701ac2c7df5/apps/cli/src/providers/codex.rs), [Claude-Abruf](https://github.com/nguyenphutrong/quotio/blob/86284d9ed3979e7213fb8085848a7701ac2c7df5/apps/cli/src/providers/catalog/oauth_primary.rs)

Besonders passend ist der Parser für Codex-Reset-Guthaben. Er trennt die gemeldete Gesamtzahl von der möglicherweise gekürzten Detailliste, filtert nach Status und Resettyp und behandelt fehlende Ablaufdaten ausdrücklich. Tests prüfen diese Fälle. [Reset-Parser und Tests](https://github.com/nguyenphutrong/quotio/blob/86284d9ed3979e7213fb8085848a7701ac2c7df5/apps/cli/src/providers/codex_reset_credits.rs)

Übernehmen würde ich den Adaptervertrag, Zeitbudgets, Abbruchregeln, testbare Uhr und Fehlertrennung. Juicebar braucht zusätzlich eine globale Parallelitätsgrenze; der untersuchte Collector startet die übergebenen Adapter parallel. Proxyverwaltung, Accountumschaltung und automatische Zusatzabfragen gehören nicht automatisch in den Umfang eines Verbrauchsmonitors. Die geprüfte CLI-Lizenz ist MIT. [CLI-Lizenz](https://github.com/nguyenphutrong/quotio/blob/86284d9ed3979e7213fb8085848a7701ac2c7df5/apps/cli/LICENSE)

## Claude Code Usage Monitor

Der Monitor liest offizielle Statusline-Daten ohne Netzwerk und speichert Messzeit und Quellenstatus. Er markiert alte Werte als veraltet, verwirft Prozente nach dem gemeldeten Reset und lehnt unplausible Zahlen ab. Seine Tests behandeln unter anderem genau den Resetzeitpunkt, kaputte JSON-Daten und nicht endliche Zahlen. [Statusline-Leser](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/src/claude_monitor/output/official.py), [Tests](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/src/tests/test_official.py)

Der private OAuth-Endpunkt ist ausdrücklich experimentell und muss aktiviert werden. Der Leser hat einen 180-Sekunden-Cache, zehn Sekunden HTTP-Timeout und speichert `Retry-After`, damit weitere Abrufe warten. Frische offizielle Daten haben Vorrang vor diesem Fallback. [API-Leser](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/src/claude_monitor/output/api_usage.py), [Snapshot-Logik](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/src/claude_monitor/output/snapshots.py)

Gut übertragbar sind Herkunft und Datenalter pro Messwert sowie Tests mit einer kontrollierten Uhr. Zwei Verhaltensweisen würde ich nicht übernehmen: Der API-Leser errät die Prozent-Skalierung aus `Wert <= 1`, was bei einem echten Prozentwert von 0,5 mehrdeutig ist. Außerdem kann die Snapshot-Logik von veralteten offiziellen Daten auf lokale Schätzungen zurückfallen. Juicebar sollte bei Kontingentwarnungen stattdessen "veraltet" oder "unbekannt" anzeigen; lokale Schätzungen bekommen eine eigene Anzeige. [API-Normalisierung](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/src/claude_monitor/output/api_usage.py), [Quellenprioritäts-Tests](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/src/tests/test_snapshots_official.py)

Die geprüfte Projektlizenz ist MIT. [Lizenz](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor/blob/c59a83bf943f329f0e61f1a29c760353ee1860a5/LICENSE)

## ccusage

ccusage ist für lokale Token- und Kostenauswertung relevant. Im untersuchten Stand liegt die Laufzeitlogik in Rust. Ein Adapter pro Client besitzt seine Pfadsuche, Parser und spezielle Token-/Preisbedeutung; gemeinsame Berichte und Aggregation sind getrennt. Diese Grenze passt zu Juicebars Unterscheidung zwischen Clientverlauf und Anbieter-Kontingent. [Adapterstruktur](https://github.com/ccusage/ccusage/blob/15830fb1636f5dccb1b8ca383ce1806a7deb0c9c/rust/adapters/README.md)

Der OpenCode-Leser behandelt SQLite, ältere Datenformen und Ersatzwerte aus Sitzungsaggregaten. Seine Tests prüfen doppelte Legacy-/V2-Nachrichten, Fork-Kopien, mehrere Datenverzeichnisse und die Gefahr, ein kumulatives Sitzungsaggregat fälschlich einem begrenzten Tagesfenster zuzuordnen. [OpenCode-Leser und Tests](https://github.com/ccusage/ccusage/blob/15830fb1636f5dccb1b8ca383ce1806a7deb0c9c/rust/adapters/opencode/src/loader.rs)

Auch die Claude-Tagesauswertung behandelt wiederholte Nachrichten und kopierte Verläufe gezielt. Das ist nützlicher als ein einfacher Summenzähler über jede gefundene JSONL-Zeile. [Claude-Auswertung und Tests](https://github.com/ccusage/ccusage/blob/15830fb1636f5dccb1b8ca383ce1806a7deb0c9c/rust/adapters/claude/src/daily.rs)

Übernehmen würde ich die fachlichen Parserregeln und Testfälle als Referenz für eine eigene Implementierung. Einen vollständigen Report-Prozess bei jedem Tray-Update zu starten wäre keine begründete Wahl; Juicebar braucht inkrementelle Einlesung und Ressourcenmessungen. Diese lokalen Daten belegen kein verbleibendes Abo-Kontingent. Die geprüfte Lizenzdatei des ccusage-Pakets nennt MIT. [Lizenz](https://github.com/ccusage/ccusage/blob/15830fb1636f5dccb1b8ca383ce1806a7deb0c9c/apps/ccusage/LICENSE)

## CodexBar als gezielte Referenz

CodexBar enthält bereits einen `CodexResetCreditExpiryNotifier` mit dreitägigem Vorwarnfenster, dauerhaft gespeicherten Fingerprints und einer begrenzten Historie von 64 Einträgen. Dafür gibt es eigene Tests. Das ist ein konkreter Ausgangspunkt für die neue Ablaufwarnung. [Notifier](https://github.com/steipete/CodexBar/blob/51898f3e5c0435d883a167069bd85ff226846101/Sources/CodexBar/CodexResetCreditExpiryNotifier.swift), [Tests](https://github.com/steipete/CodexBar/blob/51898f3e5c0435d883a167069bd85ff226846101/Tests/CodexBarTests/CodexResetCreditExpiryNotifierTests.swift)

Für Juicebar würde ich die dauerhafte Deduplizierung übernehmen, den Schlüssel aber pro Konto, Guthaben und Warnschwelle führen. Wenn stabile Guthaben-IDs fehlen, muss der Adapter eine nachvollziehbare Ersatzidentität bilden. Eine Änderung der gesamten Guthabenliste sollte nicht alle bereits gemeldeten Warnungen neu auslösen. Claude-Angebote brauchen ihre eigene Semantik und Datenquelle; aus Codex-Feldern folgt dafür nichts.

## Konsequenz für die Umsetzung

Quotio zuerst für den Collector lesen, den Claude-Monitor für Quellenqualität und ccusage für die Nutzungsansicht. CodexBar liefert einzelne relevante Alarmmechanismen. Vor Codeübernahme müssen Lizenzhinweise der konkreten Dateien erhalten bleiben. Keine dieser Quellcodeprüfungen ersetzt einen Dauertest der tatsächlichen CPU-, Speicher- und Prozessnutzung.
