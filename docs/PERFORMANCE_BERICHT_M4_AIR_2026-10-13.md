# Bloodborne auf dem MacBook Air M4: Performance-Bericht

Stand: 13. Oktober 2026. Grundlage: lokaler Arbeitsstand auf Commit `3c57da4`, einschließlich der bereits vorhandenen, nicht eingecheckten macOS-Anpassungen.

**Ergebnis:** Der größte plausible Hebel liegt im Renderablauf: weniger Unterbrechungen zusammengehöriger Renderdurchläufe, weniger unnötige Synchronisation und geringerer Aufwand pro Draw. Niedrigere Auflösung hilft bereits, reicht nach den dokumentierten Messungen allein aber nicht für stabile 30 FPS. Ein vollständig nativer ARM64-Port ist ein separates Architekturvorhaben. Für den vorhandenen Port würde ich zunächst **stabile 30 FPS bei 720p interner Auflösung als Entwicklungsziel** wählen. Ob das erreichbar ist, muss erst durch korrekte Messungen und Prototypen nachgewiesen werden; 60 FPS lassen sich derzeit nicht seriös zusagen.

Es wurde ausschließlich gelesen und dieser Bericht erstellt. Keine Implementierung, Konfigurationsänderung, Kompilierung oder neue Spielmessung wurde durchgeführt. Die Empfehlungen sind nach erwarteter Relevanz priorisiert, nicht nach bereits nachgewiesenem FPS-Gewinn.

**1. Was „nativ“ hier bedeutet**

Der aktuelle Pfad ist:

```text
Bloodborne-Spielcode (x86-64) + bbport-Runtime/Renderer (x86-64)
                         ↓ Rosetta 2
                  Apple-M4-CPU

PS4-Grafikbefehle / GCN-Shader
          ↓ bbport: Vulkan / SPIR-V
          ↓ MoltenVK: Metal / Metal-Shading-Language
                  Apple-M4-GPU
```

Das ist eine lokale macOS-Anwendung mit Grafikberechnung auf der Apple-GPU. Die Spiel-CPU-Seite und der eigene Renderer sind jedoch keine ARM64-Binaries. Das Buildskript setzt ausdrücklich `-arch x86_64` und `CMAKE_OSX_ARCHITECTURES=x86_64`; der vorhandene CMake-Cache bestätigt dies. [Buildskript](../macos/build.sh#L13), [Buildkonfiguration](../macos/out/gpu/CMakeCache.txt#L203).

Ein einfaches Umstellen auf ARM64 funktioniert nicht: Das mitgeladene Spiel bleibt x86-64, und die Runtime setzt unter anderem x86-Registerzustände voraus. Apple unterstützt unter Rosetta keine Mischung von ARM64- und x86-64-Modulen innerhalb desselben Prozesses. Ein nativer Metal-Renderer würde außerdem nicht automatisch die CPU-Übersetzung beseitigen. [Plattformanpassungen](../gpu/shim/bbport_platform.h#L40), [Apple-Dokumentation zur Prozessarchitektur](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment?changes=_7).

Die vorhandenen Klinik-Messungen beziehen sich laut Übergabedokument auf einen M4 mit **10 GPU-Kernen und 16 GB gemeinsamem Speicher**. Für eine Variante mit 8 GPU-Kernen sind die Werte nicht direkt übertragbar. Apple nennt für das 13-Zoll-Modell beide GPU-Varianten und 120 GB/s Speicherbandbreite. CPU und GPU teilen sich Speicher und Bandbreite; die Loganzeige „16384 MiB VRAM“ bedeutet hier keinen zusätzlichen dedizierten Grafikspeicher. Das Air ist lüfterlos, weshalb Dauerleistung separat betrachtet werden muss. [Lokaler Hardwarebezug](../macos/HANDOFF.md#L8), [Apple: technische Daten](https://support.apple.com/en-us/122209), [Apple: lüfterloses Design](https://www.apple.com/newsroom/2025/03/apple-introduces-the-new-macbook-air-with-the-m4-chip-and-a-sky-blue-color/).

**2. Was die vorhandenen Zahlen tatsächlich aussagen**

Die folgende Tabelle übernimmt die Werte aus dem lokalen Übergabedokument. Sie wurden für diesen Bericht nicht neu gemessen; vollständige Rohdaten, identische Startbedingungen und thermische Vergleichbarkeit sind damit nicht verifiziert. [Messnotizen](../macos/HANDOFF.md#L13).

| Dokumentierte Konfiguration in der Klinik | FPS, ungefähr | Abgeleitete Zeit pro Bild |
|---|---:|---:|
| Ursprünglicher Stand, 1080p | 4,5 | 222 ms |
| Argument Buffers aus und GPU-Labels aus, 1080p | 7,7–8,5 | 118–130 ms |
| Zusätzlich 1280 × 720 intern | 11 | 91 ms |
| Zusätzlich Schatten, Motion Blur, DoF und SSAO aus | 14 | 71 ms |
| Separater Versuch mit 320 × 180 intern; übrige Einstellungen nicht vollständig dokumentiert | 18 | 56 ms |

30 FPS erfordern höchstens 33,3 ms pro Bild, 60 FPS höchstens 16,7 ms. Ausgehend von 14 FPS wären für 30 FPS noch rund **53 % weniger Bildzeit** erforderlich. Auch der Versuch mit 320 × 180 liegt deutlich oberhalb des 30-FPS-Budgets. Das spricht für erheblichen Aufwand, der nicht allein mit der Pixelzahl verschwindet.

Das Dokument nennt außerdem etwa 27 Renderunterbrechungen pro Bild durch `FlushBarriers`, etwa 62 vorgezogene Compute-Dispatches ohne bisherigen FPS-Gewinn und einen Test ohne Draws mit etwa 40 FPS. Diese Angaben sind nützliche Hinweise, aber keine neuen Messungen. Der Versuch ohne Draws ist insbesondere keine belastbare CPU-Obergrenze des vollständigen Spiels. [Weitere Messnotizen](../macos/HANDOFF.md#L23).

Die vorhandenen `run7.log` bis `run10.log` enthalten nur etwa 5–18 Draws pro Bild in ihren FPS-Stichproben. Daraus lässt sich kein repräsentativer Klinik- oder Kampfbenchmark ableiten. Die bis etwa 95 FPS in `run10.log` widersprechen den Klinikwerten deshalb nicht automatisch. Beispiel.

**3. Prioritäten**

| Priorität | Maßnahme | Erwarteter Nutzen | Aufwand / Unsicherheit |
|---|---|---|---|
| P0 | GPU-Messung korrigieren und Referenzläufe definieren | Verhindert Optimierung anhand falscher Engpässe | Klein bis mittel; Messproblem belegt |
| P1 | Unnötige Renderunterbrechungen durch Barrieren vermeiden | Größter plausibler Hebel für GPU-Zeit und Bandbreite | Mittel bis hoch; Synchronisationskorrektheit entscheidend |
| P1 | Command-Buffer-Segmentierung auf Apple-GPUs abstimmen | Weniger künstliche Passgrenzen | Kleine A/B-Versuche, mittlerer Implementierungsaufwand |
| P1 | 16×-Filteranhebung und Effektkosten prüfen | Geringere Textur- und Pixelkosten | Kleine Versuche; Qualitätsabwägung |
| P2 | Speicherduplikate und Threadzahl an Unified Memory/M4 anpassen | Weniger Kopien, CPU-Arbeit und Energieverbrauch | Mittel; tatsächliche Laufzeitkosten fehlen |
| P2 | Release/LTO, Pipeline-Cache und Shader-Hotspots prüfen | CPU-Effizienz und weniger Ruckler | Klein bis mittel; eher ergänzend |
| P3 | MetalFX, eigener Metal-Pfad oder ARM64-Rendererprozess | Strategisches Potenzial | Hoch bis sehr hoch; Gewinn offen |

**4. P0: Der GPU-Profiler ist derzeit keine verlässliche Referenz**

Es gibt einen konkreten Fehler in der Messgrundlage: `GpuProfiler` legt vier Bereiche mit jeweils 4096 Queries in **einem** Query-Pool an. Das ergibt 16384 Zeitstempel. Im vorhandenen Log lehnt Metal den daraus entstehenden 131072-Byte-Puffer ab und nennt als Obergrenze 32768 Byte. MoltenVK fällt daraufhin ausdrücklich auf emuliertes Verhalten zurück. [Poolgröße](../gpu/shadps4/video_core/renderer_vulkan/vk_gpu_profiler.h#L64), [Poolanlage](../gpu/shadps4/video_core/renderer_vulkan/vk_gpu_profiler.cpp#L22), Fehlermeldung.

Dazu passen die anschließenden Ausgaben: nahezu die ganze Zeit wird „between submissions: GPU idle“ zugeschlagen, während die eigentlichen Pässe mit 0 ms erscheinen. Daraus darf man keinen weitgehend unbeschäftigten Grafikchip ableiten. Die aktuelle Apple-spezifische Verschiebung der Zeitstempelzuordnung löst die übergroße Poolanlage nicht. Profiler-Ausgabe, [Apple-Zuordnung](../gpu/shadps4/video_core/renderer_vulkan/vk_gpu_profiler.cpp#L84).

Außerdem ruft `WriteTimestamp()` selbst `EndRendering()` auf. Die Passmarkierung versucht bereits, nur an Passwechseln zu messen; trotzdem müssen zusätzliche Unterbrechungen durch andere Markierungen und Transfers geprüft werden. Der Profiler kann also gerade die untersuchte Passstruktur beeinflussen. [Zeitstempel-Aufzeichnung](../gpu/shadps4/video_core/renderer_vulkan/vk_gpu_profiler.cpp#L35), [Passmarkierung](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L4848).

Empfehlung für spätere Arbeiten: Query-Pools passend begrenzen oder aufteilen, Überläufe sichtbar machen und den Hardware-Fallback explizit erfassen. Danach Profiling an/aus vergleichen. Bis dahin sollte eine Metal-System-Trace die GPU-Auslastung und Encoderzeiten gegenprüfen. Auch die im Übergabedokument genannten 86 % GPU-Auslastung und 105 ms GPU-Zeit bleiben hier historische Angaben, deren zugrunde liegende Trace nicht geprüft wurde. [Apple: GPU-Zeitleiste](https://developer.apple.com/documentation/xcode/analyzing-apple-gpu-performance-using-a-visual-timeline).

**5. P1: Zusammengehörige Renderarbeit länger in einem Pass halten**

Der Code bestätigt den wesentlichen Mechanismus: `Runtime::FlushBarriers()` beendet bei vorhandenen Barrieren den laufenden Renderpass. Der Drawpfad ruft diese Funktion bei `needs_barrier` auf und eröffnet den Pass vor dem Draw wieder. Gleichzeitig verwenden sämtliche Farb-, Tiefen- und Stencil-Attachments im Scheduler `storeOp = Store`; beim Fortsetzen werden die Inhalte erneut geladen. [Barrieren](../gpu/shadps4/video_core/renderer_vulkan/vk_runtime.cpp#L884), [Drawpfad](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L1695), [Erneuter Passbeginn](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L1800), [Load/Store](../gpu/shadps4/video_core/renderer_vulkan/vk_scheduler.cpp#L214).

Bei einem G-Buffer mit mehreren Farbausgaben und Tiefe kann das zusätzlichen Transfer zwischen schnellem internem Tile-Speicher und gemeinsamem Hauptspeicher verursachen. Die genaue Menge hängt unter anderem von Formaten, Kompression und tatsächlichen Metal-Passgrenzen ab. Apples Empfehlungen bestätigen, dass möglichst wenig Load-/Store-Verkehr für diese Architektur wichtig ist. [Apple: Metal-Optimierung](https://developer.apple.com/videos/play/wwdc2020/10632/).

Ich würde die Ursachen in dieser Reihenfolge untersuchen:

1. **Falsche beziehungsweise zu grobe Abhängigkeiten:** `AccessBuffer()` rundet reine Lesezugriffe auf 4-KiB-Bereiche auf. Der Kommentar bestätigt, dass dies zusätzliche Barrieren erzeugen kann. Ein späterer Schreibzugriff auf andere Bytes derselben Seite kann damit unnötig einen Pass beenden. Der vorhandene Schalter `CoarseReadTracking` erlaubt einen gezielten Vergleich zwischen weniger CPU-Verwaltungsaufwand und weniger GPU-Unterbrechungen. [Bereichsverfolgung](../gpu/shadps4/video_core/renderer_vulkan/vk_runtime.cpp#L840).
2. **Globale Zugriffe:** Große, über Seitentabellen adressierte Buffer setzen beim Binden bedingungslos `needs_barrier = true`; globale Schreibzugriffe machen nachfolgende Bufferprüfungen pauschal abhängig. Engere, nachweisbar vollständige Zugriffsbereiche könnten helfen. Dieser direkte Zuweisungspfad wird vom vorhandenen `BbDiagTag` nicht erfasst und muss bei der Auswertung zusätzlich berücksichtigt werden. [Paged Buffer](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L3269), [Globale Abhängigkeit](../gpu/shadps4/video_core/renderer_vulkan/vk_runtime.cpp#L810).
3. **Bildübergänge vorbereiten:** Textur-Uploads und Layoutwechsel möglichst vor den gemeinsamen Pass verschieben, sofern Datenabhängigkeiten, Aliasing und Lebensdauer dies erlauben. Das ist besonders interessant für erst spät gebundene Texturen, die von früheren Draws des Passes unabhängig sind. [Texturübergänge](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L3594).
4. **Vorhandenes Dispatch-Hoisting verbessern:** Die Funktion prüft bereits gelesene und geschriebene Gastbereiche. Sie fügt aber um jeden vorgezogenen Dispatch breite Barrieren ein. Abhängige Compute-Gruppen und Barrieren könnten gegebenenfalls gemeinsam geplant werden. Bildzugriffe und unbekannte Bereiche müssen konservativ bleiben. Der bisher dokumentierte Versuch bringt noch keinen FPS-Gewinn. [Hoisting](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L2107).

Ein wichtiger Vorbehalt zur Idee im Übergabedokument: Ein Metal-`memoryBarrierWithScope` lässt sich nicht einfach als allgemeine Vulkan-Barriere innerhalb des aktuellen dynamischen Renderpasses einsetzen. Dafür gelten Feature-, Stage-, Access- und Layoutbeschränkungen. Die verwendeten breiten Compute-/Buffer-Abhängigkeiten passen nicht beliebig in einen solchen Pass. Zuerst unnötige Abhängigkeiten vermeiden oder gültig vorziehen; einen speziellen Backendpfad separat entwerfen. [Vulkan-Synchronisationsregeln](https://docs.vulkan.org/spec/latest/chapters/synchronization.html).

Ebenso wäre ein pauschales `DontCare` für alle Attachments falsch: G-Buffer und Tiefe werden später weiterverwendet. Load/Store darf nur entfallen, wenn vollständiges Überschreiben oder das Ende der Nutzung bewiesen ist. Ein späterer Metal-Pfad könnte mehr dieser Lebensdauerinformationen ausnutzen. [Apple: Load-/Store-Aktionen](https://developer.apple.com/documentation/Metal/customizing-render-pass-setup).

**6. P1: Parallelisierung verursacht eigene Passgrenzen**

Der Scheduler verwendet standardmäßig 64 KiB pro Segment und teilt innerhalb eines Renderpasses ab dem Doppelten, also rund 128 KiB aufgezeichneter Befehlsdaten. `MaybeSplit()` beendet dazu ausdrücklich den Pass. Bei zwei oder mehr Recording-Threads kann somit die CPU-Parallelisierung zusätzliche GPU-Arbeit erzeugen. Diese Bytezahl beschreibt interne Aufzeichnungsdaten, nicht die Größe der Texturen. [Standardwerte](../gpu/shadps4/video_core/renderer_vulkan/vk_scheduler.cpp#L125), [Aufteilung](../gpu/shadps4/video_core/renderer_vulkan/vk_scheduler.cpp#L533).

Sinnvolle spätere A/B-Versuche sind `BB_VK_RECORD_THREADS=1` sowie größere `BB_VK_SEGMENT_KB`-Werte mit mehreren Threads. Der in den Notizen vorgeschlagene Wert `100000` eignet sich als Diagnose, um diese Teilungen praktisch zu unterdrücken; er ist kein begründeter Dauerstandard. Der bessere Entwurf wäre eine Aufteilung bevorzugt an ohnehin notwendigen Passgrenzen, mit begrenzter Warteschlange und gemessener CPU-Auslastung.

Mehr Vulkan-Recording-Threads beseitigen außerdem nicht automatisch den MoltenVK-Aufwand beim Übersetzen einer Queue nach Metal. Das Projekt verwendet bereits asynchrone Queue-Submits und deaktivierte Argument Buffers. Diese Einstellungen sind schon Teil der dokumentierten Verbesserung von 4,5 auf etwa 8 FPS und dürfen nicht nochmals als neuer Gewinn verbucht werden. Die MoltenVK-Dokumentation beschreibt Argument Buffers normalerweise als vorteilhaft; die lokale Abweichung muss deshalb an diesem Spiel und dieser Treiberversion überprüft werden. [Aktive Standards](../macos/run.sh#L55), [MoltenVK-Konfiguration](https://github.com/KhronosGroup/MoltenVK/blob/v1.4.2/Docs/MoltenVK_Configuration_Parameters.md).

**7. P1/P2: Grafikqualität gezielt gegen Kosten abwägen**

Ein bislang wenig sichtbarer Kandidat ist `ForceAnisotropy()`: Ohne explizite Einstellung hebt der Renderer geeignete Sampler auf **16× anisotrope Filterung** an. Das ist zusätzliche Qualität mit möglichen Texturkosten. `BB_ANISO=0` deaktiviert diese Anhebung und erhält die Originalwerte des Spiels. `BB_ANISO=4` ist eine niedrigere Mindestanhebung, keine harte Obergrenze für bereits stärkere Spiel-Sampler. Diese Varianten sollten vor aufwendigen Architekturänderungen verglichen werden. Ein konkreter FPS-Gewinn ist noch nicht belegt. [Filterung](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L3674).

Als Ausgangspunkt für spätere Messungen empfehle ich 1280 × 720 intern, zunächst ohne temporales Upscaling, danach einen getrennten Vergleich mit FSR 3.1 bei gleicher interner Auflösung und höherer Ausgabeauflösung. Dadurch werden Einsparung durch weniger Pixel und Zusatzkosten des Upscalers getrennt sichtbar. Der vorhandene Startpatch für die Renderauflösung ist auf diesem Gerät besonders interessant; der macOS-Startpfad bevorzugt ihn bereits gegenüber laufender Skalierung über Proxy-Renderziele. [Auflösungswahl](../macos/run.sh#L26), [Upscaler-Pfade](../gpu/shadps4/video_core/renderer_vulkan/vk_temporal_upscaler.cpp#L199).

Schatten, SSAO, Tiefenunschärfe und Motion Blur anschließend einzeln vergleichen. Die dokumentierten 11 auf 14 FPS zeigen nur den gemeinsamen Effekt des Abschaltens; sie sagen nicht, welche Option den größten Anteil hat. Für ein späteres Spielprofil sollte die Bildwirkung mitbewertet werden, insbesondere bei Schatten. Tessellation und RectList sind nach den vorhandenen Abschaltversuchen vorerst niedriger priorisiert.

FSR 4 ist keine naheliegende Sofortlösung: Der aktuelle Code verlangt unter anderem Compute-Derivatives, die im vorhandenen MoltenVK-Log als nicht verfügbar erscheinen. FSR 3.1 besitzt bereits einen integrierten Pfad. Ein späterer MetalFX-Vergleich ist technisch interessant, weil Farb-, Tiefen- und Bewegungsdaten im Projekt bereits erzeugt werden; GPU-Interop, Synchronisation und Zusatzkopien müssen dabei mitgemessen werden. Eine schnellere MetalFX-Ausführung ist hier unbewiesen. [FSR-Prüfung](../gpu/shadps4/video_core/renderer_vulkan/vk_instance.h#L313), Gerätelog, [Apple: MetalFX](https://developer.apple.com/documentation/metalfx?changes=_10&language=objc).

**8. P2: Speicher, Threads und Build auf den M4 abstimmen**

Der Port nutzt bereits importierten Hostspeicher und `BB_GUEST_IN_PLACE=1`. Eine pauschale Empfehlung „Zero-Copy einschalten“ wäre damit zu spät. Interessant ist vielmehr, welche zusätzlichen Spiegel, Uploads und Schreibüberwachungen trotzdem aktiv bleiben. `LayerWatchEnabled()` ist standardmäßig aktiv, sofern Schreibfallen verfügbar sind, und wurde unter anderem gegen die Kosten importierten Speichers auf diskreten GPUs entwickelt. Auf Unified Memory muss der Nutzen dieser Zusatzkopien neu bewertet werden. Texturkonvertierungen und Synchronisation bleiben trotz gemeinsamem Speicher notwendig. [macOS-Speichermodell](../macos/run.sh#L44), [Spiegelungsstrategie](../gpu/shadps4/video_core/buffer_cache/buffer_cache_layer.cpp#L410).

Zu messen wären Kopierbytes pro Bild, tatsächlicher physischer Speicherbedarf, GPU-Allokationen, Kompression/Swap und die Anzahl der dadurch ausgelösten Passunterbrechungen. Besonders auf 16 GB relevant: Der automatische Auflösungspfad setzt `BB_DMEM_MB` auf 9152 MiB, während der Runtime-Standard 5056 MiB beträgt. Das ist eine Poolgrenze und nicht automatisch vollständig belegter RAM. Trotzdem sollte geprüft werden, ob niedrige Auflösungen diesen größeren Pool benötigen. [Poolwahl](../macos/run.sh#L35), [Runtime-Grenze](../src/runtime_memory.c#L21).

Für zehn verfügbare CPU-Threads erzeugt die Drawvorbereitung standardmäßig fünf Worker plus Scanner, zusätzlich zu Recording-, Spiel- und weiteren Hilfsthreads. Der M4 hat vier Performance- und sechs Effizienzkerne. Die macOS-Anpassung setzt für Hintergrundarbeit bereits Utility-QoS; die Linux-Affinitätsfunktionen legen auf dem Mac jedoch keine echten Kernbindungen fest. Vergleiche mit `BB_PREP_WORKERS=2`, `3` und `5` sowie ein oder zwei Recording-Threads sind sinnvoll. Weniger Threads könnten Energieverbrauch oder Konkurrenz senken, aber auch die GPU schlechter versorgen. [Workeranzahl](../gpu/shadps4/video_core/renderer_vulkan/vk_draw_prep.cpp#L50), [macOS-Scheduling](../gpu/shim/bbport_platform.h#L57).

Der vorhandene Build ist bereits optimiert (`RelWithDebInfo`, Runtime `-O2`), also kein einfacher Debug-Build. LTO ist im macOS-Skript und CMake-Cache allerdings aus; ein Vergleich mit LTO wäre ein überschaubarer späterer Schritt. PGO ist ausdrücklich deaktiviert, und die allgemeine PGO-Konfiguration müsste für die eingesetzte Apple-Clang-Toolchain geprüft werden. Diese Änderungen betreffen vor allem CPU-Arbeit und beheben keine GPU-Load/Store-Probleme. [Buildoptionen](../macos/build.sh#L24), [Allgemeine Optimierungsoptionen](../gpu/CMakeLists.txt#L13).

Shader-/Pipeline-Vorwärmung und Cache-Wiederverwendung verbessern vor allem Ruckler beim ersten Auftreten von Material oder Effekten. Shader-Caching ist im Projekt schon vorhanden. Erst wenn ein korrekter GPU-Trace einzelne Shader als teuer zeigt, würde ich deren SPIR-V-/MSL-Ausgabe, Registerdruck, Speicherzugriffe und geeignete reduzierte Präzision gezielt untersuchen. Ungeprüftes globales Fast-Math oder pauschale Präzisionsreduktion ist keine begründete Optimierung.

**9. Was ein nativer ARM64-/Metal-Ausbau kosten würde**

| Architektur | Was sie verbessert | Wesentlicher Aufwand | Einschätzung |
|---|---|---|---|
| Bestehender Rosetta-/MoltenVK-Pfad mit besserer Passplanung | GPU-Speicherverkehr und Aufzeichnungsaufwand | Scheduler, Ressourcenabhängigkeiten, Messung | Zuerst verfolgen |
| Eigener Metal-Renderer im bisherigen Prozess | Direkte Kontrolle über Encoder, Attachments und Bindings | Neuer Grafikbackend, Shaderpfad und Funktionsparität | Langfristiger Kandidat; CPU bleibt übersetzt |
| Separater ARM64-Rendererprozess | Eigener Renderer und Treiberansteuerung laufen ohne x86-Übersetzung | Prozessprotokoll, gemeinsamer Speicher, Ressourcenlebensdauer, Fences und Rückmeldungen | Erst bei belegtem CPU-Übersetzungsengpass prototypisieren |
| Vollständiger ARM64-Spielpfad | Auch das Spiel benötigt keine Rosetta-Ausführung | Übersetzung/Reimplementierung des ursprünglichen Spielcodes und Runtime-Anpassungen | Eigenständiges, sehr großes Projekt |

Ein separater ARM64-Prozess müsste Befehle gebündelt erhalten; ein synchroner Prozessaufruf pro Draw würde voraussichtlich einen neuen Engpass schaffen. Aktuell liest der Renderer Gastadressen direkt, etwa beim Auswerten der Copy-Shader-Kontrollliste. Diese Pointer können nicht unverändert als prozessübergreifendes Protokoll dienen. Auch GPU-Labels, CPU-Schreibzugriffe und Ressourcen-Recycling müssten korrekt über die Prozessgrenze funktionieren. [Direkte Gastzugriffe](../gpu/shadps4/video_core/renderer_vulkan/vk_rasterizer.cpp#L2075).

Ein Metal-Neubau sollte erst gegen einen bereinigten MoltenVK-Pfad bewertet werden. Er kann unnötige Übersetzungsarbeit reduzieren, garantiert aber weder 30 noch 60 FPS und beseitigt teure Shader oder schlechten Passaufbau nicht automatisch.

Zur Zieldefinition gehört außerdem vollständige Darstellung: Der aktuelle Pipeline-Code überspringt Draws mit nicht unterstützter Geometry-Shader-Stufe. Höhere FPS durch fehlende Objekte oder Effekte wären kein erfolgreicher Port. Die betroffenen Draws und sichtbaren Konsequenzen müssten erfasst und bei Bedarf korrekt ersetzt werden. [Übersprungene Shaderstufe](../gpu/shadps4/video_core/renderer_vulkan/vk_pipeline_cache.cpp#L947).

**10. Konkreter Prüfablauf für eine spätere Umsetzung**

1. **Referenz festhalten:** Commit plus lokale Änderungen, Binary-Version, MoltenVK-Version, macOS-Version, GPU-Kernzahl, RAM, sämtliche Einstellungen und identischer Spielstand/Kameraposition. Klinik, Außenbereich mit vielen Gegnern und Effekt-/Boss-Szene getrennt prüfen.
2. **Messung validieren:** Hardware-Zeitstempel ohne Fallback; Metal-Trace zur Gegenprüfung. Diagnoseausgaben und Instrumentierung separat bewerten. CPU-Statistiken wie `0.00 us/draw` nicht ungeprüft übernehmen: Einige Thread-CPU-Zeitfunktionen sind im macOS-Shim ausdrücklich nicht implementiert. [Statistikgrenze](../gpu/shim/bbport_platform.h#L84).
3. **Zuerst isolierte Vergleiche:** Segmentierung/Recording-Threads, Filteranhebung, präzise versus grobe Bereichsverfolgung, anschließend Effekte und Auflösung. Pro Variante mindestens drei vergleichbare Läufe; Shadercache für Dauer-FPS vorwärmen, Erstlauf-Ruckler gesondert messen.
4. **Danach gezielte Änderungen:** Häufigste unnötige Passunterbrechungen beseitigen. Pro Änderung Encoderanzahl, Load-/Store-Verkehr, GPU-Bildzeit, CPU-Zeit im kritischen Pfad sowie Durchschnitt und p95/p99 der Bildzeiten vergleichen. Zeitersparnisse verschiedener Maßnahmen nicht ungeprüft addieren.
5. **Dauerlast bewerten:** Identische Bedingungen am Netzteil, dokumentierter Energiemodus, anschließend 20–30 Minuten Last auf dem Air. Speicher, thermischen Zustand und Bildzeitverlauf erfassen. Kurzfristige Spitzen-FPS sind kein ausreichendes Erfolgskriterium.
6. **Bild und Spielverhalten absichern:** Gleiche Kameraansichten, Bewegungen, Kämpfe, Partikel, Schatten, UI, Laden und Speichern prüfen. Besonders Barrieren, Hoisting und Speicheränderungen können verzögerte oder nur szenenabhängige Fehler erzeugen.

Das erste belastbare Zwischenziel wäre eine korrekte, deutlich verkürzte GPU-Bildzeit bei unveränderter Szene. Erst wenn der vollständige Ablauf unter das 33,3-ms-Budget fällt, lohnt ein dauerhaftes 30-FPS-Profil mit sauberem Frame-Pacing. Für stabile 60 FPS müsste dieselbe Szene unter 16,7 ms bleiben. Dafür liefert der geprüfte Stand derzeit keinen Nachweis.
