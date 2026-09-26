# Anbieter-Metadaten

Geprüft am 25. September 2026.

## Abo-Bezeichnungen

Codex liefert über `account/read` den Plan-Identifier. `pro` wird als „Pro 20×“, `prolite` als „Pro 5×“ dargestellt. Die Zuordnung entspricht [CodexBars Plan-Formatierung](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Codex/CodexPlanFormatting.swift). Unbekannte Identifier bekommen keinen erfundenen Faktor.

Claude liefert über `get_usage` den Abo-Typ. Ergänzend liest Juicebar aus dem passenden lokalen `.claude.json` die Kontometadaten `userRateLimitTier`, ersatzweise `organizationRateLimitTier`. Ein expliziter `default_claude_max_20x`- oder `default_claude_max_5x`-Wert ergänzt das Max-Label. Unbekannte Tiers bleiben ohne Faktor. Keine zusätzliche Netzabfrage, keine Token-Erneuerung.

## Nimbus Quill

Keine belastbare Anthropic-Dokumentation zur Bedeutung gefunden. [claude-menubar](https://github.com/vkhrystych/claude-menubar/blob/main/README.md) beschreibt das Feld als Platzhalter und überspringt es. Das ist eine Beobachtung des Projekts, keine offizielle Produktzuordnung.

Juicebar ignoriert den exakten Claude-Identifier `nimbus_quill` beim Einlesen und bei der Darstellung alter Messungen. Dadurch verschwindet er auch aus Verlauf, Popover und Limit-Auswahl. Die dynamische Erkennung anderer neuer Limits bleibt bestehen.

## Reset-Fristen und Logos

Ab 0.1.3 liest Juicebar keine Claude-OAuth-Tokens mehr und ruft den privaten Endpunkt für Claude-Reset-Angebote nicht mehr auf. Claude-Ablaufdaten können weiterhin manuell erfasst werden. Hintergrund und verbleibende Grenzen stehen unter [Anbieterzugriff](provider-access.md).

Reset-Fristen stammen aus `rateLimitResetCredits.credits[].expiresAt`. Die Kontokarte und der Popover zeigen den frühesten gemeldeten Ablauf verfügbarer Resets mit Datum und Uhrzeit. Fehlende Fristen bleiben als unbekannt erkennbar.

Das OpenCode-Zeichen verwendet die Geometrie aus `assets/providers/opencode.svg` mit getrennten Farben für Rahmen und inneren Schatten. Einfarbige Template-Darstellung würde diese Unterscheidung verlieren.
