# Integrationsverträge für die Implementierung

Stand: 25. September 2026. Aus veröffentlichtem Quellcode abgeleitet; diese Recherche hat weder Zugangsdaten gelesen noch echte Sitzungen gestartet. Beispiele enthalten ausschließlich erfundene Werte.

## Claude: Kontingente ohne Modellprompt

T3 startet einen Claude-Unterprozess über SDK 0.3.276, initialisiert den Kontrollkanal, fragt `get_usage` ab und beendet den Prozess. Sein Prompt-Iterator liefert nie eine Benutzernachricht. Das verhindert Modellaufrufe; die Kontingentabfrage selbst benötigt weiterhin Netzwerk. [T3 Probe](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/ClaudeProvider.ts)

Die veröffentlichte SDK-Implementierung erzeugt folgende Basisargumente; kein `-p` oder `--print` wird angefügt:

```text
claude --output-format stream-json --verbose --input-format stream-json
       --no-session-persistence --strict-mcp-config
       --setting-sources=user,project,local
       --settings {"disableAllHooks":true}
```

Das JSON nach `--settings` ist ein einzelnes Argument, ohne Shell-Interpretation. Die Settings-Quellen sind T3s Wahl für dessen Command-Erkennung. Ein reiner Monitor kann seine Quellen enger wählen, muss dabei aber benutzerdefinierte Login-/Backend-Konfiguration berücksichtigen. `allowedTools: []` erzeugt im SDK keinen CLI-Schalter. Zum ausdrücklichen Entfernen aller Tools entspricht `tools: []` den zwei Argumenten `--tools`, `""`. [SDK 0.3.276, veröffentlichte Implementierung](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.276/sdk.mjs)

T3 setzt `ENABLE_CLAUDEAI_MCP_SERVERS=false`, `CLAUDE_CODE_AUTO_CONNECT_IDE=0`, `CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1` und entfernt `FORCE_CODE_TERMINAL`. Hooks sind deaktiviert; leeres `mcpServers` plus Strict-Modus verhindert konfigurierte MCP-Starts. Keine IDE-Suche und keine Projekt-Hooks bei jedem Refresh. Der SDK-Transport setzt außerdem `CLAUDE_CODE_ENTRYPOINT=sdk-ts`, falls leer. [T3 Probeoptionen](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/ClaudeProvider.ts), [SDK-Transport](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.276/sdk.mjs)

Stdin und Stdout sind newline-delimited JSON. Erst initialisieren und die Antwort abwarten:

```json
{"type":"control_request","request_id":"init","request":{"subtype":"initialize"}}
```

Dann auf demselben offenen Prozess:

```json
{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}
```

`skip_behaviors: true` ist für Juicebar wesentlich. Ohne diesen Schalter scannt Claude laut SDK-Typbeschreibung alle in den letzten sieben Tagen veränderten Transkripte. Das ist für eine Quotenanzeige unnötig. `initialize` benötigt außer `subtype` keine weiteren Pflichtfelder. Der SDK-Name des Usage-Aufrufs enthält ausdrücklich `EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET`; Änderungen müssen als Integrationsfehler behandelt werden. [SDK-Typen](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.276/sdk.d.ts)

Erfolgsantwort:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":"pro","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":12,"resets_at":"2026-09-25T18:00:00Z"},"seven_day":{"utilization":36,"resets_at":"2026-09-29T18:00:00Z"}},"session":{},"behaviors":null}}}
```

`session` ist hier gekürzt. Die echten Felder sind `total_cost_usd`, `total_api_duration_ms`, `total_duration_ms`, `total_lines_added`, `total_lines_removed`, `model_usage`. Für Kontingente sind sie unerheblich. `rate_limits_available=false` bedeutet zum Beispiel API-Key-/Bedrock-/Vertex-Anmeldung oder fehlenden Profile-Scope; `rate_limits` ist dann null. Prozentwerte sind 0–100, Resetzeiten ISO 8601; einzelne Fenster und Werte können null sein. Fehlerantworten tragen `response.subtype="error"`, die passende `request_id` und `error`. Andere Zeilen nicht mit der erwarteten Antwort verwechseln. [SDK-Typen](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.276/sdk.d.ts), [T3 Protokolltest](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/ClaudeCapabilitiesProbe.test.ts)

Weitere bekannte Fenster sind `seven_day_oauth_apps`, `seven_day_opus`, `seven_day_sonnet`. `model_scoped[]` enthält `{display_name, utilization, resets_at}`; fehlendes Array und leeres Array haben unterschiedliche Bedeutung. `extra_usage` enthält `{is_enabled, monthly_limit, used_credits, utilization, currency?}`. Geldbeträge daraus nicht ohne bestätigte Einheit darstellen. Stdout/Stderr gleichzeitig lesen und begrenzen, Initialisierung und Abruf begrenzen, Prozess bei Erfolg, Fehler und Timeout sicher beenden. [SDK-Typen](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.276/sdk.d.ts)

## Claude: strukturierte Reset-Angebote

T3 hat eine separate, private Integration für das Programm `cedar_ember`:

```http
GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1
Authorization: Bearer <vorhandenes Claude-OAuth-Token>
anthropic-beta: oauth-2025-04-20
user-agent: claude-cli/<Version> (external, cli)
```

```json
{"cedar_ember":{"eligible":true,"next_grant_id":"grant_example","grants":[{"id":"grant_example","resets_left":2,"ends_at":"2026-09-30T23:59:59Z","paused":false,"usable_now":true}]}}
```

T3 akzeptiert Grants mit nichtnegativem `resets_left`, ignoriert pausierte/nicht nutzbare/abgelaufene Grants und ordnet `next_grant_id` zu. Fehlendes `ends_at` bedeutet unbekannten Ablauf, nicht unbegrenzte Gültigkeit. In diesem Schema ist kein verlässlicher Fünfstunden-/Wochen-Scope belegt. Der SDK-`get_usage`-Antworttyp enthält diesen Block nicht. [T3 Reset-Adapter](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/claudeResetCredits.ts)

T3 liest dafür `.credentials.json` im Claude-Konfigurationsverzeichnis, deaktiviert diesen Weg auf macOS ausdrücklich wegen Keychain-Speicherung. Das ist kein Beleg dafür, dass jeder macOS-Login eine solche Datei besitzt. Eine native Anwendung benötigt einen ausdrücklich gewählten Zugang oder einen manuellen Angebotseintrag. Scheitert dieser optionale Abruf, dürfen normale Quoten weiter funktionieren; "unbekannt" statt "keine Angebote" anzeigen. Einlösen ist eine separate schreibende Aktion und gehört nicht in den Lese-Collector. [T3 Reset-Adapter](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/claudeResetCredits.ts)

## OpenCode Go

```http
GET https://opencode.ai/zen/go/v1/usage
Authorization: Bearer <OpenCode-Go-Key>
```

```json
{"usage":{"rolling":{"status":"ok","percent":12.5,"resetsAt":"2026-09-25T18:00:00Z"},"weekly":{"status":"ok","percent":20,"resetsAt":"2026-09-29T18:00:00Z"},"monthly":{"status":"ok","percent":25,"resetsAt":"2026-10-01T18:00:00Z"}}}
```

Der implementierte Server liefert 401 bei fehlendem/ungültigem Schlüssel und 403 bei fehlendem Go-Abonnement. `status` ist `ok` oder `rate-limited`; `percent` ist bereits Prozent. T3 ordnet rolling fünf Stunden, weekly sieben Tagen zu; für monthly setzt T3 keine feste Dauer. [OpenCode-Endpunkt](https://github.com/anomalyco/opencode/blob/34aa427434b054afcce7184764aa681159b5d769/packages/console/app/src/routes/zen/go/v1/usage.ts), [T3 Go-Adapter](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/openCodeUsageLimits.ts)

T3 sucht den lokalen Schlüssel in `OPENCODE_AUTH_CONTENT` oder `$XDG_DATA_HOME/opencode/auth.json`, standardmäßig `~/.local/share/opencode/auth.json`, unter `opencode-go: {type:"api",key:"..."}`; gespeicherte Credentials haben Vorrang vor `OPENCODE_API_KEY`. Bei Remote-Servern darf nicht automatisch der lokale Account zugeordnet werden. [T3 Go-Adapter](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/provider/Layers/openCodeUsageLimits.ts)

## OpenCode Zen: Balance nicht als Go-Quote behandeln

Im geprüften Routing ist kein ebenso geeigneter öffentlicher Balance-Endpunkt mit Zen-Bearer-Key belegt. Die Console lädt ihre Balance über `queryBillingInfo(workspaceID)` als authentifizierte Serverfunktion mit `withActor`, intern `Billing.get()`. Das ist kein bestätigter REST-Vertrag für Juicebar. In dieser Console entsprechen 100.000.000 interne Balance-Einheiten einem Dollar. Keine geratenen `/balance`-URLs implementieren und keine Browser-Cookies voraussetzen. Bis zu einer belastbaren Kontoquelle kann Juicebar lokalen OpenCode-Verbrauch und ein ausdrücklich manuelles Budget anbieten. [Console-Abfrage und Formatierung](https://github.com/anomalyco/opencode/blob/34aa427434b054afcce7184764aa681159b5d769/packages/console/app/src/routes/workspace/common.tsx)

## OpenCode: lokale SQLite-Nutzung

Aktuell existieren `message` und `session_message`, jeweils mit `id`, `session_id`, `time_created`, `time_updated`, JSON-Spalte `data`. V2 besitzt zusätzlich `type` und `seq`. Erst Tabellen und Spalten prüfen. Datenbank ausschließlich lesend öffnen, Busy-Timeout kurz halten und keine Migrationen ausführen. [Tabellenschema](https://github.com/anomalyco/opencode/blob/34aa427434b054afcce7184764aa681159b5d769/packages/core/src/session/sql.ts)

```sql
SELECT id, session_id, data, time_created, time_updated
FROM message WHERE time_updated >= ? ORDER BY time_updated, id;

SELECT id, session_id, data, time_created, time_updated
FROM session_message WHERE type = 'assistant' AND time_updated >= ?
ORDER BY time_updated, id;
```

Dies sind daraus abgeleitete Abfragen, kein veröffentlichtes Reporting-API. Der Änderungszeitpunkt ist für inkrementelles Lesen nötig, da eine bereits existierende Nachricht später Tokens erhalten kann. Usage dem Erstellungs-/Abschlusszeitpunkt zuordnen, nicht dem Scanzeitpunkt. Überlappende Änderungsfenster lesen und nach Nachrichtenschlüssel upserten. V1 `data` verwendet `role:"assistant"`, `modelID`, `providerID`; V2 verwendet `type:"assistant"`, `model:{...}`. Beide liefern `tokens:{input,output,reasoning,cache:{read,write}}` und optional `cost`. Fehlende Werte sind nicht automatisch null Dollar. [V2-Nachricht](https://github.com/anomalyco/opencode/blob/34aa427434b054afcce7184764aa681159b5d769/packages/schema/src/session-message.ts), [T3 Verlaufsleser](https://github.com/pingdotgg/t3code/blob/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/server/src/usage/opencodeUsageReader.ts)

Legacy-/V2-Kopien und Fork-Kopien dürfen nicht doppelt gezählt werden. Für detaillierte Kompatibilitätsfälle enthält ccusage einen eigenen OpenCode-Leser mit Tests. Kumulative Sitzungswerte nicht zusätzlich zu Nachrichten summieren und nicht beliebig auf Tage verteilen. [ccusage OpenCode-Leser](https://github.com/ccusage/ccusage/blob/15830fb1636f5dccb1b8ca383ce1806a7deb0c9c/rust/adapters/opencode/src/loader.rs)
