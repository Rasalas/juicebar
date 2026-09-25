# Aktivität und Kontingente

Die Nutzungsseite zeigt standardmäßig Codex, Claude und OpenCode gemeinsam. Ein Filter grenzt die Werkzeuge ein. Der Tagesverlauf umfasst 30 oder 90 Tage und schaltet zwischen Tokens und Modellantworten um. Der Kalender zeigt 90 Tage mit Antworten als Intensität und einer anklickbaren Tagesaufschlüsselung. Datumsgrenzen richten sich nach der lokalen Zeitzone.

Kontingent-Prozente kommen weiterhin direkt vom Anbieter. Die 24-Stunden-Kurve besteht aus Juicebars gespeicherten Abfragen seit dem ersten Start. Eine flache Linie bedeutet einen gleich gebliebenen gemeldeten Stand. Tokens können Abo-Prozente nicht verlässlich rekonstruieren. Diese Kurve steht separat unterhalb des Aktivitätsverlaufs, jetzt mit allen Konten und benannten Limits.

## Lokale Logs

Der manuelle Import liest Codex `sessions` und `archived_sessions`, Claude `projects` sowie die OpenCode-SQLite-Datenbank ausschließlich lesend. Zusätzliche lokale Profile der eingerichteten Codex-/Claude-Konten werden berücksichtigt. Er importiert Nutzungsdaten der letzten 90 Tage. Große JSONL-Dateien werden gestreamt, einzelne Zeilen auf 4 MB begrenzt. Noch nicht abgeschlossene Zeilen werden beim nächsten Import erneut geprüft. Der Import läuft mit Utility-Priorität außerhalb des UI-Threads und ist abbrechbar.

Pro unveränderter Datei liegt ein binärer Metadaten-Cache unter `~/Library/Application Support/Juicebar/activity-cache`. Dateigröße und Änderungsdatum entscheiden über eine erneute Verarbeitung. Es werden nur gehashte Ereignis-IDs, Datum, Quelle, Modell/Anbieter und Tokenzahl gespeichert. Kein Prompt, Antworttext, Tool-Inhalt oder Klartext-Dateipfad. Geänderte Dateien werden erneut gestreamt. Foundation-Zwischenobjekte werden pro Zeile freigegeben. Alte, nicht mehr relevante Cache-Einträge werden entfernt.

Codex verwendet bevorzugt `token_usage_record` mit Response-ID. Das ältere `token_count`-Format wird bis zum Beginn der modernen Aufzeichnung im jeweiligen Log ausgewertet. Wiederholte kumulative Stände zählen nicht erneut. Cache-Input ist bei Codex bereits in Input enthalten, Reasoning in Output. Claude addiert normalen Input, Cache-Read, Cache-Write und Output; wiederholte Message/Request-Blöcke zählen einmal mit dem größten gemeldeten Stand. Führende kopierte Codex-Fork-Historie wird nach dem in T3/ccusage verwendeten Zeitabstand erkannt. Alte Fork-Formate ohne IDs bleiben eine mögliche Quelle von Ungenauigkeit. Die Implementierung ist eigenständig; die [T3-Parser](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/usage/usageTranscripts.ts) dienen als Referenz.

OpenCode liest beide bekannten Tabellen mit maximal 100.000 Zeilen pro Tabelle. Gleiche Nachrichten-IDs werden dedupliziert. Die Grenze wird bei Erreichen angezeigt. Abrechnungsdaten werden nicht zu den Log-Tokens addiert, um Doppelzählungen zu vermeiden. Logs erlauben keine verlässliche Zuordnung zu bestimmten Abos. Andere Geräte ohne SSH-Konfiguration und gelöschte Logs fehlen im Verlauf.

## SSH

Unter Nutzung → Weitere Rechner einen bereits funktionierenden SSH-Alias hinzufügen, beispielsweise `workstation`, dann Aktualisieren. Auf dem Ziel muss Python 3 vorhanden sein. SSH benutzt Schlüsselanmeldung und die vorhandene lokale SSH-Konfiguration. Passwortdialoge, neue Host-Key-Bestätigungen, Port-/Agent-/X11-Forwarding und LocalCommand sind ausgeschaltet. Es wird nichts auf dem Ziel installiert oder geschrieben.

Ein gebündeltes Python-Skript läuft über SSH-stdin und liest die Standardpfade. `CODEX_HOME`, `CLAUDE_CONFIG_DIR` und `XDG_DATA_HOME` werden auf dem Ziel berücksichtigt, sofern sie in der SSH-Sitzung gesetzt sind. Übertragen werden ausschließlich ausgewählte Usage-Felder, Zeitpunkte und IDs/Modellnamen. Gesprächsinhalte und Projektpfade verlassen den Zielrechner nicht. Die Swift-Normalisierung ist lokal und remote dieselbe. Stabile Response-/Message-IDs verhindern Doppelzählungen bei synchronisierten Kopien über mehrere Rechner.

SSH läuft ausschließlich beim manuellen Import, mit maximal drei Minuten und 128 MB Metadatenausgabe je Host. Entfernte Logs werden dabei neu gelesen. Fehler lassen die übrigen Quellen nutzbar und markieren den gemeinsamen Verlauf sichtbar als unvollständig. Bei fehlgeschlagenem SSH-Import wird kein alter Remote-Stand in eine aktuelle Summe gemischt.

Prüfung ohne GUI:

```sh
swift run Juicebar --diagnose-activity --ssh=workstation
python3 Tests/ssh_usage_test.py
```

## Darstellung

Balken und Zahlen zeigen standardmäßig verbleibenden Vorrat. Einstellungen → Darstellung erlaubt alternativ den verbrauchten Anteil. Warnregeln arbeiten unverändert mit verbrauchten Prozenten. Die Gläser zeigen immer den verbleibenden Anteil.

Die Menüleiste zeigt standardmäßig jedes aktivierte Konto. Je Konto bestimmt das am stärksten verbrauchte gültige Limit den Füllstand. Die Beschriftung nennt Konto, Fenster und Rest, beispielsweise `CX W 80%`. `W` bedeutet Woche, `5h` fünf Stunden; ein Punkt kennzeichnet einen alten Stand. Ein unbekanntes Limit erscheint mit `?`. Alternativ lassen sich nur Gläser mit Kontokürzel oder ein gezieltes Konto/Limit auswählen. Die System-Menüleiste verwendet kontrastreiche monochrome Symbole; im Fenster gelten die Anbieterfarben.
