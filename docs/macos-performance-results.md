# macOS large-document performance results

## Status and reference machine

Checkpoint recorded 2026-10-01. The authorized original document passed 100 native typing edits, exact source/style checks, isolated services, and two close cycles on the final captured benchmark. The broader stress matrix pauses at P07 whenever a measured main-event-loop stall exceeds 100 ms. Native layout of a 1 MiB unbroken paragraph remains blocked. The dense attribute-repair stall was fixed; semantic convergence budgets and the complete final-source matrix remain unaccepted. The production 10 MiB dense run now fails initial convergence and has a native draw stall; the production 10 MiB longline workload remains paused. Asynchronous-engine crash diagnostics at 10 MiB are separate evidence. These results do not declare the complete performance plan accepted.

Reference machine: Apple M4 Max, 64 GiB RAM (recorded in the original plan); observed macOS 26.7.1, arm64. All native probes compile optimized Swift 6 sources, register bundled fonts, use synthetic fixtures or an explicitly authorized read-only document copy, and run serially in separate processes. A source-content build ID and fixture SHA-256 identify each current probe. The 120-second child watchdog excludes compilation.

The default strict visible-semantics gate remains 1 second at 1 MiB and 2 seconds at 10 MiB. Provisional heading/code readiness is reported separately: it does not imply that distant reference links have resolved. Full-source correctness and eventual heading/code/reference styling remain mandatory. Ordinary typing has a p95 budget below 16 ms; Return, deletion, paste, and undo report separate latency distributions and retain event-loop/stall checks.

## Evidence collected so far

| Workload | Typing p95 / max | Initial / steady heartbeat max | Provisional / complete visible styles | Full final convergence | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 MiB prose, services, two close cycles; earlier candidate | 5.59 / 23.08 ms | 42.37 / 27.02 ms | 242 / 649 ms | 560 ms | Passed; rerun after final lifecycle changes |
| 10 MiB prose, services, two close cycles; `ede81c8ae59f2a87` | 6.85 / 20.45 ms | 48.96 / 108.23 ms | 364 / 4,599 ms | 4,775 ms | Failed event-loop and strict complete-visible gates |
| 10 MiB prose, 12-edit selection diagnostic; `4ea74ea77ff86ec5` | 6.69 / 6.69 ms | 39.16 / 108.10 ms | 266 / 4,547 ms | 7,824 ms | Diagnostic only; not a p95 acceptance workload |
| 10 MiB prose, services, two close cycles, eager storage and event pools; `9935cc0f13a012f4` | 4.32 / 4.94 ms | 51.28 / 15.37 ms | 1,256 / 5,492 ms | 7,851 ms | Responsive; strict complete-visible gate failed |
| 10 MiB prose, services, fonts before app; `5b941005afb64977` | 2.34 / 9.71 ms | 46.49 / 17.80 ms | 1,174 / 5,423 ms | 7,541 ms | Responsive; strict complete-visible gate failed |
| 1 MiB longline, fonts before app; `5b941005afb64977` | 198.79 / 203.26 ms | 455.41 / 251.63 ms | 1,107 / 1,107 ms | 340 ms | Native typing/loop and strict visible gates failed |
| 1 MiB dense markup; `5b941005afb64977`, sampled diagnostic | Not reached | 201.22 / not reached | 479 / 9,380 ms | Initial styling exceeded 60 s | Initial convergence failed; no typing acceptance evidence |
| 1 MiB dense markup, direct storage lookup; `35a4d46261dd2c8d` | 7.97 / 10.85 ms | 45.16 / 49.35 ms | 525 / 9,334 ms | 14,763 ms | Responsive; strict complete-visible gate failed |
| 1 MiB prose, services, two close cycles, pre-overlay checkpoint `560648c7516750f7` | 3.74 / 10.38 ms | 50.50 / 15.56 ms | 471 / 857 ms | 854 ms | Passed all measured gates |
| 1 MiB fences, cached checkpoint `560648c7516750f7` | 5.55 / 14.07 ms | 44.85 / 36.24 ms | 474 / 2,958 ms | 6,170 ms | Responsive; strict complete-visible gate failed |
| 1 MiB Unicode, cached checkpoint `560648c7516750f7` | 11.16 / 32.55 ms | 61.19 / 67.67 ms | 1,038 / 3,724 ms | 9,224 ms | Responsive; strict complete-visible gate failed |
| 1 MiB dense markup, production interval overlay `fde05105ad615d8d` | 6.82 / 12.04 ms | 49.86 / 50.61 ms | 509 / 4,909 ms | 10,154 ms | Responsive; strict complete-visible gate failed |
| 10 MiB dense markup, captured interval overlay `fde05105ad615d8d` | Not reached | 143.21 / not reached ms | 1,686 / 44,714 ms | Initial styling exceeded 60 s | Initial native draw stall and convergence/semantic gates failed |

All service-enabled runs verified that the newest journal contained exactly the edited benchmark source. The authorized original was read without modification; all edits, named-file observation, and recovery writes used private temporary copies/stores. The application clipboard was neither read nor modified. No original contents or personal path appear in this report or benchmark output.

Selection substep instrumentation established that `NSTextView.setSelectedRange` costs **92.08 ms** at the 10 MiB size. Source acquisition, the local grapheme helper, line lookup, substring extraction, trimming, backward fence search, and UTF-16 length retrieval each stayed at or below **0.02 ms**. This is native selection work, not an established Foundation line-scan bottleneck. The main style coordinator's individual measured maxima stayed below 3 ms. A four-second, one-millisecond-interval sample of the isolated synthetic process attributed 1,182 of 3,044 main-thread samples to `setSelectedRanges → _fixedSelectionRangeForRange → attribute:atIndex → ensureAttributesAreFixedInRange → fixFontAttributeInRange`. This supports native lazy font-attribute repair as the next P07 experiment; layout and spell-checking had very few samples in the selection branch. Sampling overhead means that run's wall-time percentiles are diagnostic rather than acceptance evidence. The raw stack is `build/performance-results/prose-selection-stack.txt`.

The latest small-fixture checkpoint used 100 measured keys after three warm-ups. Prose included real isolated recovery/footer/external-file services and two additional close cycles. Total open times were **355 / 347 / 856 ms** for prose/fences/Unicode. Prose's extra closed documents and editors both passed weak-reference release checks; resident memory was **239.3 / 239.8 MiB**, peak **308.5 MiB**. Unicode native navigation maximum was **58.97 ms**, with ordinary typing p95 still below 16 ms. Initial heartbeat values are reported separately from steady editing, and all remained below the 100 ms ceiling. Fence/Unicode failures are complete-semantic readiness failures, not typing responsiveness failures.

The three checkpoint probes reuse one cached pre-overlay binary. Its source-content ID was computed at compilation start; they are not presented as final-production commit acceptance. Subsequent benchmark builds copy exactly the captured, hashed source bytes before invoking the compiler, preventing concurrent working-tree edits from changing what that ID represents. Font registration/draining before `NSApplication` is now the benchmark default, matching production; `--fonts-after-app` remains a diagnostic control.

## Fix attribution and remaining P07 blocker

Eager attribute fixing with a revision-cached source string eliminated the selection repair stall: the corrected 10 MiB run measured selection p95 **0.16 ms** and actual `scrollRangeToVisible` p95 **0.35 ms**, maximum **10.20 ms**. Its total document-open time, including named-file decoding/storage initialization and initial window/layout/focus, was **1,090.4 ms**. Fixture generation and isolated fixture-file creation are setup work outside that open timer.

An initial-only sample separately attributed the earlier roughly 600 ms startup pause to queued bundled-font registration notifications: `fontSetChanged` repaired fonts throughout the newly opened storage. Warming fonts and draining those notifications before creating the document removed that pause. The before-app ordering probe confirmed that `NSApp` remained absent during font setup/draining, which took **266.6 ms** separately from document opening. Live font changes are still handled normally. This initial sample is diagnostic evidence, not an acceptance latency measurement.

Each benchmark event and RunLoop turn now has an autorelease pool, matching native application event lifetimes. Without them, temporary bridged source revisions survived in the command-line process's outer pool and inflated resident memory. In the corrected 100-edit service/close-cycle run, final resident memory was **724.0 MiB**, process peak **795.5 MiB**, and post-extra-close observations **681.1 / 681.2 MiB**. Both extra documents and editors passed weak-reference release checks after close and RunLoop draining. The original benchmark document/fixture remains intentionally held; allocator caching and two extra cycles do not establish a numeric memory ceiling. The separate fonts-before-app run ended at **699.0 MiB**, peak **700.4 MiB**.

The 1 MiB unbroken-line run still stalls. Sampling its native typing path found **1,651 main-thread samples** under `NSTextView.didChangeText → _ensureLayoutCompleteToEndOfCharacterRange → NSATSTypesetter.layoutParagraphAtPoint`, including line wrapping and CoreText typesetting. About **1,626** samples involved typesetter/layout frames. Markdown coordinator application stayed small (`storage-endEditing` maximum **2.01 ms**, glyph lookup **0.10 ms**); background analysis was **132.28 ms**. The whole-paragraph native layout in `super.didChangeText` is the remaining blocking cost. The diagnostic sampled run is not used for the latency table; the unsampled run above supplies those percentiles. The isolated engine spike used 100 measured keys plus three warm-ups on the same 1 MiB longline, a 90-second bound, the bundled 20-point font, wrapping and symmetric padding. TextKit 1 word wrapping measured key p95/max **231.11 / 234.54 ms**, heartbeat maximum **317.19 ms**; character wrapping measured **156.48 / 162.18 ms**, heartbeat **195.98 ms**. TextKit 2 word wrapping reduced key p95/max to **102.57 / 114.34 ms** but deferred heartbeat maximum rose to **2,074.48 ms**. TextKit 2 character wrapping measured **81.44 / 82.72 ms** with heartbeat **2,026.59 ms**. Exact source and active-engine assertions passed. These plain-native engine probes omit Markdown coordination and are diagnostic, not production acceptance. A simple engine switch or wrapping change therefore fails responsiveness; further bounded-paragraph work is required before accepting longline workloads.

Dense markup exposed a separate initial-style blocker. The 1 MiB run failed its **60-second** style-settling deadline before reaching any typing operation. The inclusive open measurement was **279.9 ms**, but initial provisional formatting arrived at **479.1 ms**, complete visible semantics at **9,379.9 ms**, and full document styling remained pending at **60,232.2 ms**. A three-second sample during that slow convergence found **2,125 of 2,496 main-thread samples** in `MarkdownAnalysisCoordinator.applyBatch → NSTextStorage.endEditing → fixGlyphInfoAttributeInRange → longestEffectiveRange`, including `MarkdownTextStorage.attributes` and Objective-C-to-Swift dictionary bridging. Recorded initial heartbeat p95/max was **179.24 / 201.22 ms**. Because this run was sampled, those latency values are diagnostic rather than an unsampled acceptance measurement. The settle failure is recorded, not converted into an estimated typing duration. Direct backing-storage overrides for single-attribute and longest-effective-range lookup fixed that repair stall without disabling native attribute fixing. The subsequent unsampled 1 MiB dense run settled its initial styles in **17,391.3 ms**, with heartbeat maximum **45.16 ms**. Its 100 edits measured key p95/max **7.97 / 10.85 ms**, steady heartbeat maximum **49.35 ms**, and `endEditing` maximum **6.83 ms**. Exact insertion and eventual sentinel styles passed; the strict 1-second complete-visible gate still failed at **9,334.2 ms**. Background analysis maximum was **2,320.94 ms** and style-plan construction **6,588.76 ms**; these phases now dominate semantic convergence. Final resident/peak memory was **574.4 / 619.9 MiB**. A separate synthetic background-phase diagnostic measured semantic style writes **340 ms**, marker dimming **2,078 ms**, headings/tables **203 ms**, decoration scanning **3,075 ms**, and final enumeration **911 ms** (total plan **6,655 ms**, **347,250** output style runs). Repeated paragraph writes were not the dominant phase. These phase diagnostics omit the production editor and do not establish responsiveness acceptance. The validated production interval overlay subsequently reduced measured dense 1 MiB style-plan construction to **2,028.99 ms** (analysis **2,498.72 ms**). Initial full styling settled in **13,827.2 ms**, final in **10,154.3 ms**, while the 100-key and heartbeat gates passed. Inclusive open was **305.4 ms**; complete visible semantics at **4,909.0 ms** still missed the unchanged 1-second target. Native `endEditing` maximum was **7.47 ms**. Final resident/peak memory was **643.7 / 689.9 MiB**, higher than the earlier candidate; no service or extra-close cycles were included in this direct comparison. The captured-source build verifies exactly the bytes hashed by `fde05105ad615d8d`. The guarded **10 MiB** dense run then failed its initial full-style deadline at **60,029 ms**, before any measured key operation. Inclusive open **1,489.2 ms** and provisional styling **1,685.7 ms** met their proposed opening targets, but complete visible semantics needed **44,714.3 ms** against the unchanged 2-second target. Initial heartbeat p95/max was **2.66 / 143.21 ms**, and the native viewport display call reached **145.61 ms**. This is a new measured native draw/layout stall requiring diagnosis; no exact stack attribution is claimed. After close, resident memory was **630.1 MiB**, with process peak **4,797.4 MiB**. Initial background/application phase maxima were unavailable because this binary returned before printing them; the benchmark has since been instrumented to print initial phases and live memory before its failure return. No typing percentiles or final convergence time are inferred from this failed opening.

The subsequent **60-second-capped startup diagnostic**, snapshot `14ca9c2968c6b33e`, sampled its own synthetic process at 5 ms intervals. It measured full analysis **25,746.92 ms** and plan construction **18,331.47 ms**, with full application starting around 44 seconds. At 55 seconds, only about **1.16 MiB / 383,963 runs** had been applied; the cursor was still pending. Individual maxima remained bounded: source snapshot **0.001 ms**, visible lookup **0.011 ms**, attribute application **1.05 ms**, and `endEditing` **4.99 ms**. Peak/live resident memory was **4,816.8 / 3,206.6 MiB**. The original 145.61 ms display spike did not recur, so it remains unattributed; this sampled run does not clear that failure or supply acceptance percentiles. Of 9,564 main-thread samples, 7,196 were idle, 1,130 in application timers, and 609 in direct native display. The data establishes expensive background convergence plus a large volume of bounded main-actor application, rather than a reproduced single long coordinator call. The diagnostic child was stopped at its 60-second cap before typing. Raw evidence: `dense-10240-initial-profile.log` and `dense-startup-stack.txt`.

Raw profiles: `build/performance-results/prose-selection-stack.txt`, `prose-initial-stack.txt`, `longline-typing-stack.txt`, and `dense-initial-stack.txt`. Corrected run logs: `prose-10240-eager-pooled-navigated.log`, `prose-10240-fonts-before-app.log`, `longline-1024.log`, `dense-1024.log`, and `dense-1024-direct-lookup.log`.

## Rejected long-paragraph alternatives

Fixed initial view height, disabling bidi on the ASCII fixture, and a native typesetter line-fragment cap did not fix the stall. Paired TextKit 1 baseline/fixed-height/ASCII runs had key p95 **150.98 / 147.05 / 148.36 ms** and heartbeat maxima **204.84 / 186.44 / 204.51 ms**, with all **18,093** wrapped rows identical. The 32-line cap kept source/wrapping correct but key maximum remained **147.97 ms**; one typesetter call still processed up to **1,048,433** characters in **288.15 ms**. A requested fragment cap cannot preempt that paragraph's native processing.

Raw TextKit 2 content-element chunking was fast in a six-key diagnostic (paired key/heartbeat maxima **9.50 / 18.99 ms** versus **107.34 / 2,105.21 ms**), but changed wrapping from **18,093** to **18,190** rows and changed logical paragraph navigation. Wrap-aligned elements plus original logical enumeration preserved row source ranges/navigation and reached **7.02 / 25.80 ms** key/heartbeat maxima, but global row positions became incorrect after middle/end jumps: row **9,038** had Y **125,804.93**, expected **271,140**. Exact source alone is insufficient. The later explicit prefix-height fragment-frame diagnostic preserved all source row ranges and global geometry getters in 100-key **1 and 10 MiB** uniform-fixture runs (approximately 18,000/180,000 rows). This closes that getter comparison for the uniform synthetic fixture. The independent native point-to-source hit-test then **failed** at middle/end chunk boundaries, returning end-of-file: overriding the public fragment frame did not repair native private geometry indexing. Actual drawing, hit testing, arbitrary-font wrapping, editing, IME, and accessibility parity are therefore still unproven or failed. Earlier raw/aligned implementations remain failed controls, and no chunked prototype is accepted for production until those contracts hold.

The unsplit TextKit 2 native asynchronous-layout queue also produced one attractive 1 MiB trial: 100-key p95/max **10.56 / 11.43 ms**, heartbeat maximum **8.96 ms**, correct geometry/navigation. It is rejected: the serial queue crashed at **10 MiB**, and retaining content elements still crashed at **both 1 and 10 MiB**; two-worker layout also crashed. Native background typesetting received a null content location while editing invalidated elements. One successful timing cannot justify a crashing path. These are isolated feasibility experiments; no asynchronous layout queue or chunking has been enabled in production.

See [the native spike record](../macos/Spikes/Performance/README.md) for commands, controls, and source/geometry assertions. A separate interval-overlay style builder achieved approximately **1.91 seconds** for the dense 1 MiB descriptor plan versus roughly **6.6 seconds**, preserving all **347,250** descriptor runs; production integration passed native parity checks and its 1 MiB runtime result is recorded above. The full final-source matrix remains pending.

## Reported-count workload

The user reported **4,996 lines and 30,558 words**. The deterministic `reported` fixture matches those exact LF-terminated logical-line and `EditorBehavior.wordCount` totals; it is not a reconstruction of the original. A terminal LF does not add an empty logical line. Heading/code/distant-reference sentinels surround mixed markup, quotes, lists, tables, fences, and 10/20/32 Ki UTF-16 prose paragraphs. Remaining words are distributed across filler lines. Runtime assertions verify counts independently of `--kib`: **205,551 bytes/UTF-16 units**, longest line **32,768 units/bytes**, fixture SHA-256 `1711c5f3c12abeaf…`.

Each row measures 100 operations after three warm-ups, alternating beginning/middle/end and scrolling the actual viewport. Commands preserve semantic sentinels and check exact source/selection against `SourceEdit`; undo uses the real native undo manager and checks complete source restoration. All rows eventually passed sentinel styling, source correctness, and the unchanged 1-second semantic gate.

| Operation / captured source | Native p95 / max | Initial / steady heartbeat max | Initial complete semantics | Verdict |
| --- | ---: | ---: | ---: | --- |
| Typing, services/close2; `86904415c2975ef9` | 7.81 / 9.99 ms | 47.60 / 52.36 ms | 583.9 ms | Passed all gates |
| Return; `0285d2482c3d9948` | 4.60 / 11.82 ms | 71.36 / 47.81 ms | 731.0 ms | Passed all gates |
| Delete; `0285d2482c3d9948` | 8.87 / 10.61 ms | 47.24 / 56.83 ms | 534.4 ms | Passed all gates |
| Paste, first run; `0285d2482c3d9948` | 1.21 / 1.32 ms | 43.61 / 149.03 ms | 571.3 ms | Failed responsiveness |
| Paste, unsampled repeat; `0285d2482c3d9948` | 1.11 / 1.46 ms | 44.51 / 46.70 ms | 534.0 ms | Passed; prior spike remains open |
| Undo; `2759e33cb8a567cb` | 14.40 / 16.50 ms | 43.68 / 55.36 ms | 513.0 ms | Passed command gates |

The first paste run had queued-event maximum **107.90 ms** despite handler maximum **1.32 ms**. Its 149.03 ms heartbeat spike remains **unattributed**; a successful repeat does not erase that failure. No sampled attribution is claimed. Undo's 16.50 ms maximum is a command measurement; the 16 ms p95 gate applies to ordinary typing. Reported typing's isolated journal matched exactly; both extra closed documents/editors released their weak references. Post-close resident memory was **206.4 / 207.3 MiB**, peak **276.1 MiB**. Oracle construction/source verification costs are separately logged, outside native-handler timings.

Logs: `reported-typing.log`, `reported-return.log`, `reported-delete.log`, `reported-paste.log`, `reported-paste-repeat.log`, and `reported-undo.log` under ignored `build/performance-results/`.

```sh
./bin/benchmark-macos-typing --fixture reported --interactive --services \
  --close-cycles 2 --timeout 120 --settle-timeout 60
./bin/benchmark-macos-typing --fixture reported --interactive --operation undo
```

## Authorized original-document replay

The original was read through native UTF-8 decoding without augmentation: **334,961 bytes**, **322,637 UTF-16 units**, longest LF-delimited line **245 UTF-16 units / 246 bytes**. This is not the giant unbroken-paragraph workload. The benchmark counts **4,994 LF-terminated logical lines** and **31,515 `EditorBehavior.wordCount` words**; a separate physical `splitlines` count was **5,084**. These conventions differ from the user's reported 4,996/30,558 counts. Original and decoded-byte SHA-256 matched (`186e772e16baf1a3…`), and the original's hash remained unchanged after replay.

Final captured source **`2759e33cb8a567cb`**, log `authorized-copy-typing-final.log`, passed all unchanged gates with **100 native keys** at beginning/middle/end, real viewport navigation, isolated recovery/footer/external observation, and two additional close cycles:

| Measure | Result |
| --- | ---: |
| Native typing p50 / p95 / max | 2.94 / 6.31 / 10.16 ms |
| Initial heartbeat p95 / max | 2.27 / 39.45 ms |
| Steady heartbeat p95 / max | 7.52 / 21.91 ms |
| Inclusive open-ready | 219.2 ms |
| Initial / final complete semantics | 526.5 / 324.0 ms |
| Selection / viewport navigation maximum | 7.33 / 7.78 ms |
| Native storage `endEditing` maximum | 4.77 ms |
| Final / peak resident memory | 152.8 / 165.0 MiB |

Every insertion matched the exact expected source. Initial and final managed attributes matched a fresh full style plan applied through the same native eager-storage/font-fixing adapter; each oracle took approximately **246 ms outside the performance interval**. Initial/final styling settled in **323.1 / 378.1 ms**. Maximum background analysis/plan times were **166.25 / 56.45 ms**. The recovery journal contained the exact latest source, and both extra documents/editors released after close; resident observations were **157.9 / 158.9 MiB**. Allocator caching and two cycles do not establish a memory ceiling. Font setup/draining took **248.7 ms**, separately from opening.

Two earlier file probes exposed benchmark validation defects: direct descriptor-font comparison did not account for native fallback, and the subsequent correct native oracle passed while a final-ready timestamp missed completion in the last RunLoop turn. Both defects were corrected before the final unsampled replay; neither earlier run is represented as acceptance evidence. File style verification uses full managed-attribute parity rather than synthetic sentinel assumptions. Offscreen native draw timings do not measure compositor presentation.

Original-file Return/Delete/Paste/Undo were **not run**: exact command-source oracles were implemented for the protected synthetic fixture only. Manual IME, accessibility, and visible-app interaction remain separate checks. This replay establishes responsive native typing for the authorized workload; it does not accept unresolved giant stress cases or the complete P08 matrix.

```sh
./bin/benchmark-macos-typing --file '<authorized-markdown-file>' --interactive \
  --services --close-cycles 2 --timeout 120 --settle-timeout 60
```

## Reproducible commands and pending matrix

```sh
./bin/benchmark-macos-typing --kib 10240 --interactive --fixture prose \
  --services --close-cycles 2 --fonts-before-app --timeout 120 --settle-timeout 60
./bin/benchmark-macos-typing --kib 1024 --interactive --fixture longline \
  --fonts-before-app --timeout 120 --settle-timeout 60
```

Checkpoint logs are `prose-1024-checkpoint.log`, `fences-1024-checkpoint.log`, `unicode-1024-checkpoint.log`, `dense-1024-overlay.log`, and `dense-10240-overlay.log`. Raw numeric-only benchmark logs remain under ignored `build/performance-results/`. Do not compare percentage improvements across different fixture families or claim percentiles from the 12-edit diagnostic.

After the P07 blocking native-layout finding is resolved, run 100 measured edits per workload, serially:

1. Prose at 1/10 MiB, with recovery/footer/external observation and two close cycles.
2. Long unbroken lines at 1/10 MiB, early enough to expose remaining native layout costs.
3. Dense markup/tables/nested quotes, many fences, and Unicode/combining text at 1/10 MiB.
4. Return, deletion, paste, and undo on 10 MiB prose, each with a separate report.

Record every timeout and strict-gate failure. Stop a new critical native stall for diagnosis instead of masking it with a larger latency budget. Explicit changes to proposed semantic-convergence budgets belong in the performance plan with evidence and rationale. Native correctness suites, manual composition/accessibility checks, remain separate acceptance evidence; the original native typing replay above is measured, while its non-typing commands remain unrun.
