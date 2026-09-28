# Aktivität und Kontingente

Die Nutzungsseite zeigt standardmäßig Codex, Claude, OpenCode und Pi gemeinsam. Ein Filter grenzt die Werkzeuge ein. Der Tagesverlauf umfasst 30 oder 90 Tage und schaltet zwischen Tokens und Modellantworten um. Der Kalender zeigt 90 Tage mit Antworten als Intensität und einer anklickbaren Tagesaufschlüsselung. Datumsgrenzen richten sich nach der lokalen Zeitzone.

Kontingent-Prozente kommen weiterhin direkt vom Anbieter. Die 24-Stunden-Kurve besteht aus Juicebars gespeicherten Abfragen seit dem ersten Start. Eine flache Linie bedeutet einen gleich gebliebenen gemeldeten Stand. Tokens können Abo-Prozente nicht verlässlich rekonstruieren. Diese Kurve steht separat unterhalb des Aktivitätsverlaufs, jetzt mit allen Konten und benannten Limits.

## Lokale Logs

Der Import startet beim App-Start, danach alle fünf Minuten nach Abschluss sowie manuell. Er liest Codex `sessions` und `archived_sessions`, Claude `projects`, Pi `~/.pi/agent/sessions` sowie die OpenCode-SQLite-Datenbank ausschließlich lesend. Zusätzliche lokale Profile der eingerichteten Codex-/Claude-Konten werden berücksichtigt. Er importiert Nutzungsdaten der letzten 90 Tage. Große JSONL-Dateien werden gestreamt, einzelne Zeilen auf 32 MiB begrenzt. Noch nicht abgeschlossene Zeilen werden beim nächsten Import erneut geprüft. Der Import läuft mit Utility-Priorität außerhalb des UI-Threads und ist abbrechbar.

Pro unveränderter Datei liegt ein binärer Metadaten-Cache unter `~/Library/Application Support/Juicebar/activity-cache`. Dateigröße und Änderungsdatum entscheiden über eine erneute Verarbeitung. Es werden nur gehashte Ereignis-IDs, Datum, Quelle, Modell/Anbieter, Token-Arten und Tokenzahl gespeichert. Bei Pi kommen die gemeldete Kostenschätzung, Antwortanzahl und Sitzungsbeginn für die Fork-Entdoppelung hinzu. Kein Prompt, Antworttext, Tool-Inhalt oder Klartext-Dateipfad. Geänderte Dateien werden erneut gestreamt. Foundation-Zwischenobjekte werden pro Zeile freigegeben. Alte, nicht mehr relevante Cache-Einträge werden entfernt.

Codex verwendet bevorzugt `token_usage_record` mit Response-ID. Das ältere `token_count`-Format wird bis zum Beginn der modernen Aufzeichnung im jeweiligen Log ausgewertet. Wiederholte kumulative Stände zählen nicht erneut. Cache-Input ist bei Codex bereits in Input enthalten, Reasoning in Output. Claude addiert normalen Input, Cache-Read, Cache-Write und Output; wiederholte Message/Request-Blöcke zählen einmal mit dem größten gemeldeten Stand. Führende kopierte Codex-Fork-Historie wird nach dem in T3/ccusage verwendeten Zeitabstand erkannt. Alte Fork-Formate ohne IDs bleiben eine mögliche Quelle von Ungenauigkeit. Die Implementierung ist eigenständig; die [T3-Parser](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/usage/usageTranscripts.ts) dienen als Referenz.

OpenCode liest beide bekannten Tabellen mit maximal 100.000 Zeilen pro Tabelle. Gleiche Nachrichten-IDs werden dedupliziert. Die Grenze wird bei Erreichen angezeigt. Abrechnungsdaten werden nicht zu den Log-Tokens addiert, um Doppelzählungen zu vermeiden. Logs erlauben keine verlässliche Zuordnung zu bestimmten Abos. Andere Geräte ohne SSH-Konfiguration und gelöschte Logs fehlen im Verlauf.

## Pi und zusätzliche Ordner

Unter Nutzung → Zusätzliche Log-Ordner ein Format auswählen und einen Ordner hinzufügen. Die Formate Codex, Claude und Pi werden rekursiv gelesen. Tau-Sitzungen verwenden das Pi-Format und erscheinen unter Pi. OpenCode hat weiterhin eine eigene Datenbankauswahl. Die Ordnerauswahl gilt für diesen Mac.

Die Standardpfade berücksichtigen `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `PI_CODING_AGENT_DIR` und `PI_CODING_AGENT_SESSION_DIR`, sofern sie beim Start von Juicebars gesetzt sind. Bei Pi hat `PI_CODING_AGENT_SESSION_DIR` Vorrang vor `<PI_CODING_AGENT_DIR>/sessions`, ansonsten gilt `~/.pi/agent/sessions`. Eine über Finder gestartete App erbt keine Variablen aus der Shell-Konfiguration. Abweichende Pfade aus Pis `--session-dir` oder `sessionDir` lassen sich über die Ordnerauswahl hinzufügen.

Manuelle Ordner werden mit automatisch gefundenen Pfaden zusammengeführt. Standardisierte Pfade einschließlich symbolischer Verzeichnisverweise zählen einmal; überlappende Ordner lesen dieselbe Datei nur einmal. Antwort-IDs verhindern eine weitere Zählung kopierter Einträge. Erkennt eine spätere Version denselben Ordner automatisch, bleibt die manuelle Einstellung erhalten, ohne eine zweite Datenquelle zu erzeugen. Das Entfernen einer Einstellung beendet weitere Importe aus diesem zusätzlichen Ordner. Bereits importierte Metadaten bleiben innerhalb der 90 Tage erhalten. Automatisch erkannte Standardordner bleiben aktiv.

Pi liest `message`-Einträge mit `assistant` oder `toolResult`, `compaction`, `branch_summary` und eigenständige `usage`-Einträge. Cache-Tokens sind getrennte Mengen und werden einmal addiert. Tool-Ergebnisse und eigenständige Usage-Einträge tragen keine zusätzliche Modellantwort bei. Provider und Modell stammen aus der Antwort; Zusammenfassungen ohne eigene Modellangabe übernehmen die letzte Antwort. Nachrichtenzeitpunkte sind Millisekunden, Eintragszeitpunkte ISO-Zeitstempel.

Kopierte Pi-Einträge werden anhand ihrer ID und ihres Zeitpunkts zusammengeführt. Bei Abweichungen gewinnt die älteste Sitzung, unabhängig von Dateireihenfolge, Cache oder SSH-Host. Dafür wird der Sitzungsbeginn aus dem Header gespeichert. Ohne Eintrags-ID bleibt die Entdoppelung auf die jeweilige Datei beschränkt. Pis `usage.cost.total` ist die bevorzugte API-Kostenschätzung. Fehlende Kosten werden mit dem vorhandenen Preiskatalog berechnet; unbekannte Modelle ohne Kostenschätzung bleiben unbepreist. Auch bei `openai-codex` und Claude-Abos sind diese Werte keine Rechnung und keine Abo-Prozente.

Format geprüft am 28. September 2026 anhand der [Pi-Sitzungstypen](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/session-manager.ts), der [Pi-Sitzungsdokumentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md) und [Taus Usage-Reader](https://github.com/Rasalas/tau/blob/main/kits/usage/pi-sessions.ts). Tests verwenden synthetische Sitzungen.

## SSH

Unter Nutzung → Weitere Rechner einen bereits funktionierenden SSH-Alias hinzufügen, beispielsweise `workstation`, dann Aktualisieren. Auf dem Ziel muss Python 3 vorhanden sein. SSH benutzt Schlüsselanmeldung und die vorhandene lokale SSH-Konfiguration. Passwortdialoge, neue Host-Key-Bestätigungen, Port-/Agent-/X11-Forwarding und LocalCommand sind ausgeschaltet. Es wird nichts auf dem Ziel installiert oder geschrieben.

Ein gebündeltes Python-Skript läuft über SSH-stdin und liest die Standardpfade. `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `XDG_DATA_HOME`, `PI_CODING_AGENT_DIR` und `PI_CODING_AGENT_SESSION_DIR` werden auf dem Ziel berücksichtigt, sofern sie in der SSH-Sitzung gesetzt sind. Übertragen werden ausschließlich ausgewählte Usage-Felder, Zeitpunkte und IDs/Modellnamen. Gesprächsinhalte und Projektpfade verlassen den Zielrechner nicht. Die Swift-Normalisierung ist lokal und remote dieselbe. Stabile Response-/Message-IDs verhindern Doppelzählungen bei synchronisierten Kopien über mehrere Rechner.

SSH läuft bei jedem automatischen oder manuellen Import, mit maximal drei Minuten und 128 MB Metadatenausgabe je Host. Entfernte Logs werden dabei neu gelesen. Fehler lassen die übrigen Quellen nutzbar und markieren den gemeinsamen Verlauf sichtbar als unvollständig. Bei fehlgeschlagenem SSH-Import bleibt der letzte erfolgreiche Stand erhalten und wird mit seinem Zeitpunkt als Warnung ausgewiesen.

Prüfung ohne GUI:

```sh
swift run Juicebar --diagnose-activity --ssh=workstation
python3 Tests/ssh_usage_test.py
```

## Darstellung

Balken und Zahlen zeigen standardmäßig verbleibenden Vorrat. Einstellungen → Darstellung erlaubt alternativ den verbrauchten Anteil. Warnregeln arbeiten unverändert mit verbrauchten Prozenten. Die Gläser zeigen immer den verbleibenden Anteil.

Die Menüleiste zeigt standardmäßig jedes aktivierte Konto. Je Konto bestimmt das am stärksten verbrauchte gültige Limit den Füllstand. Die Beschriftung nennt Konto, Fenster und Rest, beispielsweise `CX W 80%`. `W` bedeutet Woche, `5h` fünf Stunden; ein Punkt kennzeichnet einen alten Stand. Ein unbekanntes Limit erscheint mit `?`. Alternativ lassen sich nur Gläser mit Kontokürzel oder ein gezieltes Konto/Limit auswählen. Die System-Menüleiste verwendet kontrastreiche monochrome Symbole; im Fenster gelten die Anbieterfarben.
