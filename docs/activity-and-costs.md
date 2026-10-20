# Nutzungsverlauf und API-Gegenwert

Der Import startet beim App-Start und danach fünf Minuten nach dem letzten Import. Ein laufender Import wird nicht doppelt gestartet. Pause und Ruhezustand stoppen den Worker. Gespeicherte Tageswerte sind sofort nach einem Neustart sichtbar. OpenCode- und SSH-Archive erhalten Nutzungsmetadaten bei Ausfällen; entfernte SSH-Hosts werden nicht mehr addiert. Lokale Dateicaches behalten bereits erfasste Metadaten gelöschter Chats bis zum Ende des 90-Tage-Zeitraums. Kein Cache enthält Gesprächsinhalte.

JSONL wird begrenzt und nur lesend verarbeitet. Gültige Zeilen bis 32 MiB werden berücksichtigt, bekannte übergroße Gesprächs-/Kompaktionszeilen ignoriert. Unvollständige letzte Zeilen werden beim nächsten Schreibvorgang erneut geprüft. Unlesbare Nutzungsdaten werden separat gemeldet; keine fremden Logs werden verändert.

Claude bereinigt Transkripte standardmäßig nach 30 Tagen. `stats-cache.json` bleibt erhalten. Tagesstatistiken werden ausschließlich für Tage ohne detaillierte Claude-Antworten ergänzt. Damit werden Tagesaggregate nicht mit einzelnen Antworten vermischt oder doppelt gezählt. Die Statistik enthält auch Nutzer- und Werkzeugnachrichten; sie wird entsprechend beschriftet. Token-Tageswerte werden nur für die bekannte Statistikversion 5 übernommen. Ohne Token-Arten gibt es keinen verlässlichen API-Gegenwert.

Pi verwendet zuerst die im Log gespeicherte Schätzung `usage.cost.total`. Cline SDK, Roo und Kilo übernehmen ebenfalls ihre protokollierten Kosten, einschließlich eines expliziten Nullwerts. Fehlt eine Kostenschätzung, gilt derselbe Preiskatalog wie für andere Quellen. Pi-Tool-Ergebnisse und Cache-Warming tragen Tokens bei, ohne die Antwortanzahl zu erhöhen. Bei Abo-Anbietern bleiben Pi-Kosten ein API-Gegenwert, keine Rechnung. Details zu Pfaden und Forks stehen unter [Aktivitätsquellen](activity-history.md#pi-und-zusätzliche-ordner).

Katalogpreise sind der theoretische Gegenwert zu Standardpreisen, keine historische Rechnung. `Resources/model-catalog.json` enthält explizite Modelle und das Prüfdatum je Eintrag; `APICost.swift` berücksichtigt Datumssuffixe. Unbekannte Modelle bleiben unbepreist. Neue Modelle werden nicht nach Namensähnlichkeit geraten. Input, Output inklusive Reasoning, Cache-Lesen und Cache-Schreiben werden getrennt berechnet. Codex zählt Cache im Input, Claude und OpenCode führen ihn separat. Claude meldet teils 1h-Cache-Schreiben; fehlt dessen Dauer, wird 5m angenommen. Lange Kontexte werden pro Antwort berücksichtigt, soweit die Logs die nötigen Werte enthalten. Fast-Modus, regionale Zuschläge, Steuern, Batch-Rabatte und Toolgebühren fehlen bewusst im Standardvergleich. OpenCode Go-Modelle verwenden, sofern bekannt, den veröffentlichten Zen-API-Preis. Bestätigte Modell-Enthüllungen stehen mit Provider-Zuordnung, Quelle und Prüfdatum in `Sources/JuicebarCore/Resources/model-catalog.json`. Ox Alpha wird GLM-5.3-Flash zugeordnet, Union Alpha wird Unbiased Pareto zugeordnet. Weitere bestätigte Aliase werden dort ergänzt; das Zielmodell braucht außerdem einen belegten Eintrag im Preiskatalog. Nach einem Katalog-Update berechnet der automatische Import die gesamten 90 Tage aus den ursprünglichen Nutzungsmetadaten neu, einschließlich zwischengespeicherter und archivierter Einträge. Originalnamen, IDs und tatsächlich gemeldete Kosten bleiben unverändert. Nicht bestätigte Alpha-/Gratis-Aliase bleiben unbepreist. Es gibt keinen automatischen Web-Scraper für Modellgerüchte.

Quellen:
- https://developers.openai.com/api/docs/pricing
- https://developers.openai.com/api/docs/models/gpt-6-astra
- https://developers.openai.com/api/docs/models/gpt-5.6-sol
- https://developers.openai.com/api/docs/models/gpt-5.6-terra
- https://developers.openai.com/api/docs/models/gpt-5.6-luna
- https://developers.openai.com/api/docs/models/gpt-5.5
- https://developers.openai.com/api/docs/models/gpt-5.4-mini
- https://developers.openai.com/api/docs/guides/prompt-caching
- https://platform.claude.com/docs/en/about-claude/pricing
- https://opencode.ai/docs/zen/
- https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/session.ts
- https://code.claude.com/docs/en/claude-directory

Prüfung: `swift test`, `python3 Tests/ssh_usage_test.py`, `swift run Juicebar --verify-activity-persistence`, `swift run Juicebar --verify-tray-layout`. Der Persistenztest öffnet einen neuen AppStore mit isolierter Datenbank und prüft Nutzungswerte samt Kosten vor jedem Netzwerkzugriff.

Alias-Quellen:
- https://openrouter.ai/stealth/ox-alpha
- https://openrouter.ai/stealth/union-alpha
- https://openrouter.ai/unbiased/pareto

Weitere Werkzeuge, Versionen und Speicherpfade stehen unter [Aktivitätsquellen](activity-history.md#weitere-werkzeuge).

## Wochenreichweite

Claude und Codex begrenzen Nutzung in 5-Stunden-Fenstern und pro Woche. Jedes 5-Stunden-Fenster deckt nur einen Teil der Woche ab. Kurz vor dem Wochenreset kann deshalb mehr Wochenrest übrig sein, als die verbleibenden Fenster noch verbrauchen können. `WeeklyReach.swift` schätzt das ohne Netzwerkzugriff:

- Verhältnis: Wochenprozent je 5-Stunden-Prozent aus dem gespeicherten Verlauf desselben Kontos und derselben Anmeldung der letzten 14 Tage. Es zählen nur aufeinanderfolgende Messungen, bei denen beide Fenster im selben Zeitraum blieben. Summiert wird, nicht gemittelt, weil Anbieter ganze Prozent melden. Unter 60 Prozentpunkten im 5-Stunden-Fenster gibt es keine Schätzung. Modell- oder App-bezogene Wochenlimits bewegen sich nur mit einem Teil der Nutzung und brauchen mindestens 10 Wochenpunkte. Der Speicher hält 30 Tage pro Konto, also auch die vorige Woche vollständig. Älter als einen Tag werden Messungen ausgedünnt: Liegt eine Messung zwischen zwei mit gleichen Prozenten im selben Zeitraum, fällt sie weg, weil sie keine Differenz und keine Stufe im Diagramm ändert. Höchstens 10.000 Messungen pro Konto bleiben; geladen werden die 14 Tage, die die Schätzung liest.
- Nutzbare Stunden: Eine Stunde gilt als nutzbar, wenn die lokalen Logs desselben Anbieters an mindestens 20 % der aktiven Tage der letzten 28 Tage dort Aktivität zeigen. Bei weniger als sieben aktiven Tagen gelten die Ruhezeiten aus den Warnungen, ohne Ruhezeiten alle Stunden.
- Fenster bis zum Wochenreset: der Rest des aktuellen Fensters, danach je ein volles Fenster ab der nächsten nutzbaren Stunde. Das letzte zählt anteilig bis zum Reset.
- Reicht die Kapazität nicht, zeigt der Wochenbalken den Teil, der auch bei voller Nutzung verfällt. Braucht die Woche mindestens 70 % der Kapazität, zeigt der 5-Stunden-Balken das Wochenziel: wie weit dieses Fenster genutzt werden sollte, damit die Woche über alle nutzbaren Fenster gleichmäßig aufgeht.

Alle Werte sind Näherungen („≈“). Wie viel Woche ein volles Fenster ausmacht, wird direkt aus den gemeldeten Limitständen ermittelt. Es gibt keinen zusätzlichen Faktor für Modellkosten oder Modellmix. Veraltete Messungen, fehlende Resetzeiten oder ein Abruffehler blenden die Schätzung aus. Warnungen gibt es dafür noch nicht.

Die Rechnung verwendet `r = Summe Wochenanstieg / Summe 5-Stunden-Anstieg` und `W = aktueller 5-Stunden-Rest / 100 + zukünftige nutzbare Fenster`. Damit ist die geschätzte Kapazität `K = 100 × r × W` in Wochenprozentpunkten. Bei Wochenrest `R` bleiben `max(0, R − K)` Prozentpunkte ungenutzt. Die übrigen `min(R, K)` setzen volle Nutzung der eingeplanten Kapazität voraus. Bei 83 % Wochenrest und ungefähr 36 Prozentpunkten Verfall sind also noch ungefähr 47 Prozentpunkte nutzbar.

Das ist keine mathematisch sichere Obergrenze des Anbieters. Die Rechnung berücksichtigt übliche Startstunden, setzt das gemessene Verhältnis der Limitstände fort und gewichtet ein letztes verkürztes Fenster linear nach seiner Dauer. Zusätzliche Nutzungszeiten oder schnellerer Verbrauch in diesem letzten Fenster können das Ergebnis verändern.

Wenn beide Limits denselben Verbrauch mit derselben Modellgewichtung zählen, kürzt sich diese Gewichtung im Verhältnis heraus. Dass ein Modell mehr Kontingent verbraucht, beweist deshalb keine Änderung dieses Verhältnisses. Die [offizielle Beschreibung der Limits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work) und die [Team-Plan-Dokumentation](https://support.claude.com/en/articles/9266767-what-is-the-team-plan) nennen Session- und Wochenlimits, aber keine feste Umrechnung in beispielsweise 10 oder 20 volle Fenster. Modellbezogene Wochenlimits sind gesondert zu betrachten, weil nur ein Teil der gesamten Nutzung auf sie zählt.

Für das Wochenziel gilt `Auslastung = R / K` und `Zielrest im aktuellen Fenster = aktueller Rest × max(0, 1 − Auslastung)`. Ab 70 % Auslastung erscheint der gefüllte Halbdiamant. Seine untere Ecke markiert den Zielstand horizontal. Beide Markierungen verwenden dasselbe gerundete Rautensymbol in derselben Größe und auf derselben Höhe, mit der Mitte auf der oberen Balkenkante. Für das Wochenziel wird die linke oder rechte Hälfte dieses Symbols eingeblendet, vom Soll-Diamanten weg. Die beiden Ecken an der Schnittkante erhalten ebenfalls eine leichte Rundung; die Markierung behält dieselbe neutrale Farbe wie die Soll-Raute. An den Balkenenden darf das Symbol überstehen, damit der Anker exakt bei 0 beziehungsweise 100 % bleibt. Das Wochenziel kann auf beiden Seiten liegen, weil es vom Wochenrest abhängt, der Sollstand dagegen nur von der verbleibenden Zeit im einzelnen Fenster. Eine zusätzliche Wochenzielzeile unter dem kurzen Balken entfällt; Zielwert und Erklärung stehen in dessen Details, die gemeinsame Symbollegende unter den Konten.
