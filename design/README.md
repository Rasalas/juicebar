# Menüleisten-Prototyp

Frage: Welche Darstellung zeigt mehrere Anbieter gleichzeitig am lesbarsten in einer 24-Pixel-Menüleiste?

Vier vorläufige Varianten: horizontale Fülllinien, vertikale Doppellinien, segmentierte Skalen und Prozentzahlen mit Unterstrich. Feste Reihenfolge Codex, Claude, OpenCode Go, weiterer Anbieter. Mit zwei/vier Konten, Anbieterfarben/Monochrom und Normal-/Leer-/Offline-Zuständen vergleichbar.

```sh
python3 -m http.server 4318 --bind 127.0.0.1 --directory design
```

Dann `http://localhost:4318/menubar-prototype.html?variant=A` öffnen. Die HTML-Datei funktioniert auch direkt ohne Server. A–D über die Pfeile unten, Tastatur oder Vergleichskarten wählen. Keine Live-Daten, keine Änderungen an Konten, kein Speichern von Einstellungen. Die Datei ist ausschließlich ein Entscheidungsprototyp und gehört nicht ins App-Bundle.

B wurde nach Rückmeldung zu farbigen Limitlinien ohne Namen und Prozentzahlen geändert. Eine Linie pro vorhandenem Limit, fest gruppiert nach Anbieter, optionales Modelllimit und anklickbare Detailvorschau. Feinauswahl noch offen. Nach Auswahl wird die Darstellung in Swift/AppKit umgesetzt. Das Projekt ist momentan kein Git-Repository; deshalb gibt es noch keinen separaten Prototyp-Branch.

## Soll-Markierung

`http://localhost:4318/pace-marker-prototype.html?variant=C` vergleicht dieselbe Raute mit Abstand, 25 % und 50 % Überlappung. Helle und dunkle Karten, verstellbarer Rest- und Sollstand. A–C per Karte oder Pfeiltasten. Die Prozentangabe bezieht sich auf die Höhe der Raute. Gewählt: C mit 50 % Überlappung. In Übersicht und Popover liegt die Rautenmitte auf der oberen Balkenkante.
