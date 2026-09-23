# Muusy Island v1.5.0

Eine systemweite Musiksteuerung für Windows 11 mit nativer Glass-Oberfläche,
Mediensteuerung, Queue, App-Schnellzugriff und Browser-Bridge.

## Changes

- YouTube Music in **Google Chrome**, **Opera** und **Opera GX**
- Spotify und VLC über die Windows-Mediensteuerung
- Einstellungen für Darstellung, Wiedergabe und App-Schnellzugriffe
- Kompakte Waveform für die Wiedergabe
- Play/Pause, vorheriger und nächster Titel auch bei minimiertem Browser
- Queue-Vorschau und Like/Dislike für YouTube Music
- Globale Hotkeys, Lautstärke per Mausrad, Profile und optionaler Autostart
- Island durch Ziehen auf das eingeblendete X schließen
- Einfache Installation mit `Install-MuusyIsland.bat`, Startmenü- und Desktop-Verknüpfung
- Automatische Wiederverbindung der Browser-Bridge bei bestehendem YouTube-Music-Tab

## Sicherheitsänderung

Die lokale Browser-Bridge prüft den Ursprung der Anfrage und verlangt einen
versionsgebundenen Header. Größe der Anfragen und erlaubte Cover-Quellen sind
begrenzt.

**Wichtig:** Eine ältere Erweiterung muss nach dem Update in der jeweiligen
Browser-Erweiterungsseite neu geladen werden. Version 1.4 kann nicht mit dem
gehärteten v1.5-Host kommunizieren.

## Installation

1. `Muusy-Island-v1.5.0.zip` entpacken.
2. `Install-MuusyIsland.bat` doppelklicken.
3. Im gewünschten Browser die passende Bridge als entpackte Erweiterung laden:
   - Chrome: `Chrome Bridge`
   - Opera: `Opera Bridge`
   - Opera GX: `Opera GX Bridge`
4. Den YouTube-Music-Tab neu laden.

Windows kann beim ersten Start vor einem unbekannten PowerShell-Skript warnen.
Das Projekt ist quelloffen; Skript und native C#-Hilfsklasse liegen vollständig
im Archiv.
