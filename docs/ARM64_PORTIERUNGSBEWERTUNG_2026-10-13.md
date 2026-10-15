# Bloodborne auf Apple Silicon: Was ein nativer ARM64-Port bedeuten würde

Bewertung vom 13. Oktober 2026 anhand des lokalen Arbeitsstands. Nur Analyse und Bericht; keine Implementierung, Builds oder neuen Benchmarks.

**Meine Einschätzung:** Einen ARM64-nativen Renderer zu entwickeln ist technisch plausibel und als begrenztes Vorhaben untersuchbar. Das vollständige Spiel ohne Rosetta auszuführen erfordert zusätzlich eine eigene oder integrierte x86-64-Ausführungsschicht oder eine weitreichende statische Übersetzung des Spielprogramms. Für einen klassischen Quellcode-Port fehlen hier die Quellen der Bloodborne-Engine. Ein solcher Ausbau kann CPU-Aufwand reduzieren, garantiert aber keine höhere FPS-Rate, solange die GPU den Ablauf begrenzt.

**1. Vier unterschiedliche Ziele**

| Ziel | Was tatsächlich nativ wird | Was weiterhin übersetzt wird | Bedeutung für dieses Projekt |
|---|---|---|---|
| ARM64-Renderer neben dem bisherigen Spielprozess | Command Processing, Ressourcenverwaltung, Shadercompiler und MoltenVK-Ansteuerung im neuen Prozess | Spiel und bisherige Runtime durch Rosetta | Begrenztester Weg, einen wesentlichen Teil der CPU-Arbeit nativ auszuführen |
| ARM64-Anwendung mit integriertem x86-Übersetzer | Eigene Runtime, Renderer und die Ausführungsumgebung | Der ursprüngliche Spielcode durch den neuen Übersetzer | Rosetta-frei; weiterhin CPU-Binärübersetzung |
| Vorab nach ARM64 übersetztes Spiel, AOT | Vorab erzeugter ARM64-Code plus native Runtime/Renderer | Eventuell nicht vorab aufgelöste Pfade über einen Fallback | Spielbezogenes Recompiler-Projekt mit hohem Verifikationsaufwand |
| Vollständiger Quellcode-Port | Engine, Runtime und Renderer aus portierbaren Quellen gebaut | Keine allgemeine x86-Ausführung mehr nötig | Mit diesem Repository allein nicht verfügbar; setzt Originalquellen oder Rekonstruktion voraus |

Auch ein vollständig ARM64-nativer CPU-Pfad braucht weiterhin die Umsetzung der PS4-Grafikbefehle und GCN-Shader für die Apple-GPU. **ARM64 und Metal sind getrennte Entscheidungen.** Ein nativer ARM64-Prozess kann zunächst den bestehenden Vulkan-/MoltenVK-Pfad verwenden. Ein direkter Metal-Backend ist ein weiteres Projekt.

**2. Die grundlegende Hürde: Der Spielcode ist ein geladenes x86-Programm**

Das Repository enthält keine neu kompilierbare Bloodborne-Engine. `prepare.py` verlangt ein x86-64-ELF und übernimmt dessen Segmente in ein Speicherabbild. Der Loader ruft die Initialisierungsfunktionen der eingebundenen Module und anschließend den ursprünglichen Spieleinstieg direkt auf. Schon der Build von `probe.c` wird außerhalb von x86-64 ausdrücklich verhindert. [ELF-Prüfung](../scripts/prepare.py#L30), [Architekturprüfung](../src/probe.c#L11), [Module und Spieleinstieg](../src/probe.c#L368), [Einordnung im README](../README.md#L134).

Das Umstellen der eigenen C/C++-Dateien auf `arm64` übersetzt dieses separat geladene Spielprogramm nicht mit. Ebenso kann eine ARM64-Version von `libbbgpu` nicht einfach in den bisherigen Rosetta-Prozess geladen werden: Apple unterstützt diese Mischung von ARM64- und x86-64-Modulen nicht. [Apple: Rosetta-Prozessmodell](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment?changes=_7).

Ein eigener Übersetzer in einem ARM64-Prozess wäre dagegen grundsätzlich möglich: Das x86-Spiel wird dabei als Gastprogramm interpretiert oder in ausführbaren ARM64-Code umgewandelt. Das ist eine andere Ausführungsarchitektur als das heutige direkte Aufrufen von Gastadressen.

**3. Konkrete Abhängigkeiten im aktuellen Code**

| Bereich | Befund | Erforderliche Arbeit |
|---|---|---|
| Loader | x86-Architekturprüfung, CPUID/AVX-Prüfung, Stackwechsel in x86-Assembler, direkte Sprünge ins Spiel | Gastzustand und Ausführungsdispatcher statt direkter Funktionsaufrufe; ARM64-Einstieg für eigenen Code |
| Funktionsaufrufe | `ABI` ist `sysv_abi`; Gastcallbacks sind direkt aufrufbare Funktionspointer | Brücken zwischen Gast-ABI und Apple-ARM64-ABI für Argumente, Rückgaben und Rückrufe |
| Threads und TLS | FS-/GS-Instruktionen werden gepatcht; Threadstart ruft `t->entry` direkt | Pro Thread einen Gastregisterzustand und Gast-TLS verwalten; Eintritt/Rückkehr über den Übersetzer |
| Hooks und Spielpatches | x86-Sprungbytes, `int3`, Änderungen an RIP/RSP und Code-Stubs | Hooks als Übersetzeroperationen oder ARM64-Brücken abbilden; Gastcodeänderungen invalidieren übersetzte Blöcke |
| Signal- und Speicherbehandlung | Registerauswertung mit x86-`ucontext`, 4-KiB-Verfolgungsraster | Host-PC auf Gast-PC abbilden; Host-Seitenschutz und logisches Gast-Raster trennen |
| Renderer-Hilfsfunktionen | x86-Pause-/Zeitstempelinstruktionen in Warteschleifen und Statistiken | Portable Warte-/Zeitfunktionen oder ARM64-Implementierungen |
| Shader-Ressourcenanalyse | Generiert auf der CPU x86-Maschinencode mit Xbyak; ARM-Pfad fehlt | Ressourcen-Walker portabel interpretieren oder ARM64-Codegenerator bauen |
| Cache | Speichert ausführbare Ressourcen-Walker mit ab | Cache nach Hostarchitektur und Codegenerator-Version trennen oder neutralen Zwischenstand speichern |
| Abhängigkeiten | Buildskripte bauen für x86-64 und schneiden MoltenVK auf x86-64 zu | Eigener ARM64-Abhängigkeitsbaum und unabhängige Buildziele |

Besonders relevant ist der **Ressourcen-Walker im Shadercompiler**: `FlattenExtendedUserdataPass` erzeugt kleine CPU-Programme, die die vom Spiel referenzierten Shader-Ressourcentabellen durchlaufen. Die Nicht-x86-Version enthält lediglich einen Abbruch mit „unimplemented for target architecture“. Dieser Pfad betrifft bereits einen allein portierten Renderer, unabhängig von einer Übersetzung der Spiel-CPU. Ein langsamer, portabler Referenz-Walker wäre der sichere Einstieg; danach könnte ein ARM64-JIT dieselbe Semantik beschleunigen. [Codegenerator](../gpu/shadps4/shader_recompiler/ir/passes/flatten_extended_userdata_pass.cpp#L636), [Fehlender ARM-Pfad](../gpu/shadps4/shader_recompiler/ir/passes/flatten_extended_userdata_pass.cpp#L863), [Cacheinhalt](../gpu/shadps4/video_core/renderer_vulkan/vk_pipeline_serialization.cpp#L503).

Weitere Belege: [Gast-ABI](../src/runtime.h#L13), [Threadstart](../src/runtime_thread.c#L241), [TLS-Patches](../scripts/link_libc.py#L160), [x86-Hooks](../gpu/shim/bbport_guest_hooks.cpp#L155), [Warteschleifen](../gpu/shadps4/video_core/renderer_vulkan/vk_draw_pipe.h#L191), [Speicherraster](../gpu/shadps4/video_core/page_manager.cpp#L59), [Abhängigkeiten](../macos/build-deps.sh#L92).

Nicht jede x86-Fundstelle bedeutet eine Neuentwicklung. Beispielsweise besitzt `BitArray` für seine AVX2-Optimierung bereits einen skalaren Fallback. Große Teile des PM4-Decoders, der Ressourcenlogik und des Shader-Zwischencodes sind wiederverwendbare C++-Logik. Der Port muss diese Infrastruktur nicht vollständig ersetzen. [Vorhandener Fallback](../gpu/shadps4/common/bit_array.h#L90), [PM4-Abstraktion](../gpu/cp/cp_decoder.h#L4).

**4. Variante A: Spiel unter Rosetta, Renderer in einem ARM64-Prozess**

Eine plausible Aufteilung wäre:

```text
x86-Prozess unter Rosetta           ARM64-Rendererprozess
Spiel + spielnahe Runtime           PM4-Verarbeitung + Ressourcen
Gast-Hooks und Schreibverfolgung    Shadercompiler + Vulkan/MoltenVK
             │                                  │
             └── Befehlsblöcke, gemeinsamer ──────┘
                 Speicher, Fertigmeldungen
```

Der native Teil könnte den vorhandenen Vulkan-Renderer weitgehend behalten. Die MoltenVK-Distribution wird im aktuellen Build bereits als Universal-Bibliothek bezogen und dann auf x86-64 reduziert; für den neuen Prozess würde die ARM64-Variante verwendet. [MoltenVK-Buildschritt](../macos/build-deps.sh#L92).

Die schwierige Arbeit wäre die **Prozessgrenze**:

- Gastadressen, Hostpointer und GPU-Adressen müssen unterscheidbar werden. Ein Zeiger aus dem Spielprozess ist im Rendererprozess nicht automatisch gültig. Geteilte Speicherbereiche brauchen eine Abbildung über Offsets oder explizite Adressübersetzung.
- Befehle sollten als zusammenhängende PM4-Blöcke beziehungsweise größere Pakete übertragen werden. Ein synchroner Prozessaufruf pro Draw würde unnötige Latenz erzeugen.
- CPU-Schreibzugriffe, Descriptoränderungen, Buffer-Wiederverwendung, GPU-Fences und End-of-Pipe-Labels müssen in beiden Prozessen korrekt geordnet sein. Shared Memory allein löst diese Synchronisation nicht.
- Eingabe, Fenster, Videoausgabe und spielseitige Rückmeldungen benötigen klare Zuständigkeiten. Fehler oder ein Absturz des Renderers dürfen das Spiel nicht unbegrenzt warten lassen.

Die vorhandene C-Schnittstelle ist dafür noch kein fertiges Protokoll: `bbgpu_resolve()` liefert direkte Funktionsadressen, und Fault-Handling reicht native `ucontext`-Zeiger weiter. Ebenso enthält der PM4-Decoder lokale Pointer und Spans. `BbCp::Sink` bietet eine brauchbare Stelle für die Entkopplung, muss für die Prozessgrenze aber ergänzt werden. [GPU-Schnittstelle](../gpu/bbgpu.h#L27), [Funktionsauflösung](../gpu/shim/bbgpu.cpp#L331), [Decoder-Schnittstelle](../gpu/cp/cp_decoder.h#L127).

**Bewertung:** Der sinnvollste begrenzte Versuch für native Renderer-CPU-Leistung. Der Nutzen hängt davon ab, wie viel Zeit tatsächlich im eigenen Renderer und in MoltenVK auf der CPU verloren geht. Das eigentliche Spiel bleibt Rosetta-abhängig. Auch zusätzliche Speicherabbildungen und Kommunikationsarbeit können den Gewinn aufzehren.

**5. Variante B: ARM64-Runtime mit integriertem x86-Übersetzer**

Hier bleiben Runtime und Renderer im selben nativen Prozess. Die x86-Instruktionen des Spiels laufen über einen Interpreter oder einen dynamischen Übersetzer, der Blöcke nach ARM64 kompiliert. Gastaufrufe bekannter PS4-Funktionen wechseln über definierte Brücken direkt in die native Runtime. So könnten Prozesse und Pointer einfacher zusammenbleiben als bei Variante A, dafür müsste die CPU-Ausführung grundlegend neu gebaut werden.

Der Übersetzer müsste mehr beherrschen als normale Integer-Instruktionen:

- x86-Flags, indirekte Sprünge, Funktionspointer, Stackverhalten und Gastregister;
- die im Spiel eingesetzten SIMD-/AVX- und Bitmanipulationsinstruktionen mit korrekter Semantik;
- mehrere Gastthreads, Atomics und x86-Speicherordnung;
- Gast-TLS, native Funktionsaufrufe und Rückrufe vom Host ins Spiel;
- Faults, Codepatches und Invalidierung bereits übersetzter Blöcke;
- mögliche Ausnahme-/Unwind- und Kontextwechselpfade, deren tatsächliche Nutzung separat zu erheben wäre.

Die ARM-Speicherordnung ist dabei ein wesentliches Risiko: Ein auf x86 korrekt laufender Gastzugriff darf nicht allein deshalb anders sichtbar werden, weil der Host Load-/Store-Operationen anders ordnen kann. Korrekt übersetzte Atomics und erforderliche Barrieren kosten wiederum Laufzeit. Die eigene C++-Synchronisation und die Semantik des fremden Gastprogramms sind getrennte Prüfaufgaben. [Apple: Architekturunterschiede](https://developer.apple.com/documentation/Apple-Silicon/addressing-architectural-differences-in-your-macos-code?changes=l_2%2Cl_2), [Arm: Synchronisation und Speicherordnung](https://developer.arm.com/community/arm-community-blogs/b/servers-and-cloud-computing-blog/posts/synchronization-overview-and-case-study-on-arm-architecture-563085493).

Bestehende Projekte wie FEX oder Box64 wären Forschungsgrundlagen. Ihre dokumentierten Einsatzpfade sind jedoch auf andere Umgebungen ausgerichtet, insbesondere Linux; sie bieten keine hier nachgewiesene, unmittelbar einsetzbare Einbettung für dieses PS4-Gastprogramm unter macOS. QEMU besitzt etablierte Übersetzungstechnik, daraus folgt ebenfalls keine fertige, performante Integration für bbport. Eine Kandidatenprüfung müsste insbesondere macOS-Hostsupport, Einbettbarkeit, ISA-Abdeckung, Multithreading und Gast-/Host-Brücken testen. [FEX](https://github.com/FEX-Emu/FEX), [Box64](https://github.com/ptitSeb/box64/blob/main/README.md), [QEMU-Ausführungsmodelle](https://www.qemu.org/docs/master/about/).

Auf Apple Silicon braucht neu erzeugter ausführbarer Code außerdem eine passende JIT-Speicherstrategie mit Schreib-/Ausführungsschutz und Instruction-Cache-Synchronisation. Bestehende RWX-Patches können nicht unverändert übernommen werden. Details hängen unter anderem vom Hardened Runtime-Modell ab. [Apple: JIT-Portierung](https://developer.apple.com/documentation/Apple-Silicon/porting-just-in-time-compilers-to-apple-silicon).

**Bewertung:** Rosetta-Unabhängigkeit ist erreichbar als Architekturziel. Ein neuer Übersetzer wäre aber nicht automatisch schneller als Rosetta. Für die vollständige Spiel-CPU kann er zunächst sogar langsamer sein; der Vorteil wäre vor allem die native Ausführung der eigenen Runtime und Grafikseite sowie die Kontrolle über die Übersetzung.

**6. Variante C: Spielcode vorab nach ARM64 übersetzen**

Ein spielbezogener AOT-Recompiler würde die unterstützte Version des `eboot` und die benötigten Module analysieren, in eine Zwischenrepräsentation überführen und daraus ARM64-Code erzeugen. Die feste Spielversion und bereits bekannten Import-/Patchstellen helfen: Es muss nicht jedes beliebige PS4-Programm unterstützt werden.

Die wesentlichen Aufgaben bleiben jedoch groß:

1. **Kontrollfluss erfassen:** Code von Daten unterscheiden, indirekte Sprungziele und virtuelle Funktionsaufrufe auflösen. Nur beobachtete Pfade zu übersetzen deckt selten besuchte Spielbereiche nicht ab.
2. **Gastadressen erhalten:** Gespeicherte Funktionspointer, Rücksprungadressen und Inline-Daten müssen weiterhin das vom Spiel erwartete Verhalten haben. Eine Abbildung von Gast-PC zu ARM64-Code und ein Resolver für indirekte Ziele wären nötig.
3. **ABI sauber überbrücken:** PS4-Strukturen und Gastobjekte dürfen nicht einfach durch gleichnamige macOS-Strukturen ersetzt werden. Apple ARM64 hat eigene Regeln für Register, Stack, variable Argumentlisten und bestimmte Datentypen. [Apple: ARM64-ABI](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms?changes=_1).
4. **Module und Patches integrieren:** Auch eingebundene PS4-libc-/Fios-Module sind x86-Code. Man müsste sie ebenfalls übersetzen oder ihre benötigte Funktionalität kompatibel ersetzen. Binäre FPS- und Auflösungspatches müssen vor der Übersetzung berücksichtigt oder auf semantische Eingriffe umgestellt werden.
5. **Fehlende Pfade behandeln:** Ein Interpreter/JIT als Fallback erhöht die erreichbare Abdeckung, erhält aber eine zusätzliche Ausführungsschicht. Ohne Fallback muss jeder erreichbare Pfad korrekt übersetzt sein.

Der Umweg über generiertes C oder LLVM beseitigt diese Probleme nicht. Ein Compiler kann aus einer korrekten Zwischenrepräsentation ARM64 erzeugen; die korrekte Rekonstruktion des ursprünglichen Verhaltens ist die eigentliche Aufgabe. AOT kann weiterhin Gastregister, Speicherprüfungen und Dispatcher enthalten und deshalb langsamer sein als ein ursprünglicher Quellcode-Port.

**Bewertung:** Für langfristige Unabhängigkeit interessant, für kurzfristige FPS-Optimierung hochriskant. Ein vollständig rekonstruierter, idiomatischer Engine-Quellcode wäre noch einmal wesentlich aufwendiger.

**7. Welchen FPS-Gewinn darf man erwarten?**

Aus der statischen Analyse lässt sich kein belastbarer Faktor nennen. Native ARM64-Ausführung kann CPU-Arbeit für Befehlsverarbeitung, Ressourcenbindung und Hilfsfunktionen reduzieren. Sie reduziert nicht automatisch die GPU-Arbeit für Shader, Texturzugriffe oder Renderpass-Load/Store.

Ein vereinfachtes, rein hypothetisches Beispiel verdeutlicht die Grenze:

| Beispielzustand | Kritischer CPU-Pfad | GPU-Zeit | Vereinfachte überlappte Bildzeit | FPS |
|---|---:|---:|---:|---:|
| Ausgangspunkt | 30 ms | 40 ms | 40 ms | 25 |
| CPU beschleunigt | 15 ms | 40 ms | 40 ms | 25 |
| GPU beschleunigt | 30 ms | 20 ms | 30 ms | 33 |
| CPU und GPU beschleunigt | 15 ms | 20 ms | 20 ms | 50 |

Das Modell verwendet näherungsweise `max(CPU-Zeit, GPU-Zeit)`. Echte Warteketten, Submission-Latenz, gemeinsame Bandbreite und thermische Grenzen machen es komplexer. Die Zahlen sind **keine Bloodborne-Messung**. Gerade beim lüfterlosen Air könnte geringere CPU-Arbeit indirekt die Dauerleistung verbessern; auch das ist zu messen.

Die wichtigste wirtschaftliche Frage lautet deshalb: **Ist genügend vermeidbare CPU-Zeit auf dem kritischen Pfad vorhanden, um die Portierung zu rechtfertigen?** Dafür reicht die Gesamtauslastung des Prozesses nicht. Spielthreads, Renderer, MoltenVK-Encoding und GPU-Wartezeit müssen getrennt betrachtet werden. Die im früheren Bericht beschriebenen alten FPS-Werte sind kein Nachweis für die Leistung eines ARM64-Prototyps; der lokale Rendererstand wurde inzwischen außerdem weiter verändert.

**8. Grobe Größenordnung des Vorhabens**

Die folgenden Angaben sind meine vorläufigen Planungsgrößen, keine ausgemessene Aufwandsschätzung. Annahme: ein kleines, erfahrenes Team von etwa zwei bis drei Personen mit Kenntnissen in Grafik, macOS-Systemprogrammierung und gegebenenfalls Binärübersetzung; zunächst nur die bereits unterstützte Spielversion. Vollständige Spieltests und seltene Kompatibilitätsfehler können den Umfang erheblich verlängern. Die Zeilen sind alternative beziehungsweise aufeinander aufbauende Ziele und dürfen nicht einfach addiert werden.

| Ergebnis | Vorläufiger Planungshorizont | Größte Unsicherheit |
|---|---|---|
| Architekturprüfung, repräsentative Aufzeichnung und kleiner ARM64-Test | Etwa 2–6 Wochen | Reproduzierbare Daten und Abgrenzung der Gastabhängigkeiten |
| Nativer Renderer spielt ausgewählte aufgezeichnete Szenen korrekt ab | Etwa 1–3 Monate | Ressourcen-Walker, Speicherzugriffe, Architekturannahmen |
| Integrierter, im Spiel brauchbarer separater ARM64-Renderer | Mehrere Monate; grob 3–9 Monate | Prozessübergreifende Speicher- und Synchronisationskorrektheit |
| Rosetta-freier Spielpfad mit integriertem Übersetzer | Eher 1–2 Jahre oder länger bis robust spielbar | Verwendbarer Übersetzerkern, ISA-/ABI-Abdeckung, Threading und Performance |
| Vollständiger AOT-/rekonstruierter Spielport | Langfristiges Vorhaben bis hin zu mehreren Jahren | Kontrollflussabdeckung und vollständige Verhaltensgleichheit |

Ein erster Menübildschirm kann erheblich früher erscheinen als ein stabiler Port. Aus einem erfolgreichen Start folgt noch keine verlässliche Laufzeit in Kämpfen, DLC-Gebieten, seltenen Animationen oder beim Laden und Speichern. Für einen Entwickler ohne entsprechende Spezialisierung sind die kurzen Bereiche der Schätzungen keine realistische Zusage.

**9. Empfohlener Entscheidungsweg**

Ich würde die ARM64-Frage zuerst mit einem **separaten Renderer-Replay-Prototyp** beantworten. Dieser könnte CPU-Architektur und GPU-Backend zunächst isolieren, bevor die vollständige Prozesskommunikation gebaut wird.

1. Einen repräsentativen Frame beziehungsweise eine kurze Sequenz samt benötigten PM4-Daten, Shadern, Ressourcen und Zustandsänderungen reproduzierbar aufzeichnen. Eine bereits vollständig decodierte Drawliste allein würde den Decoderanteil nicht messen.
2. Denselben Ablauf unter x86/Rosetta und nativem ARM64 abspielen, mit gleichem MoltenVK-Backend und gleichen GPU-Einstellungen. Den Ressourcen-Walker zunächst korrekt portieren; den Gewinn nicht mit einer gleichzeitig veränderten Grafikqualität vermischen.
3. CPU-Zeit, GPU-Zeit, Speicherverkehr, Bildgleichheit und Bedarf an Gast-Rückmeldungen vergleichen. Danach die Zusatzkosten einer echten Shared-Memory-/Prozessverbindung messen.
4. Nur bei einem relevanten Gewinn auf dem kritischen Pfad den nativen Renderer integrieren. Wenn die GPU weiter dominiert, Renderpassplanung und Ressourcenverkehr priorisieren.
5. Einen vollständigen CPU-Übersetzer oder AOT-Recompiler nur dann als eigenes Ziel verfolgen, wenn Rosetta-Unabhängigkeit den erheblichen Aufwand auch ohne garantierten FPS-Sprung rechtfertigt.

**Empfehlung für dieses Repository:** ARM64 zunächst als gezielte Auslagerung und Portierung der Renderer-CPU-Arbeit untersuchen. Für einen vollständig nativen Bloodborne-Spielpfad müsste das Projekt zusätzlich die Ausführung des fremden Spielprogramms übernehmen. Diese zweite Aufgabe ist wesentlich größer und sollte erst nach einem erfolgreichen, messbaren Renderer-Prototyp budgetiert werden.
