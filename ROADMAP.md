# PalmierPro Roadmap — 12 Monate

Priorisierung: Q1 schließt die Table-Stakes, die Nutzer sofort vermissen. Q2 baut Audio & Finishing aus. Q3 liefert die AI-Differenzierung. Q4 Ökosystem und Politur. Jedes Feature erscheint am selben Tag als MCP-Tool mit strukturierten Receipts.

Alle Features laufen on-device oder über BYO-Keys (OpenRouter, ElevenLabs, Google AI). Keine Abhängigkeit von Palmier-Cloud-Diensten.

## Quartal 1 — Editing Table-Stakes (Monate 1–3)

| Monat | Feature | Umfang |
|---|---|---|
| 1 | Transition-Bibliothek | Cross Dissolve, Dip to Black/White, Wipe, Slide, Push als echte Timeline-Items; Metal-Kernel; MCP `add_transition`; Standard-Dauer + Alignment (centered/start/end) |
| 1–2 | Timeline-Marker | Farbige Marker, Chapter-Marker (→ YouTube-Kapitel im Export), To-do-Marker; MCP-Tool; `review_timeline`-Findings als Marker ablegen |
| 2 | Speed Ramping | Time-Remap-Kurve als Keyframe-Property, Optical-Flow-Frame-Blending, pitch-korrigiertes Audio; nutzt das bestehende Easing-System |
| 2–3 | Adjustment Layers | Clip-Typ `adjustment` auf Video-Tracks, wendet Grade + Effekte auf alles darunter an |
| 3 | Render-Cache | Hintergrund-Pre-Render effektlastiger Segmente, Invalidierung über bestehende Mutation-Deltas |
| 3 | J/L-Cut-Shortcuts + Safe-Area-Guides | Link-Offset-Trim per Modifier-Drag; Title/Action-Safe-Overlays im Preview |

## Quartal 2 — Audio & Finishing (Monate 4–6)

| Monat | Feature | Umfang |
|---|---|---|
| 4 | Audio-Mixing-Grundausstattung | Pan, 3-Band-EQ, Kompressor/Limiter pro Clip/Track; LUFS-Metering mit Plattform-Presets (−14 YouTube, −16 Podcast) |
| 4–5 | Auto-Ducking | Musik automatisch unter Sprache absenken via vorhandener SpeechVAD; nicht-destruktive Volume-Automation |
| 5 | AI Audio Assistant | Agent-Tool `mix_audio`: analysiert Timeline, setzt Pegel, Ducking, Mastering in einem Schritt — vollständig on-device |
| 5–6 | Stabilisierung | Vision-Framework-Homographie-Analyse, Smooth-Faktor, Crop-Anzeige; Analyse-Bake wie Denoise |
| 6 | Proxy-Workflow | Automatische Proxy-Medien bei Import (opt-in), transparenter Toggle, Export immer Full-Res |
| 6 | User-Presets | Speicherbare Looks, Effekt-Stacks und Text-Styles als lokale Bibliothek |

## Quartal 3 — AI-Differenzierung (Monate 7–9)

| Monat | Feature | Umfang |
|---|---|---|
| 7 | Motion Tracking | Punkt/Planar-Tracker on-device (Vision Framework), Ergebnis = Keyframes auf Position/Scale/Corner-Pin |
| 7–8 | Trackbare AI-Masken | Subject Key → verfeinerbare, über Zeit getrackte Maske pro Objekt; Basis für selektive Grades und Objekt-Effekte |
| 8 | Auto Reframe nativ | Subjekt-Tracking + Crop-Keyframes on-device; ein Klick 16:9→9:16; MCP-Tool für Batch-Reframe |
| 8–9 | Long→Short Auto-Clipping | Transkript + Beat + `review_timeline` finden Highlights, erzeugen Vertical-Timelines mit Captions; Tool `create_clips_from_longform` |
| 9 | AI Multicam SmartSwitch | Speaker-ID steuert `change_cam` automatisch; ein Tool-Call schneidet ein ganzes Interview |
| 9 | Generative Extend | Letzter Frame + Videomodell über BYO-Key → Clip um n Frames verlängern |

## Quartal 4 — Ökosystem & Politur (Monate 10–12)

| Monat | Feature | Umfang |
|---|---|---|
| 10–11 | Direct Publishing | Export → YouTube/TikTok/Instagram direkt über deren APIs, mit Chapter-Markern, Plattform-LUFS und Auto-Reframe-Varianten |
| 11 | Lokale Preset-Pakete | Motion-Scenes, Looks, Caption-Styles als teilbare Dateipakete (Import/Export ohne Server) |
| 12 | Performance- & Stabilitäts-Release | Instruments-Pass über Playback/Scrubbing, Thread-Sanitizer-Sweep, Benchmarks mit 1h+ Timelines, Bugfix-Puffer |

## Bewusst nicht enthalten

- Palmier-Cloud-Features (Kollaboration/Cloud-Sync, Community-Marktplatz, Cloud-only-Modelle wie Eye Contact)
- Spatial Video, Windows-Port, Node-Compositing, VST-Hosting
