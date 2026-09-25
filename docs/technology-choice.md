# Technologievergleich für Juicebar

Stand: 25. September 2026. Umgesetzt ist Swift mit SwiftUI/AppKit für macOS 14+. Der erste Tauri-Vorschlag hat die optionale Unterstützung weiterer Betriebssysteme stärker gewichtet als die native Mac-Integration. Die Entscheidung gewichtet nun die native Mac-Menüleiste, begrenzte Hintergrundarbeit und direkte Systemintegration höher. Windows und Linux bleiben mögliche spätere Portierungen.

## Was die Wahl entscheiden sollte

Juicebar wartet überwiegend auf Netzwerk, lokale Dateien und Zeitpunkte. Tray, Benachrichtigungen, Anmeldung, Schlafmodus und begrenzte Hintergrundarbeit sind wichtiger als maximale Rechengeschwindigkeit. Die Frage ist deshalb zunächst, welche Desktop-Umgebung wir bauen und pflegen wollen, danach die Sprache des Kerns.

Open Source erfordert keine Unterstützung für drei Betriebssysteme. Eine gute Mac-App kann anderen Mac-Nutzern helfen. Umgekehrt ist eine native SwiftUI-Oberfläche später kein wiederverwendbares Windows-/Linux-Frontend.

## Die ernsthaften Optionen

| Option | Passt besonders, wenn | Preis der Entscheidung |
| --- | --- | --- |
| Swift mit SwiftUI/AppKit | Mac-Menüleiste, native Bedienung und direkter Betriebssystemzugang Vorrang haben | Für Windows/Linux braucht es eine andere Oberfläche und Integration. |
| Tauri 2 mit Rust und Weboberfläche | Eine gemeinsame Desktop-App für macOS, Windows und Linux tatsächlich geplant ist | Rust plus Webentwicklung, Kommunikation zwischen beiden, Unterschiede der System-Webviews und gelegentlich nativer Zusatzcode. |
| Wails mit Go und Weboberfläche | Gemeinsame Plattformen gewünscht sind und Go gut zum Projekt passt | Ähnliche Webview-Kompromisse; die für Tray und Fensterverwaltung besonders interessante v3 ist derzeit Beta. |
| Electron mit TypeScript | Durchgängige TS-Entwicklung und eine mitgelieferte Browserumgebung wichtig sind | Chromium und Node gehören zur Laufzeit; für eine kleine ständig laufende Utility muss deren Grundaufwand bewusst akzeptiert und gemessen werden. |

SwiftUI bietet `MenuBarExtra` für eine reine Menüleisten-App und einen Fensterstil für reichhaltigere Inhalte. AppKit ergänzt direkte Kontrolle über Statusitem und Fenster. Dafür braucht die App keine Webview. Das ist eine gute Ausgangslage für Juicebars Mac-Schwerpunkt, keine Garantie für bestimmte RAM-Werte. [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)

Tauri trennt einen Rust-Kern von den Webview-Prozessen. Es verwendet die Webview des Betriebssystems. Die Oberfläche kann in TypeScript mit React, Svelte oder anderen Web-Frameworks entstehen. Ein Framework wie React allein liefert jedoch keine native Tray-App oder dauerhaft laufenden Betriebssystemprozess. [Tauri-Prozessmodell](https://v2.tauri.app/concept/process-model/)

Wails verbindet einen Go-Kern ebenfalls mit einer System-Webview und erzeugt Bindings zwischen Go und Frontend. Es ist damit ein direkter Kandidat neben Tauri. Die v3-Dokumentation und Beta-Ankündigung beschreiben das neue Fenster- und Anwendungsmodell; v2 bleibt laut Ankündigung die stabile Linie. Die Entscheidung gegen Wails wäre derzeit eine Abwägung der benötigten Funktionen und Release-Reife, kein Beweis, dass Go zu langsam oder zu speicherhungrig wäre. [Wails-Architektur](https://v3.wails.io/concepts/architecture/), [v3-Beta-Ankündigung](https://v3.wails.io/blog/wails-v3-beta/)

Electron erlaubt Hauptprozess und Frontend weitgehend in JavaScript/TypeScript. Es übernimmt Chromiums Prozessmodell und integriert Node. Das erleichtert insbesondere die Verwendung von TS-SDKs. Es hat einen anderen Laufzeitumfang als Swift oder eine System-Webview-Lösung. Daraus folgt eine begründete Erwartung an den Grundaufwand, aber keine seriöse pauschale Aussage wie "Electron braucht immer X MB" oder "jede Electron-App ist langsam". [Electron-Prozessmodell](https://www.electronjs.org/docs/latest/tutorial/process-model), [Leistungshinweise](https://www.electronjs.org/docs/latest/tutorial/performance)

## Rust, Go und Swift lösen unterschiedliche Probleme

TypeScript bedeutet nicht zwangsläufig Electron. Electrobun ist eine weitere Desktop-Option mit System-Webviews; seine aktuelle 2.x-Dokumentation nennt Cottontail auf JavaScriptCore als Standardlaufzeit und Bun als Alternative. Ein Tray-Interface ist vorhanden. Die für Juicebar nötige Benachrichtigungsfunktion wurde bei dieser Prüfung nicht vollständig belegt und müsste vor einer Empfehlung getestet werden. [Electrobun-Aufbau](https://framework.blackboard.sh/electrobun/guides/what-is-electrobun/), [Tray](https://framework.blackboard.sh/electrobun/apis/tray/)

Wails v3 dokumentiert bereits Tray-Menüs, Popup-Fenster und native Benachrichtigungen mit Ton. Bei geplanten Benachrichtigungen unterscheidet sich die Umsetzung: macOS verwendet Systemplanung, Windows/Linux verwenden Timer im laufenden Prozess. Das ist ein Beispiel dafür, warum ein gemeinsames Framework einen dauerhaft gespeicherten Warnzustand und Plattformtests nicht ersetzt. [Wails Tray](https://v3.wails.io/features/menus/systray/), [Benachrichtigungen](https://v3.wails.io/features/notifications/overview/), [aktueller Beta-Status](https://v3.wails.io/status/)

Rust bietet Kontrolle über Lebensdauern ohne einen tracing Garbage Collector im Rust-Kern. Go nimmt mit seinem Garbage Collector mehr Speicherverwaltung ab und bietet eine kompakte Sprache für Netzwerk- und Hintergrundarbeit. Für Juicebars erwartete Last ist der GC allein kein überzeugendes Ausschlusskriterium. Swift verwendet automatische Referenzzählung und passt unmittelbar zu Apples UI-Frameworks. [Go-GC-Leitfaden](https://go.dev/doc/gc-guide), [Swift ARC](https://docs.swift.org/latest/documentation/the-swift-programming-language/automaticreferencecounting/)

Keine dieser Entscheidungen begrenzt von selbst wachsende Caches, stoppt vergessene Tasks oder beendet Kindprozesse. Tauri enthält außerdem eine Webview mit eigenem Laufzeitverhalten. CPU, Speicher und Hänger müssen am gesamten Prozessbaum geprüft werden. Die fehlende Browserengine bei einer nativen Swift-Oberfläche ist ein konkreter Unterschied; ein allgemeines Versprechen "Rust verhindert Speicherleaks" wäre falsch.

Die Anbieteranbindung kann die Wahl beeinflussen. Eine dokumentierte JSON-RPC-Schnittstelle lässt sich aus mehreren Sprachen verwenden. Ein nur über ein TS-SDK erreichbarer Zugriff kann dagegen einen zusätzlichen Helfer erfordern. Ein Rust-Kern allein macht diesen Helfer weder überflüssig noch kostenlos. Die Codex-/Claude-Machbarkeitsprüfung gehört vor die endgültige Stackwahl.

## Ladybird

Ladybird entstand in C++ und hat im Februar 2026 Rust als Nachfolgesprache für Teile des Systems gewählt. Der zuvor untersuchte Swift-Weg wurde wegen C++-Integration und Plattformunterstützung verworfen. Das Projekt kündigte ausdrücklich ein längeres Nebeneinander von C++ und Rust an. Im August meldete es weitere Rust-Portierungen von CSS-Parsing und Zeichenpipeline. [Ladybird: Rust-Einführung](https://ladybird.org/posts/adopting-rust/), [August-Bericht](https://ladybird.org/newsletter/2026-08-31/)

Ein Browser muss fremde Inhalte parsen, Layout berechnen und Skripte ausführen. Diese Anforderungen erklären seinen Schwerpunkt auf Systemsprache, Speichersicherheit und vorhandener C++-Integration. Für Juicebar folgt daraus keine Pflicht zu C++ oder Rust. Tauri würde ohnehin Rust verwenden, aber wegen seines Desktop-Angebots gewählt werden. C++ mit etwa Qt wäre möglich; ohne vorhandenen C++-Code oder besondere native Anforderungen gibt es hier keinen erkennbaren Vorteil, der die zusätzliche Pflege rechtfertigt.

## Vorläufige Empfehlung und Prüfung

Wenn Windows/Linux optional bleiben, würde ich für die beschriebene Priorität eine native Swift-App zuerst prüfen. Wenn eine gemeinsame Anwendung für alle drei Systeme verbindlich wird, ist Tauri 2 die erste Vergleichsoption, Wails v3 eine ernsthafte Alternative bei Go-Präferenz und akzeptierter Beta-Reife. Electron ist sinnvoll, wenn TS-Durchgängigkeit und SDK-Nutzung den Laufzeitumfang rechtfertigen.

Eine gemischte Swift-Oberfläche mit separat entwickeltem Rust-Kern kann später sinnvoll sein, führt aber sofort eine weitere Sprach- und Buildgrenze ein. Ohne konkreten Wiederverwendungsbedarf ist sie kein automatischer Mittelweg. Die beschriebenen Anbietermodule und Warnregeln lassen sich auch in Swift oder Go sauber trennen.

Vor einer Festlegung sollten zwei kleine, vergleichbare Varianten denselben Collector verwenden beziehungsweise dieselben Abfragen durchführen: native Mac-Oberfläche und die bevorzugte plattformübergreifende Alternative. Geprüft werden Start, Leerlauf, geöffnetes und geschlossenes Fenster, Schlafmodus, Offline/Online, Benachrichtigung mit Ton, beendete Helfer und längerer Speicherverlauf. Noch wurden keine solchen Varianten gebaut oder gemessen.
