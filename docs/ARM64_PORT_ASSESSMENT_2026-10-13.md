# Bloodborne on Apple Silicon: What a Native ARM64 Port Would Mean

Assessment of 13 October 2026, based on the local working state. Analysis and report only; no implementation, builds or new benchmarks.

**My assessment:** Building an ARM64-native renderer is technically plausible and can be investigated as a bounded project. Running the complete game without Rosetta additionally requires its own or an integrated x86-64 execution layer, or extensive static translation of the game program. For a classic source-code port, the sources of the Bloodborne engine are missing here. Such an effort can reduce CPU work, but it does not guarantee a higher frame rate as long as the GPU limits the pipeline.

**1. Four different goals**

| Goal | What actually becomes native | What is still translated | Meaning for this project |
|---|---|---|---|
| ARM64 renderer next to the existing game process | Command processing, resource management, shader compiler and MoltenVK control in the new process | Game and existing runtime through Rosetta | Most limited way to run a substantial part of the CPU work natively |
| ARM64 application with integrated x86 translator | Own runtime, renderer and the execution environment | The original game code through the new translator | Rosetta-free; still CPU binary translation |
| Game translated to ARM64 ahead of time, AOT | Pre-generated ARM64 code plus native runtime/renderer | Possibly paths not resolved ahead of time, through a fallback | Game-specific recompiler project with high verification effort |
| Full source-code port | Engine, runtime and renderer built from portable sources | General x86 execution no longer needed | Not available with this repository alone; requires original sources or reconstruction |

Even a fully ARM64-native CPU path still needs the translation of the PS4 graphics commands and GCN shaders for the Apple GPU. **ARM64 and Metal are separate decisions.** A native ARM64 process can initially use the existing Vulkan/MoltenVK path. A direct Metal backend is another project.

**2. The fundamental obstacle: the game code is a loaded x86 program**

The repository does not contain a recompilable Bloodborne engine. `prepare.py` requires an x86-64 ELF and copies its segments into a memory image. The loader calls the initialization functions of the linked modules and then the original game entry point directly. Even the build of `probe.c` is explicitly prevented on anything other than x86-64. [ELF check](../scripts/prepare.py#L30), [Architecture check](../src/probe.c#L11), [Modules and game entry point](../src/probe.c#L368), [Classification in the README](../README.md#L134).

Switching the project's own C/C++ files to `arm64` does not translate this separately loaded game program. Likewise, an ARM64 version of `libbbgpu` cannot simply be loaded into the existing Rosetta process: Apple does not support this mix of ARM64 and x86-64 modules. [Apple: Rosetta process model](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment?changes=_7).

A translator of its own inside an ARM64 process would be possible in principle: the x86 game is then interpreted as a guest program or converted into executable ARM64 code. That is a different execution architecture from today's direct calling of guest addresses.

**3. Concrete dependencies in the current code**

| Area | Finding | Required work |
|---|---|---|
| Loader | x86 architecture check, CPUID/AVX check, stack switch in x86 assembly, direct jumps into the game | Guest state and an execution dispatcher instead of direct function calls; ARM64 entry point for own code |
| Function calls | `ABI` is `sysv_abi`; guest callbacks are directly callable function pointers | Bridges between the guest ABI and the Apple ARM64 ABI for arguments, return values and callbacks |
| Threads and TLS | FS/GS instructions are patched; thread start calls `t->entry` directly | Manage a guest register state and guest TLS per thread; enter and return through the translator |
| Hooks and game patches | x86 jump bytes, `int3`, changes to RIP/RSP and code stubs | Map hooks to translator operations or ARM64 bridges; invalidate translated blocks when guest code changes |
| Signal and memory handling | Register evaluation with x86 `ucontext`, 4 KiB tracking grid | Map host PC to guest PC; separate host page protection from the logical guest grid |
| Renderer helper functions | x86 pause/timestamp instructions in wait loops and statistics | Portable wait/time functions or ARM64 implementations |
| Shader resource analysis | Generates x86 machine code on the CPU with Xbyak; no ARM path | Interpret the resource walkers portably or build an ARM64 code generator |
| Cache | Also stores executable resource walkers | Separate the cache by host architecture and code generator version, or store an architecture-neutral intermediate state |
| Dependencies | Build scripts build for x86-64 and trim MoltenVK to x86-64 | Own ARM64 dependency tree and independent build targets |

The **resource walker in the shader compiler** is particularly relevant: `FlattenExtendedUserdataPass` generates small CPU programs that traverse the shader resource tables referenced by the game. The non-x86 version contains only an abort with "unimplemented for target architecture". This path already affects a renderer ported on its own, independent of any translation of the game CPU. A slow, portable reference walker would be the safe starting point; an ARM64 JIT could then accelerate the same semantics. [Code generator](../gpu/shadps4/shader_recompiler/ir/passes/flatten_extended_userdata_pass.cpp#L636), [Missing ARM path](../gpu/shadps4/shader_recompiler/ir/passes/flatten_extended_userdata_pass.cpp#L863), [Cache contents](../gpu/shadps4/video_core/renderer_vulkan/vk_pipeline_serialization.cpp#L503).

Further evidence: [Guest ABI](../src/runtime.h#L13), [Thread start](../src/runtime_thread.c#L241), [TLS patches](../scripts/link_libc.py#L160), [x86 hooks](../gpu/shim/bbport_guest_hooks.cpp#L155), [Wait loops](../gpu/shadps4/video_core/renderer_vulkan/vk_draw_pipe.h#L191), [Memory grid](../gpu/shadps4/video_core/page_manager.cpp#L59), [Dependencies](../macos/build-deps.sh#L92).

Not every x86 finding means new development. For example, `BitArray` already has a scalar fallback for its AVX2 optimization. Large parts of the PM4 decoder, the resource logic and the shader intermediate code are reusable C++ logic. The port does not have to replace this infrastructure completely. [Existing fallback](../gpu/shadps4/common/bit_array.h#L90), [PM4 abstraction](../gpu/cp/cp_decoder.h#L4).

**4. Variant A: game under Rosetta, renderer in an ARM64 process**

A plausible split would be:

```text
x86 process under Rosetta           ARM64 renderer process
Game + game-adjacent runtime        PM4 processing + resources
Guest hooks and write tracking      Shader compiler + Vulkan/MoltenVK
             │                                  │
             └── Command blocks, shared ────────┘
                 memory, completion messages
```

The native part could largely keep the existing Vulkan renderer. The MoltenVK distribution is already obtained as a universal library in the current build and then reduced to x86-64; for the new process, the ARM64 variant would be used. [MoltenVK build step](../macos/build-deps.sh#L92).

The difficult work would be the **process boundary**:

- Guest addresses, host pointers and GPU addresses must become distinguishable. A pointer from the game process is not automatically valid in the renderer process. Shared memory regions need a mapping through offsets or explicit address translation.
- Commands should be transferred as contiguous PM4 blocks or larger packets. A synchronous process call per draw would add unnecessary latency.
- CPU writes, descriptor changes, buffer reuse, GPU fences and end-of-pipe labels must be ordered correctly in both processes. Shared memory alone does not solve this synchronization.
- Input, window, video output and game-side feedback need clear responsibilities. An error or a crash of the renderer must not make the game wait indefinitely.

The existing C interface is not yet a finished protocol for this: `bbgpu_resolve()` returns direct function addresses, and fault handling passes native `ucontext` pointers along. The PM4 decoder likewise contains local pointers and spans. `BbCp::Sink` offers a usable place for decoupling, but it must be extended for the process boundary. [GPU interface](../gpu/bbgpu.h#L27), [Function resolution](../gpu/shim/bbgpu.cpp#L331), [Decoder interface](../gpu/cp/cp_decoder.h#L127).

**Assessment:** The most sensible bounded attempt for native renderer CPU performance. The benefit depends on how much CPU time is actually lost in the renderer itself and in MoltenVK. The game itself stays dependent on Rosetta. Additional memory mappings and communication work can also consume the gain.

**5. Variant B: ARM64 runtime with integrated x86 translator**

Here, runtime and renderer stay in the same native process. The game's x86 instructions run through an interpreter or a dynamic translator that compiles blocks to ARM64. Guest calls to known PS4 functions switch directly into the native runtime through defined bridges. This could keep processes and pointers together more easily than in Variant A, but CPU execution would have to be rebuilt from the ground up.

The translator would have to handle more than ordinary integer instructions:

- x86 flags, indirect jumps, function pointers, stack behavior and guest registers;
- the SIMD/AVX and bit-manipulation instructions used in the game, with correct semantics;
- multiple guest threads, atomics and x86 memory ordering;
- guest TLS, native function calls and callbacks from the host into the game;
- faults, code patches and invalidation of already translated blocks;
- possible exception/unwind and context-switch paths, whose actual use would have to be determined separately.

ARM memory ordering is a major risk here: a guest access that runs correctly on x86 must not become visible differently merely because the host can order loads and stores differently. Correctly translated atomics and the required barriers in turn cost run time. The project's own C++ synchronization and the semantics of the foreign guest program are separate verification tasks. [Apple: Architectural differences](https://developer.apple.com/documentation/Apple-Silicon/addressing-architectural-differences-in-your-macos-code?changes=l_2%2Cl_2), [Arm: Synchronization and memory ordering](https://developer.arm.com/community/arm-community-blogs/b/servers-and-cloud-computing-blog/posts/synchronization-overview-and-case-study-on-arm-architecture-563085493).

Existing projects such as FEX or Box64 would be research foundations. Their documented deployment paths, however, target other environments, in particular Linux; they offer no immediately usable embedding for this PS4 guest program under macOS that has been shown to work here. QEMU has established translation technology, but this likewise does not imply a finished, performant integration for bbport. A candidate evaluation would have to test macOS host support, embeddability, ISA coverage, multithreading and guest/host bridges in particular. [FEX](https://github.com/FEX-Emu/FEX), [Box64](https://github.com/ptitSeb/box64/blob/main/README.md), [QEMU execution models](https://www.qemu.org/docs/master/about/).

On Apple Silicon, newly generated executable code also needs a suitable JIT memory strategy with write/execute protection and instruction-cache synchronization. Existing RWX patches cannot be taken over unchanged. Details depend, among other things, on the Hardened Runtime model. [Apple: Porting JIT compilers](https://developer.apple.com/documentation/Apple-Silicon/porting-just-in-time-compilers-to-apple-silicon).

**Assessment:** Rosetta independence is achievable as an architecture goal. A new translator would not automatically be faster than Rosetta, however. For the complete game CPU it may even be slower at first; the advantage would mainly be native execution of the project's own runtime and graphics side, plus control over the translation.

**6. Variant C: translate the game code to ARM64 ahead of time**

A game-specific AOT recompiler would analyze the supported version of the `eboot` and the required modules, convert them into an intermediate representation and generate ARM64 code from it. The fixed game version and the already known import/patch sites help: not every arbitrary PS4 program has to be supported.

The main tasks nevertheless remain large:

1. **Capture control flow:** Distinguish code from data, resolve indirect jump targets and virtual function calls. Translating only observed paths rarely covers seldom visited parts of the game.
2. **Preserve guest addresses:** Stored function pointers, return addresses and inline data must still behave as the game expects. A mapping from guest PC to ARM64 code and a resolver for indirect targets would be needed.
3. **Bridge the ABI cleanly:** PS4 structures and guest objects must not simply be replaced by macOS structures of the same name. Apple ARM64 has its own rules for registers, stack, variable argument lists and certain data types. [Apple: ARM64 ABI](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms?changes=_1).
4. **Integrate modules and patches:** The linked PS4 libc/Fios modules are also x86 code. They would likewise have to be translated, or their required functionality replaced compatibly. Binary FPS and resolution patches must be taken into account before translation or converted to semantic interventions.
5. **Handle missing paths:** An interpreter/JIT as a fallback increases the achievable coverage but retains an additional execution layer. Without a fallback, every reachable path must be translated correctly.

The detour through generated C or LLVM does not remove these problems. A compiler can generate ARM64 from a correct intermediate representation; correctly reconstructing the original behavior is the actual task. AOT can still contain guest registers, memory checks and dispatchers and can therefore be slower than a true source-code port.

**Assessment:** Interesting for long-term independence, highly risky for short-term FPS optimization. A fully reconstructed, idiomatic engine source code would be substantially more effort still.

**7. What FPS gain can be expected?**

No reliable factor can be derived from the static analysis. Native ARM64 execution can reduce CPU work for command processing, resource binding and helper functions. It does not automatically reduce GPU work for shaders, texture accesses or render pass load/store.

A simplified, purely hypothetical example illustrates the limit:

| Example state | Critical CPU path | GPU time | Simplified overlapped frame time | FPS |
|---|---:|---:|---:|---:|
| Starting point | 30 ms | 40 ms | 40 ms | 25 |
| CPU accelerated | 15 ms | 40 ms | 40 ms | 25 |
| GPU accelerated | 30 ms | 20 ms | 30 ms | 33 |
| CPU and GPU accelerated | 15 ms | 20 ms | 20 ms | 50 |

The model uses approximately `max(CPU time, GPU time)`. Real wait chains, submission latency, shared bandwidth and thermal limits make it more complex. The numbers are **not a Bloodborne measurement**. On the fanless Air in particular, less CPU work could indirectly improve sustained performance; this too has to be measured.

The most important economic question is therefore: **Is there enough avoidable CPU time on the critical path to justify the port?** The overall utilization of the process is not sufficient for this. Game threads, renderer, MoltenVK encoding and GPU wait time must be considered separately. The old FPS values described in the earlier report are no evidence for the performance of an ARM64 prototype; the local renderer state has also been changed further since then.

**8. Rough order of magnitude of the effort**

The following figures are my preliminary planning values, not a measured effort estimate. Assumption: a small, experienced team of about two to three people with knowledge of graphics, macOS systems programming and, where applicable, binary translation; initially only the already supported game version. Full game tests and rare compatibility errors can extend the scope considerably. The rows are alternative or successive goals and must not simply be added up.

| Outcome | Preliminary planning horizon | Largest uncertainty |
|---|---|---|
| Architecture review, representative recording and small ARM64 test | About 2–6 weeks | Reproducible data and delimiting the guest dependencies |
| Native renderer correctly replays selected recorded scenes | About 1–3 months | Resource walker, memory accesses, architecture assumptions |
| Integrated separate ARM64 renderer that is usable in the game | Several months; roughly 3–9 months | Cross-process memory and synchronization correctness |
| Rosetta-free game path with integrated translator | More likely 1–2 years or longer until robustly playable | Usable translator core, ISA/ABI coverage, threading and performance |
| Complete AOT/reconstructed game port | Long-term project, up to several years | Control-flow coverage and complete behavioral equivalence |

A first menu screen can appear considerably earlier than a stable port. A successful start does not yet imply reliable run time in fights, DLC areas, rare animations or when loading and saving. For a developer without the corresponding specialization, the short ends of the ranges are not a realistic commitment.

**9. Recommended decision path**

I would answer the ARM64 question first with a **separate renderer replay prototype**. It could initially isolate CPU architecture and GPU backend before the full process communication is built.

1. Record a representative frame or a short sequence, reproducibly, together with the required PM4 data, shaders, resources and state changes. An already fully decoded draw list alone would not measure the decoder share.
2. Replay the same sequence under x86/Rosetta and native ARM64, with the same MoltenVK backend and the same GPU settings. Port the resource walker correctly first; do not mix the gain with a simultaneous change in graphics quality.
3. Compare CPU time, GPU time, memory traffic, image equality and the need for guest feedback. Then measure the additional cost of a real shared-memory/process connection.
4. Integrate the native renderer only if there is a relevant gain on the critical path. If the GPU keeps dominating, prioritize render pass planning and resource traffic.
5. Pursue a full CPU translator or AOT recompiler as a goal of its own only if Rosetta independence justifies the considerable effort even without a guaranteed FPS jump.

**Recommendation for this repository:** First investigate ARM64 as a targeted offloading and porting of the renderer CPU work. For a fully native Bloodborne game path, the project would additionally have to take over the execution of the foreign game program. This second task is substantially larger and should be budgeted only after a successful, measurable renderer prototype.
