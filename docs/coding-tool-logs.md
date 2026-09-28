# Weitere lokale Nutzungsquellen

Stand: 28. September 2026. Geprüft wurden Herstellerdokumentation und der aktuelle Quellcode der jeweiligen Projekte. Diese Notiz beschreibt mögliche Integrationen; den tatsächlich implementierten Umfang dokumentiert [activity-and-costs.md](activity-and-costs.md).

Gemini CLI, Cline SDK, Roo Code und aktuelles Kilo haben verwertbare lokale Nutzungsdaten. Qwen Code speichert ebenfalls strukturierte Zähler, verwendet aber trotz ähnlicher Feldnamen eine andere Reasoning-Semantik als Gemini. Ein gemeinsamer Parser allein aufgrund der Projektverwandtschaft würde falsch zählen.

| Werkzeug | Verwertbare Quelle | Konsequenz für Juicebar |
| --- | --- | --- |
| Gemini CLI | JSONL und ältere JSON-Sitzungen mit Nachrichten-IDs und Tokens | Eigener Parser für beide Versionen |
| Cline SDK / CLI | Versioniertes `*.messages.json` mit Modell und Metriken | Eigenes Format für Vertrag v1 |
| Roo Code | `ui_messages.json` mit Anfragezählern und Kosten | Modell fehlt; gemeldete Kosten nutzen |
| Kilo, aktueller Stand | OpenCode-kompatible SQLite-Nachrichten | Bestehenden Datenbankleser mit eigener Quellenerkennung verwenden |
| Qwen Code | JSONL mit `usageMetadata` pro Antwort | Eigener Parser; Reasoning ist bereits im Output enthalten |
| GitHub Copilot CLI | Dauerhafte Sitzungsaggregate, flüchtige Anfragezähler | Eigenes Aggregatmodell nötig |
| Cursor | Dokumentierte Dashboard- und Admin-API-Nutzung | Separater Konto- oder Exportimport |
| Aider | Gesprächsprotokoll und gerundete Textberichte | Noch kein verifizierter vollständiger Importvertrag |

## Gemini CLI

Der Standardpfad ist `~/.gemini/tmp/<project>/chats/`. Unter macOS Seatbelt verwendet Gemini `~/.cache/.gemini/tmp/<project>/chats/`. `GEMINI_CLI_HOME` ersetzt das Home-Verzeichnis, nicht unmittelbar `.gemini`: Bei `/custom` lautet der normale Pfad `/custom/.gemini/tmp`. Projektverzeichnisse nicht auf ein bestimmtes Hashformat beschränken. [Speicherpfade](https://github.com/google-gemini/gemini-cli/blob/2fe7c2d3f065dc40ad573d50b2091116f8a4aa18/packages/core/src/config/storage.ts), [Home-Auflösung](https://github.com/google-gemini/gemini-cli/blob/2fe7c2d3f065dc40ad573d50b2091116f8a4aa18/packages/core/src/utils/paths.ts)

Ältere Dateien enthalten ein JSON-Objekt mit `sessionId` und `messages`. Aktuelle Dateien sind JSONL: Metadaten, Nachrichten und Aktualisierungen stehen in separaten Zeilen. Eine Nachricht besitzt `id`, `timestamp`, `type`, optional `model` und `tokens`. `recordMessageTokens` kann dieselbe ID später mit vollständigen Zählern erneut schreiben. Solche Revisionen ersetzen den Datensatz; sie sind keine weiteren Aufrufe. `$set` aktualisiert Metadaten und kann eine Nachrichtenliste enthalten. `$rewindTo` verändert den Gesprächsverlauf. Unterhaltungsverlauf und bereits angefallenen Verbrauch dabei auseinanderhalten. Subagent-Dateien liegen in Unterverzeichnissen. [Aufzeichnung und Laden](https://github.com/google-gemini/gemini-cli/blob/2fe7c2d3f065dc40ad573d50b2091116f8a4aa18/packages/core/src/services/chatRecordingService.ts)

`tokens.input` entspricht `promptTokenCount` und enthält den Cacheanteil `tokens.cached`. `tokens.output` entspricht `candidatesTokenCount`; `tokens.thoughts` steht separat. Für Juicebars getrennte Kategorien deshalb Cache aus Input herausrechnen und Thoughts dem gesamten Output zurechnen. `tokens.tool` und `tokens.total` sind zusätzliche Metadaten und keine unabhängig addierbaren Aufrufe. Nachrichten-ID und Quellformat bilden den Deduplizierungsschlüssel für Dateikopien und Formatmigrationen. [Feldvertrag](https://github.com/google-gemini/gemini-cli/blob/2fe7c2d3f065dc40ad573d50b2091116f8a4aa18/packages/core/src/services/chatRecordingTypes.ts), [Gemini-API-Zähler](https://ai.google.dev/api/generate-content#UsageMetadata)

Sitzungsdateien enthalten auch Prompts, Antworten und Werkzeugausgaben. Juicebar sollte ausschließlich die Nutzungsmetadaten speichern. Automatische Löschung kann die verfügbare Historie verkürzen. [Sitzungsverwaltung](https://github.com/google-gemini/gemini-cli/blob/2fe7c2d3f065dc40ad573d50b2091116f8a4aa18/docs/cli/session-management.md)

## Cline SDK und CLI

Der dokumentierte Vertrag v1 liegt unter `~/.cline/data/sessions/<sessionId>/<sessionId>.messages.json`. Das Objekt enthält `version`, `sessionId`, `agent` und `messages`. Assistant-Nachrichten haben stabile `id`, `ts` in Millisekunden und `modelInfo.id` sowie `modelInfo.provider`. Nur die abschließende Assistant-Nachricht eines Turns trägt die zugehörigen `metrics`. Diese enthalten `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens` und `cost`. `hooks.jsonl` ist zusätzliches Debugging und muss nicht eingelesen werden. [Vertrag v1](https://github.com/cline/cline/blob/880826f189bc87e8b43b477f97e2d564b520a5e1/sdk/packages/core/docs/messages-contract-v1.md)

Der SDK-Nutzungsdienst bestätigt ausdrücklich: `inputTokens` enthält bereits Cache-Lese- und Schreibanteile. Für exklusiven Input beide abziehen. Der SDK summiert Assistant-Metriken; Nachrichtenversionen daher nach stabiler ID ersetzen. Kosten sind USD laut Streamvertrag. Fehlende Kosten nicht als gemeldete Null behandeln. [Summierung und Cache-Semantik](https://github.com/cline/cline/blob/880826f189bc87e8b43b477f97e2d564b520a5e1/sdk/packages/core/src/services/usage.ts), [Streamvertrag](https://github.com/cline/cline/blob/880826f189bc87e8b43b477f97e2d564b520a5e1/sdk/packages/llms/src/providers/stream.ts)

Älteres Cline-Extension-Format ist eine separate Quelle. `tasks/<taskId>/ui_messages.json` enthält `say: "api_req_started"`, dessen `text` wiederum JSON mit `tokensIn`, `tokensOut`, `cacheReads`, `cacheWrites` und `cost` enthält. Der Typ garantiert weder Modell noch Protokoll; eine allgemeingültige Cache-Normalisierung ist damit nicht belegt. Diesen Verlauf nicht stillschweigend als SDK-v1-Datei oder Roo-Datei behandeln. [Dateinamen](https://github.com/cline/cline/blob/880826f189bc87e8b43b477f97e2d564b520a5e1/apps/vscode/src/core/storage/disk.ts), [Metriktyp](https://github.com/cline/cline/blob/880826f189bc87e8b43b477f97e2d564b520a5e1/apps/vscode/src/shared/ExtensionMessage.ts), [ältere Summierung](https://github.com/cline/cline/blob/880826f189bc87e8b43b477f97e2d564b520a5e1/apps/vscode/src/shared/getApiMetrics.ts)

## Roo Code

Roo legt Aufgaben unter `<extension-global-storage>/tasks/<taskId>/` ab. Die Extension-ID ist `rooveterinaryinc.roo-cline`. Auf macOS liegt der normale VS-Code-Stamm unter `~/Library/Application Support/Code/User/globalStorage/`; andere Editorvarianten und Remote-Server benötigen ihre eigenen Stämme. Die Einstellung `roo-cline.customStoragePath` ersetzt den Basispfad. [Extension-Manifest](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/package.json), [Speicherauflösung](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/utils/storage.ts)

`ui_messages.json` enthält ein Array. Die verwertbaren Zeilen haben `type: "say"`, `say: "api_req_started"`, `ts` und JSON im `text`-Feld. Roo aktualisiert diese Zeile nach Ende der Anfrage mit `tokensIn`, `tokensOut`, `cacheReads`, `cacheWrites`, `cost` und gegebenenfalls Fehlerstatus. `tokensIn` enthält nach Roos eigener Normalisierung sämtliche Cacheanteile, sowohl bei Anthropic als auch bei OpenAI. `apiProtocol` ändert diese bereits normalisierte Semantik nicht. [Anfrageverarbeitung](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/core/task/Task.ts), [Kosten- und Tokennormalisierung](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/shared/cost.ts)

In der Nutzungszeile fehlt eine belastbare Modell-ID. Empfehlung: als unbekanntes Modell anzeigen, vorhandene Kosten übernehmen und keine Modellnamen aus Prompttext extrahieren. Aufgabe plus Zeitstempel identifizieren eine Zeile innerhalb dieses Formats. Ein Zeitstempel allein reicht nicht über mehrere Aufgaben hinweg. Eine fehlende stabile Anfrage-ID begrenzt die Erkennung von beliebig kopierten oder geforkten Aufgaben.

## Kilo

Das aktuelle Kilo verwendet eine OpenCode-basierte SQLite-Datenbank. Standard ist `${XDG_DATA_HOME:-~/.local/share}/kilo/kilo.db`, auch unter macOS. `KILO_DB` kann einen absoluten Dateipfad oder einen Namen relativ zum Kilo-Datenverzeichnis festlegen. Entwicklungszweige verwenden `kilo-<channel>.db`; der Loader berücksichtigt vorhandene ältere `opencode-<channel>.db`. [Datenverzeichnis](https://github.com/Kilo-Org/kilocode/blob/7d977bce994af36f0edf752cb53e3aefc7aeb214/packages/core/src/global.ts), [Datenbankauflösung](https://github.com/Kilo-Org/kilocode/blob/7d977bce994af36f0edf752cb53e3aefc7aeb214/packages/core/src/database/database.ts)

Die Tabelle `message` enthält `id`, `session_id`, Erstellungs-/Änderungszeiten und JSON in `data`. Der Typ ist die V1-Nachricht des OpenCode-Schemas. `session` liefert unter anderem das Projektverzeichnis. Der bestehende OpenCode-Leser kann diese Nachrichten lesen; Kilo benötigt eine eigene Herkunft, damit sein Verbrauch korrekt bezeichnet wird. Nur Nachrichten summieren, nicht zusätzlich die kumulierten Tokenfelder der Sitzung. Datenbank ausschließlich lesend öffnen. [SQL-Schema](https://github.com/Kilo-Org/kilocode/blob/7d977bce994af36f0edf752cb53e3aefc7aeb214/packages/core/src/session/sql.ts), [Nachrichtenleser](https://github.com/Kilo-Org/kilocode/blob/7d977bce994af36f0edf752cb53e3aefc7aeb214/packages/opencode/src/session/message-v2.ts)

Ältere Kilo-Versionen schrieben Roo-artige Dateien in `kilocode.kilo-code/tasks`. Unterstützung der aktuellen Datenbank bedeutet keine automatische Unterstützung dieses früheren Formats.

## Qwen Code

Der reguläre Verlauf liegt unter `~/.qwen/projects/<sanitized-cwd>/chats/<sessionId>.jsonl`. `QWEN_HOME` ersetzt `.qwen` direkt. `QWEN_RUNTIME_DIR` hat für Laufzeitdaten Vorrang. Intern können ein gebundener Managed-Runtime-Kontext oder eine konfigurierte Runtime-Basis den Zielpfad bestimmen. Zusätzliche manuelle Verzeichnisse sind deshalb auch bei vorhandener Standarderkennung sinnvoll. [Pfadauflösung](https://github.com/QwenLM/qwen-code/blob/0105eb7d49c6acd7dc4ae97abd71630495c38c44/packages/core/src/config/storage.ts)

Assistant-Zeilen enthalten `uuid`, `sessionId`, ISO-Zeitstempel, `model` und `usageMetadata`. `recordAssistantTurn` schreibt die übergebenen Tokenmetadaten in diesen Datensatz. Andere System-, Werkzeug- und Metadatenzeilen sind keine Modellaufrufe. Neuere Managed-Transkripte haben weitere Subtypen; deren bloße Existenz beweist keine Kompatibilität mit dem regulären Assistant-Vertrag. [Aufzeichnung](https://github.com/QwenLM/qwen-code/blob/0105eb7d49c6acd7dc4ae97abd71630495c38c44/packages/core/src/services/chatRecordingService.ts)

Der OpenAI-Konverter setzt `promptTokenCount = prompt_tokens`, `candidatesTokenCount = completion_tokens` und `thoughtsTokenCount = reasoning_tokens`. Fehlt der letzte Wert, kann Qwen ihn aus Reasoning-Text schätzen. Output enthält Reasoning bereits; Thoughts nicht noch einmal addieren. Cache ist eine Teilmenge des Inputs. Dieses Verhalten ist für die untersuchte OpenAI-kompatible Quelle belegt und darf nicht unbesehen auf beliebige zukünftige Provider übertragen werden. [Konverter](https://github.com/QwenLM/qwen-code/blob/0105eb7d49c6acd7dc4ae97abd71630495c38c44/packages/core/src/core/openaiContentGenerator/converter.ts)

## Warum Copilot, Cursor und Aider andere Integrationen brauchen

Copilot CLI speichert Sitzungen unter `~/.copilot/session-state/`. Im offiziellen SDK-Schema ist `assistant.usage` ausdrücklich flüchtig und nicht Bestandteil des dauerhaften Ereignislogs. `session.shutdown` enthält dagegen kumulierte Modellmetriken; `session.usage_checkpoint` enthält akkumulierte AI-Credits. Diese Aggregate erlauben keine verlässliche zeitliche Zuordnung jeder einzelnen Anfrage. Außerdem sind Credits, Premium-Requests und Dollar unterschiedliche Einheiten. Ein späterer Import braucht Regeln für wiederaufgenommene Sitzungen und kumulierte Stände. [Sitzungsdaten](https://docs.github.com/en/enterprise-cloud%40latest/copilot/concepts/agents/copilot-cli/chronicle), [offizielles Ereignisschema](https://github.com/github/copilot-sdk/blob/d106d29dc6c5112da2abdae59008571b6692f12b/nodejs/src/generated/session-events.ts)

Cursor dokumentiert Nutzungsdaten im Dashboard und einen Admin-Endpunkt für Nutzungsereignisse. Die untersuchten Primärquellen liefern keinen stabilen Vertrag für vollständige lokale Tokenaufzeichnungen. Empfehlung: eigener Import des offiziellen Exports oder der autorisierten API. Die Existenz lokaler Chatdaten allein reicht nicht als Nachweis vollständiger Abrechnungszähler. [Nutzungsanalyse](https://cursor.com/docs/account/teams/analytics), [Admin-API](https://docs.cursor.com/en/account/teams/admin-api)

Aider bietet Gesprächs- und optionale LLM-Protokolle. Sein normaler Bericht formatiert Tokens und Kosten als gerundeten Text. In den geprüften Quellen wurde kein standardmäßig geschriebenes, vollständiges Nutzungsformat mit stabilen Anfrage-IDs gefunden. Empfehlung: erst einen strukturierten Exportvertrag oder eine ausdrücklich eingerichtete Telemetriequelle unterstützen. [Protokolloptionen](https://aider.chat/docs/config/options.html), [Erzeugung der Nutzungsberichte](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/coders/base_coder.py)

## Preise und Importregeln

Beispielwerte aus Googles Standard-API-Tarif am Recherchetag, USD je Million Tokens: `gemini-3.1-pro-preview` kostet bis einschließlich 200.000 Prompt-Tokens 2 Input, 12 Output und 0,20 Cache; darüber 4, 18 und 0,40. `gemini-3.1-flash-lite` kostet für Text 0,25, 1,50 und 0,025. Outputpreise enthalten Thinking. Zusätzliche Speicher- und Toolgebühren sind damit nicht erfasst. Das sind API-Gegenwerte, keine persönliche Abo-Abrechnung. [Google-Preise](https://ai.google.dev/gemini-api/docs/pricing)

Für alle Leser gilt als Implementierungsempfehlung: ausschließlich belegte Nutzungszeilen übernehmen, Änderungen nach stabiler Identität ersetzen und unbekannte Werte sichtbar lassen. Zusätzliche Ordner sollten ein bekanntes Format auswählen. Standarderkennung und manuell angelegter Ordner müssen denselben kanonischen Pfad und dieselben Nutzungsidentitäten verwenden, damit spätere Unterstützung keine Doppelzählung erzeugt.
