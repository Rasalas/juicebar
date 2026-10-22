# Menüleisten-Prototyp

Frage: Welche Darstellung zeigt mehrere Anbieter gleichzeitig am lesbarsten in einer 24-Pixel-Menüleiste?

Vier vorläufige Varianten: horizontale Fülllinien, vertikale Doppellinien, segmentierte Skalen und Prozentzahlen mit Unterstrich. Feste Reihenfolge Codex, Claude, OpenCode Go, weiterer Anbieter. Mit zwei/vier Konten, Anbieterfarben/Monochrom und Normal-/Leer-/Offline-Zuständen vergleichbar.

```sh
python3 -m http.server 4318 --bind 127.0.0.1 --directory design
```

Dann `http://localhost:4318/menubar-prototype.html?variant=A` öffnen. Die HTML-Datei funktioniert auch direkt ohne Server. A–D über die Pfeile unten, Tastatur oder Vergleichskarten wählen. Keine Live-Daten, keine Änderungen an Konten, kein Speichern von Einstellungen. Die Datei ist ausschließlich ein Entscheidungsprototyp und gehört nicht ins App-Bundle.

B wurde nach Rückmeldung zu farbigen Limitlinien ohne Namen und Prozentzahlen geändert. Eine Linie pro vorhandenem Limit, fest gruppiert nach Anbieter, optionales Modelllimit und anklickbare Detailvorschau. Feinauswahl noch offen. Nach Auswahl wird die Darstellung in Swift/AppKit umgesetzt. Das Projekt ist momentan kein Git-Repository; deshalb gibt es noch keinen separaten Prototyp-Branch.

## Arbeitsplan

`work-plan-prototype.html` ist ein interaktiver Entscheidungsentwurf für die Frage, ob das Wochenbudget in die Arbeitszeiten eines Kontos passt. Die Datei lässt sich direkt öffnen oder mit dem oben genannten Server unter `/work-plan-prototype.html` aufrufen. Keine App-Anbindung, keine gespeicherten Einstellungen.

Voreinstellung: Team-Konto, Mo/Di/Do/Fr 08:00–13:30 Uhr und eine vorläufig angenommene Pause von 12:00–12:30 Uhr, insgesamt 20 Arbeitsstunden. Geschätzte Verbrauchswerte sind 10 Wochenprozent pro vollem 5h-Kontingent und 40 Minuten Agentenlauf pro Kontingent. Der Beginn eines nutzbaren Kontingents startet die fünfstündige Frist. Laufzeit und Frist sind getrennt; bei erlaubtem Weiterlaufen darf ein gestarteter Lauf außerhalb der Arbeitszeiten enden. Bei strengem Feierabend wird nur die tatsächlich verfügbare Zeit innerhalb des Fensters angerechnet.

„Volle Woche“ zeigt den Beispielzyklus 28.10.–04.11.2026 mit dem kontoeigenen Reset mittwochs um 13 Uhr. „Ab jetzt“ verwendet ausschließlich den gespeicherten Stand vom 22.10.2026, 19:34 Uhr mit 48 % Wochenrest. Alle Zeiten sind Europe/Berlin. Pro Szenario wird ein volles 5h-Kontingent zu Beginn angenommen. Zusätzliche Starts werden als Vorschlag bevorzugt auf vorhandene Arbeitstage gelegt. Die Oberfläche und die isolierte Berechnung bleiben vorerst ein Prototyp; ein App-Einbau ist noch nicht beschlossen.

### Kompakter Gegenentwurf

Nach Rückmeldung war die Kalenderdarstellung zu unübersichtlich. `work-target-prototype.html` beschränkt sich auf die vorhandene Kontokarte. Zwei umschaltbare Darstellungen zeigen das heutige Verbrauchsziel als weitere Raute am Restbalken oder als verbleibende Teilkontingente. Eine kurze Zeile nennt nötige Zusatznutzung außerhalb der Arbeitszeiten. Die drei ausdrücklich fiktiven Beispiele unterscheiden Arbeitstag, freien Mittwoch mit Budgetpuffer und freien Mittwoch mit vollständig für Arbeitstage reserviertem Wochenrest. Die Reservierung ist ein Planungsziel, keine zusätzliche Anbietersperre. Auswahl über die Oberfläche oder `?variant=diamond` beziehungsweise `?variant=segments`.

Gewählt und nativ umgesetzt: zusätzliche grüne Raute am unteren Balkenrand, eine gemeinsame Legende unten. Der Wert liegt bei allen Rauten auf der senkrechten Mittellinie, beim halben Symbol auf der Schnittkante, auch bei 0 und 100 %. Arbeitsplanwerte stehen nur im Popover. Der Arbeitsplan ist pro Konto standardmäßig aus. Im Kontoeditor lassen sich Wochentage und Uhrzeiten einstellen. Voreinstellung ist Mo/Di/Do/Fr 08:00–13:30 Uhr. Das Verhältnis zwischen 5-Stunden- und Wochenkontingent stammt aus dem Verbrauchsverlauf des jeweiligen Kontos. Ohne ausreichende Messwerte gibt es nur ein zeitbasiertes Wochenziel. Die HTML-Dateien bleiben isolierte Entwürfe; native Ansichten lassen sich mit `swift run Juicebar --render-previews --language=de` prüfen.

## Soll-Markierung

`http://localhost:4318/pace-marker-prototype.html?variant=C` vergleicht dieselbe Raute mit Abstand, 25 % und 50 % Überlappung. Helle und dunkle Karten, verstellbarer Rest- und Sollstand. A–C per Karte oder Pfeiltasten. Die Prozentangabe bezieht sich auf die Höhe der Raute. Gewählt: C mit 50 % Überlappung. In Übersicht und Popover liegt die Rautenmitte auf der oberen Balkenkante.
