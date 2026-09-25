# Juicebar: Datenquellen und Umsetzungsvorschlag

Stand: 25. September 2026. Recherche und Entwurf, noch keine implementierte Anwendung. Priorität haben ChatGPT/Codex und Claude-Abos, danach OpenCode Go. Zen und API-Schlüssel sind mögliche Erweiterungen.

## Drei verschiedene Messwerte

| Messwert | Aussage | Geeignete Quelle |
| --- | --- | --- |
| Account-Limit | Wie viel eines bestimmten Kontingents ist verbraucht, wann wird es zurückgesetzt? | Kontodaten des Anbieters |
| Lokale Nutzung | Welche Sitzungen und Modelle haben Tokens verbraucht? | Verlauf des jeweiligen Clients |
| Kosten | Gemeldete Kosten oder geschätzter API-Gegenwert | Nutzungsdaten und passende Preistabelle |

Ein Tokenzähler liefert keine verlässliche Abo-Prozentzahl. OpenCode und T3 Code sind Clients; OpenAI, Anthropic und OpenCode Go liefern unterschiedliche Kontingente. T3 trennt Nutzungsverlauf und Limits bereits und bezeichnet seine API-Kostenschätzungen ausdrücklich nicht als Abo-Rechnung. [T3-Nutzungsdokumentation](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/docs/user/usage.md)

Folgerung für Juicebar: Limits nach Anbieter, Konto und Kontingent identifizieren. Dasselbe Konto in T3, CLI und OpenCode darf nicht dreimal gezählt werden. Lokale Nutzung zusätzlich nach Client, Sitzung und Modell aufschlüsseln. Ohne verifizierte Kontoidentität keine automatische Zusammenführung.

## Codex

Der dokumentierte App Server bietet `account/rateLimits/read`. Fenster enthalten `usedPercent`, `windowDurationMins` und `resetsAt`; zusätzliche Kontingente können in `rateLimitsByLimitId` stehen. `account/rateLimits/updated` liefert Aktualisierungen. `account/usage/read` bietet eine Kontoübersicht und optionale Tagesdaten, ist aber nicht für reine API-Key-Anmeldung verfügbar. Die Fähigkeit muss zur installierten Version passen. [OpenAI App Server](https://learn.chatgpt.com/docs/app-server#auth-endpoints)

T3 startet für die Anbieterprüfung einen App-Server-Prozess, initialisiert das Protokoll und fragt das Konto sowie die Limits ab. Die Limitabfrage hat einen eigenen Timeout; ihr Fehlschlag lässt die übrige Anbieterprüfung weiterlaufen. Das ist ein brauchbares Vorbild für Fehlerisolation, kein Beleg für kostenlose oder ressourcenfreie Abfragen. [T3 CodexProvider](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/CodexProvider.ts)

T3 verarbeitet Ereignisse laufender Sitzungen und führt sie mit dem Snapshot zusammen. `primary` und `secondary` sind Positionen, keine garantierten Dauern. Modellbezogene Limits dürfen die Hauptkontingente nicht überschreiben; partielle Updates dürfen vorhandene Werte nicht versehentlich löschen. [T3 Codex-Limitabbildung](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/codexUsageLimits.ts), [Ereignisverarbeitung](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/ProviderUsageLimitsIngestion.ts)

Für eine eigenständige Tray-App folgt daraus: Snapshots regelmäßig abrufen; Ereignisse als Ergänzung nutzen. Ein eigener App-Server-Prozess ist kein belegter systemweiter Ereigniskanal für alle bereits laufenden Clients. Das Verhalten bei parallelen Clients muss der erste technische Versuch prüfen.

## Claude

Aktuelles T3 nutzt den Claude-SDK-Kontrollaufruf `get_usage` für die Abfrage und `rate_limit_event` für Aktualisierungen während eines Turns. Es verarbeitet `five_hour`, `seven_day` und verfügbare modellbezogene Wochenkontingente. Bei `rate_limits_available = false` meldet es die Quelle als nicht unterstützt. Achtung: Die Abfrage liefert Prozentwerte von 0 bis 100, Ereignisse liefern `utilization` von 0 bis 1. [T3 Claude-Limitabbildung](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/claudeUsageLimits.ts)

Das belegt einen aktuellen Integrationsweg über CLI/SDK, keine allgemeine HTTP-Schnittstelle für beliebige Claude-Abos. Für Juicebar muss ein Versuch ohne Modellprompt zeigen, welche installierten CLI-/SDK-Versionen diesen Abruf erlauben, wie sie sich anmelden und welchen Prozessaufwand er verursacht. Keine Browser-Cookies als Standardzugang.

Als passive Ergänzung dokumentiert Claude Code `rate_limits.five_hour` und `rate_limits.seven_day` im Statusline-JSON, jeweils mit `used_percentage` und `resets_at`. Die Daten erscheinen für Pro/Max nach der ersten API-Antwort und sind optional. Statusline-Ausführung selbst verbraucht keine API-Tokens. Eine spätere Integration müsste sich mit einer vorhandenen Statusline kombinieren und abgelaufene Werte verwerfen. Sie ersetzt keinen frischen Abruf bei geschlossenem Claude Code. [Claude Code Statusline](https://code.claude.com/docs/en/statusline)

Die offizielle Usage-and-Cost-API für Organisationen verlangt Admin-Zugang und betrifft API-Abrechnung. Sie ist keine Quelle für persönliche Pro-/Max-Abo-Prozente. [Anthropic Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)

## Angesparte Resets und Ablaufwarnungen

Codex liefert unter `account/rateLimits/read` optional `rateLimitResetCredits`. `availableCount` ist die maßgebliche Gesamtzahl. `credits` kann fehlen oder nur einen begrenzten Ausschnitt enthalten. Einzelne Einträge können ID, Resettyp, Status, Vergabezeit und Ablaufzeit enthalten; `expiresAt = null` belegt kein konkretes Ablaufdatum. Eine separate Einlöseoperation existiert, gehört aber nicht zur Beobachtung. [OpenAI App Server](https://learn.chatgpt.com/docs/app-server#auth-endpoints)

Claude beschreibt eigene Reset-Angebote. Je nach Angebot betreffen sie das Fünf-Stunden- oder das Wochenlimit. Der reguläre Wochenzeitplan bleibt bestehen. Ein eventueller Ablauf steht beim Angebot; die Einlösung erfolgt laut Hilfeseite im Web oder in Claude Desktop. Nicht genutzte Angebote können auch durch Kündigung oder Downgrade wegfallen. [Claude: What is a limit reset?](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset)

Damit ist die Produktfunktion bei Claude belegt, aber noch kein stabiler maschinenlesbarer Abruf ihrer Angebots-IDs, Wirkung und Ablaufzeiten. Die bisher untersuchten normalen Quotenfelder reichen dafür nicht aus. Die allgemeine Reset-Hilfeseite ist auch kein Beleg, dass mögliche andere CLI-Resetmechanismen identisch funktionieren. Anbieterbegriff, Wirkung, Ablauf und nächste Verfügbarkeit müssen getrennt bleiben.

CodexBar implementiert bereits eine Dreitageswarnung für ablaufende Codex-Resets. Es speichert Fingerabdrücke gemeldeter Bestände, begrenzt diese Historie auf 64 Einträge und testet Wiederholungen, Kontowechsel sowie fehlende Ablaufdaten. Das ist ein konkretes Vorbild für gespeicherten Warnzustand. Juicebar sollte stattdessen pro Konto, Vorteil und Warnstufe deduplizieren, damit eine veränderte Zusammenstellung nicht bereits gemeldete Einzelheiten erneut auslöst. [CodexBar-Notifier](https://github.com/steipete/CodexBar/blob/51898f3e5c0435d883a167069bd85ff226846101/Sources/CodexBar/CodexResetCreditExpiryNotifier.swift), [zugehörige Tests](https://github.com/steipete/CodexBar/blob/51898f3e5c0435d883a167069bd85ff226846101/Tests/CodexBarTests/CodexResetCreditExpiryNotifierTests.swift)

Der Vorschlag ist eine eigene Vorteilsliste neben Verbrauchsmesswerten. Ein lokaler Zeitplan erinnert beispielsweise drei Tage, einen Tag und kurz vor Ablauf, auch ohne neue Verbrauchsereignisse. Jede Erinnerung nennt den Geltungsbereich und einen genauen lokalen Zeitpunkt. Fehlende Ablaufdaten bleiben unbekannt; ein optionaler manueller Eintrag wird als solcher gekennzeichnet. Die erste Version öffnet zur Einlösung die Anbieterseite und löst nichts automatisch ein.

Weitere geprüfte Projekte und übertragbare Ansätze stehen in [project-comparison.md](project-comparison.md).

## OpenCode: Verlauf und Go-Limits getrennt anbinden

OpenCode veröffentlicht HTTP-APIs und SSE unter `/event` beziehungsweise `/global/event`. Sitzungen und Nachrichten lassen sich darüber abrufen. Eine TUI startet ihren eigenen Server; zusätzliches `opencode serve` startet einen weiteren. Zum Verbinden mit einer vorhandenen TUI muss deren Adresse bekannt sein. [OpenCode Server](https://opencode.ai/docs/server/)

Der globale Ereignisstrom hängt im untersuchten Quellcode an einem prozesslokalen `EventEmitter`. Daraus folgt keine automatische Beobachtung aller separat gestarteten TUIs. Die Integration braucht bekannte Serveradressen oder einen gemeinsamen Verlauf als zusätzliche Quelle. [GlobalBus](https://github.com/anomalyco/opencode/blob/34aa427434b054afcce7184764aa681159b5d769/packages/opencode/src/bus/global.ts), [SSE-Handler](https://github.com/anomalyco/opencode/blob/34aa427434b054afcce7184764aa681159b5d769/packages/opencode/src/server/routes/instance/httpapi/handlers/global.ts)

OpenCode schreibt Tokens und Kosten beim Abschluss eines Modellschritts in Nachricht und `step-finish`-Teil. Das ermöglicht zeitnahe Nutzungsauswertung, aber keinen Token-für-Token-Kontostand. Wiederholte Nachrichtenupdates müssen vorhandene Datensätze ersetzen statt sie erneut zu addieren. [OpenCode-Verarbeitung](https://github.com/anomalyco/opencode/blob/34aa427434b054afcce7184764aa681159b5d769/packages/opencode/src/session/processor.ts)

T3 hat inzwischen auch einen OpenCode-Verlaufsleser. Er liest aktuelle SQLite-Datenbanken ausschließlich lesend, setzt `busy_timeout = 100`, unterstützt ältere JSON-Dateien und dedupliziert Nachrichten-IDs. Der untersuchte Code ist damit weiter als die einleitende Anbieteraufzählung der Nutzungsdokumentation. Kosten von null behandelt T3 teilweise als fehlende Preisangabe und schätzt nach; Juicebar sollte gemeldete Kosten, Schätzungen und unbekannte Preise ausdrücklich unterscheiden. [T3 OpenCode-Verlaufsleser](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/usage/opencodeUsageReader.ts)

Für OpenCode Go existiert der konkrete Endpunkt `GET https://opencode.ai/zen/go/v1/usage`. Er erwartet einen Bearer-Schlüssel und liefert `rolling`, `weekly`, `monthly`, jeweils mit Prozentwert und Resetzeit. Der Server unterscheidet ungültige Anmeldung von fehlendem Go-Abonnement. Das ist eine echte Kontoquelle, aber die Quellcode-Verfügbarkeit allein garantiert keine dauerhaft stabile öffentliche API. [OpenCode Go-Endpunkt](https://github.com/anomalyco/opencode/blob/34aa427434b054afcce7184764aa681159b5d769/packages/console/app/src/routes/zen/go/v1/usage.ts)

T3 benutzt diesen Endpunkt, begrenzt den Abruf auf fünf Sekunden und lehnt die lokale Credential-Suche bei externen OpenCode-Servern ausdrücklich ab. Dort gehört das Konto dem entfernten Server. Ein Zen-Schlüssel allein bedeutet außerdem noch kein Go-Abonnement. [T3 Go-Adapter](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/openCodeUsageLimits.ts)

Empfehlung: OpenCode Go als separaten Kontingentadapter aufnehmen. Den OpenCode-Verlauf für die Nutzungsansicht lesen. Zen/API-Verbrauch später als Kosten- oder Budgetanzeige ergänzen; keinen erfundenen Abo-Prozentwert aus Tokens berechnen.

## Vorgeschlagene Architektur

Tauri 2 mit Rust für Abfragen, Regeln, Tray und Speicherung; React/TypeScript für die erst beim Öffnen erzeugte Ansicht. Tauri trennt den Rust-Hauptprozess von Webviews und nutzt die Webview des Betriebssystems. Das ist eine geeignete Grundlage, aber kein Beweis für niedrigen Verbrauch der fertigen App. [Tauri-Prozessmodell](https://v2.tauri.app/concept/process-model/)

- Quellenadapter liefern Kontoidentität, Kontingent-ID, Messzeit, Prozentwert, Reset und verfügbare Fensterdauer. Nicht unterstützte oder veraltete Quellen bleiben sichtbar.
- Ein zentraler Scheduler erlaubt je Quelle höchstens einen laufenden Abruf. Vorschlag: alle 60 Sekunden bei Aktivität, alle fünf Minuten im Leerlauf; zusätzlich manuell und durch geeignete Ereignisse. Anbieterregeln können längere Intervalle erzwingen.
- Jeder Abruf bekommt Timeout, Abbruch und begrenzte Wiederholungen mit Rückoff. Keine unbeschränkten Warteschlangen oder dauerhaft wiederholten Loginversuche.
- SQLite speichert Messpunkte, aggregierte Nutzungsmetadaten und Alarmzustände. Keine Prompts, Antworten oder kopierten Zugangsdaten.
- UI und Regeln zeigen den Zeitpunkt der letzten erfolgreichen Messung. Fehler ersetzen den letzten Messwert nicht durch null.

Das sind Entwurfsentscheidungen. Die konkreten Intervalle und Speichergrenzen müssen durch Messungen bestätigt werden. Bestehende Ereignisse helfen nur, wenn der jeweilige Adapter sie tatsächlich empfängt.

## Alarmregeln

Jedes Kontingent wird unabhängig ausgewertet. Ein ausgereiztes Wochenlimit bleibt relevant, auch wenn das kurze Fenster noch frei ist.

1. **50 Prozent.** Beim Erreichen oder Überschreiten einmal pro Kontingent und Resetperiode benachrichtigen. Bei erstmaliger Verbindung oberhalb der Schwelle höchstens einmal melden. Den Zustand über Neustarts speichern.
2. **Über dem gleichmäßigen Verbrauch.** Für ein verlässlich bekanntes Resetfenster mit Dauer `D` und Reset `R` gilt `Soll = 100 × clamp((jetzt − (R − D)) / D, 0, 1)`. Warnen, wenn `Verbrauch > Soll + Puffer`. Beispiel: Nach 40 Prozent der Fensterzeit sind 60 Prozent verbraucht. Puffer und Anlaufzeit verhindern Meldungen direkt nach dem Reset.
3. **Voraussichtlich innerhalb von zwei Stunden leer.** Aus mehreren frischen Messpunkten der letzten 30 bis 60 Minuten eine geglättete Verbrauchsrate in Prozentpunkten pro Stunde schätzen. `Restzeit = (100 − Verbrauch) / Rate`. Nur warnen, wenn die Rate positiv ist, die Restzeit den konfigurierten Horizont unterschreitet und das Limit vor dem nächsten Reset erreicht würde.

Die Sollkurve beschreibt zunächst gleichmäßigen Verbrauch über die gesamte Kalenderzeit. Arbeitszeiten und freie Tage wären eine spätere Option. Bei unbekanntem Fensteranfang, echtem gleitendem Fenster oder unklarer Resetsemantik bleibt diese Warnung deaktiviert. Eine bekannte Resetzeit allein beweist keinen festen Fensteranfang.

Nach Reset, Kontowechsel oder fallendem Verbrauch beginnt die Prognose mit neuen Messpunkten. Bei veralteten Daten, zu wenigen Punkten oder beendetem Verbrauch keine neue Prognosewarnung auslösen. Den Forecast als Schätzung kennzeichnen.

Alarmzustände dauerhaft speichern; Hysterese und Cooldown verhindern wiederholte Meldungen an einer Grenze. Gleichzeitig ausgelöste Regeln in einer Systembenachrichtigung bündeln. Ton ist separat einstellbar; keine modalen Popups. Ruhezeiten und Schlummern gehören in die erste brauchbare Version.

## Plattformen und Reihenfolge

Tauri unterstützt Tray-Menüs plattformübergreifend. Unter Linux sind Tray-Mausereignisse laut Dokumentation nicht unterstützt; die Bedienung braucht dort einen Menüpfad. Ein identischer macOS-Popover ist deshalb kein sinnvolles plattformübergreifendes Versprechen. [Tauri System Tray](https://v2.tauri.app/learn/system-tray/)

Systembenachrichtigungen sind über das Tauri-Plugin verfügbar. Unter Windows muss insbesondere die installierte Anwendung geprüft werden; das Verhalten im Entwicklungsmodus entspricht nicht dem fertig installierten Paket. [Tauri Notifications](https://v2.tauri.app/plugin/notification/)

Empfohlene Reihenfolge:

1. Codex- und Claude-Abruf ohne Modellprompts belegen. CPU, Arbeitsspeicher, Kindprozesse und Verhalten nach Schlafmodus, Offlinephasen und Authentifizierungsfehlern messen.
2. macOS-Tray mit Kontingenten, Datenalter und den drei Alarmregeln. OpenCode Go ergänzen.
3. Nutzungsansicht aus Codex-/Claude-/OpenCode-Verlauf mit sauberer Deduplizierung und erkennbaren Kostenschätzungen.
4. Windows- und Linux-Builds früh in CI aufnehmen; Plattformunterstützung erst nach Tests auf den jeweiligen Systemen behaupten.

Für eine Veröffentlichung ist MIT ein möglicher Lizenzvorschlag, noch keine getroffene Lizenzentscheidung. Kleine dokumentierte Adapter, anonymisierte Testdaten und reproduzierbare Fehlerberichte würden Beiträge erleichtern. Zuerst muss der Collector über längere Laufzeit ruhig bleiben; das Dashboard kommt danach.
