# Nutzungsverlauf und API-Gegenwert

Der Import startet beim App-Start und danach fünf Minuten nach dem letzten Import. Ein laufender Import wird nicht doppelt gestartet. Pause und Ruhezustand stoppen den Worker. Gespeicherte Tageswerte sind sofort nach einem Neustart sichtbar. OpenCode- und SSH-Archive erhalten Nutzungsmetadaten bei Ausfällen; entfernte SSH-Hosts werden nicht mehr addiert. Lokale Dateicaches behalten bereits erfasste Metadaten gelöschter Chats bis zum Ende des 90-Tage-Zeitraums. Kein Cache enthält Gesprächsinhalte.

JSONL wird begrenzt und nur lesend verarbeitet. Gültige Zeilen bis 32 MiB werden berücksichtigt, bekannte übergroße Gesprächs-/Kompaktionszeilen ignoriert. Unvollständige letzte Zeilen werden beim nächsten Schreibvorgang erneut geprüft. Unlesbare Nutzungsdaten werden separat gemeldet; keine fremden Logs werden verändert.

Claude bereinigt Transkripte standardmäßig nach 30 Tagen. `stats-cache.json` bleibt erhalten. Tagesstatistiken werden ausschließlich für Tage ohne detaillierte Claude-Antworten ergänzt. Damit werden Tagesaggregate nicht mit einzelnen Antworten vermischt oder doppelt gezählt. Die Statistik enthält auch Nutzer- und Werkzeugnachrichten; sie wird entsprechend beschriftet. Token-Tageswerte werden nur für die bekannte Statistikversion 5 übernommen. Ohne Token-Arten gibt es keinen verlässlichen API-Gegenwert.

Preise sind der theoretische Gegenwert zu aktuellen Standardpreisen, Stand 25.09.2026, keine historische Rechnung. `APICost.swift` enthält explizite Modelle und Datumssuffixe; unbekannte Modelle bleiben unbepreist. Neue Modelle werden nicht nach Namensähnlichkeit geraten. Input, Output inklusive Reasoning, Cache-Lesen und Cache-Schreiben werden getrennt berechnet. Codex zählt Cache im Input, Claude und OpenCode führen ihn separat. Claude meldet teils 1h-Cache-Schreiben; fehlt dessen Dauer, wird 5m angenommen. Lange Kontexte werden pro Antwort berücksichtigt, soweit die Logs die nötigen Werte enthalten. Fast-Modus, regionale Zuschläge, Steuern, Batch-Rabatte und Toolgebühren fehlen bewusst im Standardvergleich. OpenCode Go-Modelle verwenden, sofern bekannt, den veröffentlichten Zen-API-Preis. Bestätigte Modell-Enthüllungen stehen mit Provider-Zuordnung, Quelle und Prüfdatum in `Sources/JuicebarCore/Resources/model-aliases.json`. Ox Alpha wird GLM-5.3-Flash zugeordnet, Union Alpha wird Unbiased Pareto zugeordnet. Weitere bestätigte Aliase werden dort ergänzt; das Zielmodell braucht außerdem einen belegten Eintrag im Preiskatalog. Nach einem Katalog-Update berechnet der automatische Import die gesamten 90 Tage aus den ursprünglichen Nutzungsmetadaten neu, einschließlich zwischengespeicherter und archivierter Einträge. Originalnamen, IDs und tatsächlich gemeldete Kosten bleiben unverändert. Nicht bestätigte Alpha-/Gratis-Aliase bleiben unbepreist. Es gibt keinen automatischen Web-Scraper für Modellgerüchte.

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
