# Muusy Island v1.5.0

Eine systemweite Musiksteuerung für Windows 11 mit nativer Glass-Oberfläche,
Mediensteuerung, Queue, App-Schnellzugriff und Browser-Bridge.

## Highlights

- YouTube Music in **Google Chrome**, **Opera** und **Opera GX**
- Spotify und VLC über die Windows-Mediensteuerung
- Neue, deutlich einfachere Einstellungen mit drei übersichtlichen Bereichen
- Neue kompakte Musik-Waveform
- Play/Pause, vorheriger und nächster Titel auch bei minimiertem Browser
- Queue-Vorschau und Like/Dislike für YouTube Music
- Globale Hotkeys, Lautstärke per Mausrad, Profile und optionaler Autostart
- Cleanes Drag-to-close: Island nach unten auf das eingeblendete X ziehen
- Einfache Installation mit `Install-MuusyIsland.bat`, Startmenü- und Desktop-Verknüpfung

## Sicherheitsänderung

Die lokale Browser-Bridge wurde für v1.5 neu abgesichert. Fremde Webseiten
können nicht mehr auf Songdaten oder Steuerbefehle zugreifen. Zusätzlich sind
Payload-Größe und Cover-Quellen begrenzt.

**Wichtig:** Eine ältere Erweiterung muss nach dem Update in der jeweiligen
Browser-Erweiterungsseite neu geladen werden. Version 1.4 kann nicht mit dem
gehärteten v1.5-Host kommunizieren.

## Installation

1. `Muusy-Island-v1.5.0.zip` entpacken.
2. `Install-MuusyIsland.bat` doppelklicken.
3. Im gewünschten Browser die passende Bridge als entpackte Erweiterung laden:
   - Chrome: `Chrome Bridge`
   - Opera: `Opera Bridge`
   - Opera GX: `Entpackte Browser-Erweiterung`
4. Den YouTube-Music-Tab neu laden.

Windows kann beim ersten Start vor einem unbekannten PowerShell-Skript warnen.
Das Projekt ist quelloffen; Skript und native C#-Hilfsklasse liegen vollständig
im Archiv.
