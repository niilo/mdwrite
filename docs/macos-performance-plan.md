# Large-document responsiveness plan

## Scope and current status

Implementation and validation, 2026-10-01. Efficient source mapping, bounded background analysis, changed-attribute application, lexical Return checkpoints, and asynchronous document services are implemented. Runtime acceptance evidence is recorded in [the performance results](macos-performance-results.md). Preserve the [Markdown profile](macos-markdown-coverage.md), [editing contract](macos-behavior-contract.md), and [View/Edit modes](macos-view-edit-modes.md). `AGENTS.md` remains unchanged. This work addresses the open M02/M09 performance gates in the [migration plan](macos-port-plan.md).

The user reports a Markdown file with **4,996 lines and 30,558 words**, and described long single lines. The authorized original-file inspection found **334,961 UTF-8 bytes, 322,637 UTF-16 units, 5,084 physical lines and a maximum physical line of 245 UTF-16 units**; it is not the giant-paragraph stress case. Original-file replay now passes 100 native keys, exact edited-source/native-style checks, recovery, and two close cycles using a private copy. Typing p95 is 6.31 ms; original contents and modification time remain unchanged. Its contents/path are not committed. P01 also includes a synthetic fixture with the reported line/word counts and several 10–32 KiB prose paragraphs. Synthetic stress fixtures reproduce the original synchronous Markdown-analysis stalls and a separate whole-paragraph native-layout stall at much larger single-line sizes. Keep original-file, reported-count, and 1/10 MiB unbroken-paragraph evidence separate.

## Evidence and reproducible baseline

Initial isolated probes used optimized current sources at `27efed8`, macOS 26.7.1 / Apple M4 Max / 64 GiB RAM, default fallback monospaced typography. One repeated Markdown unit contains a heading, emphasis, a link, quote, list, and fenced code; sizes round up to a whole unit. Recovery writes and named-file observation were excluded. Startup, timer callbacks, event delivery, and drawing are outside the typing measurement.

| Fixture | Initial window/style | One native insertion | Verdict against 100 ms stall ceiling |
| --- | ---: | ---: | --- |
| 4,154 bytes | 167 ms | 43 ms | Pass |
| 16,482 bytes | 551–577 ms | 346–359 ms | Fail, reproduced twice |
| 65,660 bytes | 5,681 ms | 4,708 ms | Fail |

Separate probes at 16/64 KiB measured semantic parsing plus source mapping on generated native Swift strings at 22/91 ms, inline scanning at 26/100 ms, and styling **without a layout manager** at 379/5,094 ms. Enter's standalone analysis cost on generated strings was 22/88 ms, before the subsequent edit/restyle.

Review exposed a crucial representation difference: on the string returned by `NSTextStorage`, the same semantic parser/source mapper took **314/4,819 ms**. Materializing an identical UTF-8 string reduced those measurements to **20/86 ms**, with identical run counts (1,353/5,390). This explains most of the measured styling delay and changes the first implementation priority. The final reusable 64 KiB stage benchmark confirmed **4,890 ms** for parser plus mapping on text-storage strings versus **82 ms** for Foundation parsing alone and **86 ms** for parsing plus mapping on materialized UTF-8. The adapter's range conversion on the bridged representation is the primary measured bottleneck. Bypassing only the semantic-marker all-runs search in a temporary ablation did not improve styling (376/5,156 ms); do not call that search the established primary cause. All ablations remain outside production.

The reusable optimized Swift 6 benchmark with bundled typography failed twice at 16 KiB: insertion **403–406 ms**, initial window/style **642–675 ms**. Final validation failed three more times at **430/409/411 ms**. The 1 MiB run exceeded its **25-second watchdog before initial window/style completed**, so no insertion duration is claimed for that fixture. These are single-operation measurements and a timeout, not p95 release acceptance.

The reusable benchmark builds optimized Swift 6 sources, registers the bundled fonts, asserts insertion correctness, and exits unsuccessfully on a synchronous typing stall over 100 ms. It never reads user documents or restores/writes recovery records. First compilation is excluded from measurements; subsequent invocations reuse a content-keyed build. Requires Python 3, Swift tools, and a logged-in macOS graphical session.

```sh
./bin/benchmark-macos-typing --kib 16 --repetitions 3
./bin/benchmark-macos-typing --kib 64 --stages
./bin/benchmark-macos-typing --kib 1024 --timeout 25
```

The runtime watchdog kills only the benchmark child. Larger fixtures may time out before reaching insertion; report that failure rather than estimating latency. Stage mode reports timings, without a typing verdict. This initial benchmark can falsely pass after work is merely deferred; P01 must add event-loop and eventual-style assertions before accepting a fix.

Final command evidence (first-build time excluded):

```text
./bin/benchmark-macos-typing --kib 16 --repetitions 3
native-insertText ms=429.8 / 409.0 / 411.4
FAIL: synchronous typing stall <=100 ms (three runs; exit 1)
./bin/benchmark-macos-typing --kib 1024 --timeout 25
FAIL: isolated benchmark exceeded 25 seconds (exit 1)
./bin/benchmark-macos-typing --kib 64 --stages
text-storage parse+map=4890.0 ms; UTF8-snapshot parse+map=85.8 ms
Foundation parse-only=82.2 ms; styler without layout=5807.8 ms (exit 0)
```

## Hypotheses and experiments

Ranked before probes; keep the original benchmark unchanged when comparing candidates.

1. **Repeated span/range intersections dominate styling.** Replace one all-runs search with an indexed lookup in an isolated probe. Predict a large reduction in styling time with identical production style results after implementing the correct index. The semantic-marker ablation did not support this as the primary cause; other interval scans remain secondary profiling candidates.
2. **Whole-buffer attribute replacement drives invalidation/layout.** Compare storage-only styling with attached TextKit layout, then changed attributes with a whole reset. Storage-only results already show that layout is not necessary for the freeze; layout remains a possible additional cost.
3. **Parsing, range conversion, and repeated regex compilation scale poorly.** Time Foundation parsing separately from UTF-8/UTF-16 conversion, block scans, and inline scans. The source-representation probe supports this path as the first priority: materialized UTF-8 eliminated most of the measured parser/mapper delay. Confirm which adapter operations traverse bridged strings repeatedly; avoid assigning all cost to Foundation itself.
4. **Enter/formatting add redundant scans and copies.** Compare ordinary insertion, Return, and soft Return at beginning/middle/end. `smartReturn` currently parses all source; `SourceEdit.applying` constructs a replacement string just to validate native edits.
5. **Main-thread services introduce delayed stalls.** Measure word count, recovery JSON encoding/write, and external-file polling independently, then with typing. Their synchronous implementations are verified in source but were excluded from the initial reproduction.

Record probe commands, configuration, output, and whether each prediction held. An ablation that drops styling is diagnostic evidence, never an acceptable fix.

## Proposed acceptance gates

Retain the migration plan's proposed **p95 ordinary key handling below 16 ms** and **10 MiB interactive open below 2 seconds** on a recorded reference machine. Add p95 main-event-loop delay below 50 ms and no measured steady-editing stall over 100 ms. Define open as decoded text, visible viewport, and usable View/Edit controls; also measure time until correct visible styling, proposed below 1 second at 1 MiB and 2 seconds at 10 MiB after input settles. Full-document styling must converge without starvation after input settles; P01 sets its numeric budget from measured baseline and fixture complexity. These are targets awaiting the P01 reference run, not achieved results. Any revision requires recorded evidence and rationale.

Measure at least 100 edits after warm-up at beginning/middle/end, and report p50/p95/max separately for typing, Return, deletion, paste, undo/redo, and Replace All. Bulk operations have separate duration reports; they must keep the app responsive and complete correctly rather than meet the single-character budget. Capture snapshot, analysis, attribute application, layout/draw, and service timing plus peak/resident memory. No percentiles from one insertion.

Use deterministic 1 MiB/10 MiB fixtures: ordinary prose, dense inline/link markup, many fences, tables/nested quotes/lists, emoji/combining text, a very long unbroken line, an unclosed fence, and distant reference definitions. Include a 16 KiB fast regression. Test multiple dirty windows, continuous input, idle timer bursts, mode changes, theme/font changes, resizing, native Find/Replace, composition, and close/reload while analysis is pending. Record hardware model, RAM, OS, build configuration, fixture seed/hash, and command. Avoid machine names or personal paths in published results.

Automated deterministic correctness/ordering checks belong in normal tests. Hardware-sensitive latency reports run serially on the reference Mac; do not turn noisy shared-CI wall time into a flaky correctness test. P01 establishes a measured memory ceiling before optimization: retained revisions/tasks must remain bounded, and repeated edits/close must not cause continuing growth.

## Design to implement

### Separate source analysis from AppKit presentation

Introduce an `EditorCore` analysis value containing UTF-16 source ranges, semantic style descriptors, merged/indexed code intervals, block context, and marker spans. Fonts, colors, paragraph styles, text storage, layout, and undo remain on the main actor. Analyze immutable source snapshots off the main actor using genuinely concurrent work; `Task {}` created on the main actor alone does not move synchronous work away from it.

First normalize the immutable snapshot to a representation with efficient UTF-8 access **once per analysis**, rather than traversing bridged text-storage strings for every source run. Measure snapshot acquisition and conversion separately: moving parsing off-thread must not leave a large synchronous copy on each keystroke. Prove snapshots remain immutable while native storage changes; pass only value-semantic `Sendable` data to workers, never a live mutable AppKit backing string.

Parse Foundation Markdown once per analyzed revision, reuse one block scan, and cache constant regex patterns safely. Profile residual interval searches before adding sorted queries/sweeps. Build UTF-8-to-UTF-16 mappings once when profiling justifies it; preserve inclusive source columns, end-column-zero handling, non-ASCII boundaries, and existing mapping fixtures. Coalesce equivalent descriptors and intern repeated paragraph/font choices. Preserve current style precedence through differential comparisons against the existing styler.

Start with full-document **background** semantic analysis and targeted presentation. Local-only parsing is not the first fix: reference definitions, fences, list nesting, and Setext/table delimiters have nonlocal effects. Incremental parsing is a later, measured option requiring dependency tracking and a correct full-analysis fallback.

### Bound scheduling and application

A document-owned analysis coordinator maintains a monotonically increasing source revision and a lifecycle epoch. Increment revisions for character edits, undo/redo, Replace All, and loads, never for display-only attributes. Observe native storage changes, including edits that bypass custom commands. Keep at most one in-flight analysis per document and one latest pending request; pending requests carry revision/dirty-range metadata, not a fresh complete copy for every keystroke. Cap global CPU workers and schedule fairly across documents.

Coalesce requests briefly (initial experiment: 40–80 ms), capture an immutable snapshot when a worker can use it, and check cancellation between phases. Foundation's synchronous parser may not cancel mid-call; cancelling a handle does not justify launching unlimited replacement workers. Background work must yield results without blocking the main actor on a semaphore or `.value` wait.

Apply only results matching document identity, lifecycle epoch, and source revision. Presentation has a separate generation for font/theme changes; reuse semantic analysis where possible. Cancel/invalidate pending work on close, reload, and superseding edits. Keep layout-affecting paragraph changes paragraph-aligned. Diff against the **actually applied** attributes, including partially applied batches, not just the last completed plan. Rebase retained ranges through edits or invalidate them; an old offset must never address new source blindly.

Prioritize visible paragraphs and caret context, then remaining differences in bounded main-actor batches (initial experiment: 2–4 ms). Check revision/generation before every batch and reschedule through the event loop. Avoid whole-storage `setAttributes`, full-document `ensureLayout`, and repeated attribute writes with equal values. A batch budget does not preempt an expensive TextKit call; profile each call and split further or invoke the P07 engine decision if necessary.

Native source mutation, selection, dirty tracking, and undo stay synchronous. Give inserted text safe base typing attributes immediately; derived decoration may settle afterward. Styling must not create source edits, undo entries, or dirty changes, and must preserve selection, scroll/caret position, Find highlights, and custom code/quote/rule backgrounds. Defer style application during marked-text composition, then revalidate the revision on commit. Never disable editing or lose keystrokes to wait for styling.

### Bound long-paragraph layout before enabling a new engine

The 1/10 MiB single-paragraph stress workload requires P07's additional source-preserving layout work. The synthetic fixture matching the user's reported counts passes ordinary typing with 10–32 KiB paragraphs; the original-file replay also passes ordinary typing and native style correctness. The raw TextKit 2 chunk experiment is only an efficacy probe; artificial source cuts cannot be accepted merely because typing is faster.

1. **Prove wrapping and logical selection.** Compare native visual-row source ranges and coordinates against the unsplit engine. Align layout elements to real wrap boundaries; keep original paragraph/word/character/sentence segmentation through the supported selection-data-source interface. Cover forward/reverse enumeration, paragraph selection, extension and deletion as well as arrow actions.
2. **Define one engine owner.** Own content/layout/container/navigation objects and expose a visible UTF-16 source range. The coordinator must not access legacy `layoutManager` on a modern editor and trigger compatibility fallback. Keep source storage, revision, undo, Save, and modes under their existing owners.
3. **Invalidate every relevant edit.** Same-length replacements, deletions, paste, undo, load, font/paragraph-style changes and resize must refresh chunk ranges and attributed snapshots. Preserve grapheme boundaries and source-location mappings. Continuations retain head indentation without adding paragraph gaps. Full-source reshaping on each key is not a bounded implementation.
4. **Preserve presentation and lifecycle.** Custom modern layout fragments draw code/table backgrounds, quote rails and rules behind native selection/Find/marked text. Defer derived styling during composition. Verify close/reload callbacks cannot revive obsolete layout work.
5. **Accept the complete route.** Test variable ASCII content and mixed Unicode, all native command classes, cross-boundary Find/replace and composition, font/resize geometry, multiple windows and release. Run 100-key 1/10 MiB long-line workloads including deferred callbacks and memory. Record conservative eligibility/fallback limits explicitly; a repeated ASCII calibration does not establish general shaping correctness.

### Remove the other synchronous scans

Return must use current structural context without invoking Foundation over the entire document. Maintain a revision-correct context index; use an allocation-light lexical scan to the caret when the cache is cold/invalid, with measured bounds and equivalent fenced/indented/quoted-code behavior. Test adversarial edits that invalidate all following fence state. If the cold path misses latency or behavior gates, revise this task before merging; silently changing smart Return to plain Return is not acceptable.

Separate range validation from constructing a complete edited string. Validate replacement/result selections and composed-character boundaries without discarding a full-document replacement copy. Preserve native undo grouping, source normalization, and all toolbox outcomes.

Move word counting and recovery encoding/I/O off the main actor using immutable snapshots, with revision-checked footer updates. Recovery uses one serial owner for write/remove operations and document epoch/revision tokens: Save, undo-to-clean, Discard, reload, and close must not be followed by an obsolete write resurrecting a journal. Lifecycle barriers are ordered owner commands, never blocking main-thread waits. Retain newer unsaved revisions. Keep failure reporting and schema compatibility; document and measure the recovery freshness window during continuous typing. Forced-termination checks must distinguish an obsolete recoverable copy during interrupted cleanup from loss of newer unsaved source; recovery never overwrites the named file.

Move external disk reads off the main actor and reject stale path/baseline observations. A file-change notification or metadata check may reduce reads, but metadata alone cannot detect every same-size/coarse-timestamp write. Preserve periodic reconciliation and authoritative coordinated save-time baseline comparison, including atomic replace/delete/recreate and inaccessible files. Explicit synchronous Save semantics remain unchanged in this performance pass; profile Save separately and open another task if its latency needs a safe redesign.

## Execution tasks and agent handoffs

P02–P06 implementation and native correctness checks are complete; P01/P07/P08 runtime acceptance is being measured. Assign one owner per file; the coordinator owns shared interfaces, scripts, and integration. Each task produces a small commit, acceptance evidence, and a requirements/failure-path review. Fix and rerun every blocking finding before dependents proceed. The user’s execution request authorizes the core, editor, persistence, and benchmark handoffs.

| Task | Dependencies / owner and files | Deliverable and exit check |
| --- | --- | --- |
| P01 Reproduce and instrument | First; coordinator: benchmark, native checks, report | Extend the seed benchmark with real key events, heartbeat/draw latency, stage timings, settled-style correctness, memory, fixture families, and timeout-safe 1/10 MiB runs. Confirm baseline failure twice, establish reference machine/budgets, and measure background services separately. |
| P02 Build efficient analysis | P01; core owner: `MarkdownSyntax.swift`, `MarkdownBlocks.swift`, `MarkdownSpans.swift`, new analysis/index types and core tests | Freeze snapshot/result/revision interfaces. Address the measured bridged-string parser/mapper slowdown first, then profile residual scans. Compare new descriptors with legacy style results on the Markdown profile, Unicode, malformed input, and adversarial fixtures. Record scaling and memory; every discrepancy resolved or explicitly approved as a behavior change. |
| P03 Schedule background analysis | P02; editor owner: new coordinator, `MarkdownTextView.swift`, `MarkdownDocument.swift` integration | Implement bounded workers/coalescing, native-character revision tracking, lifecycle invalidation, and composition guards. Controllable-worker tests prove out-of-order results, close/reload, undo, and multiple windows cannot install stale ranges. No full semantic parse in ordinary typing callbacks. |
| P04 Apply only changed styles | P03; same editor owner: `MarkdownStyler.swift`, coordinator, layout integration | Main-actor descriptor adapter, actual-applied-state diff, visible-first bounded batches, generation checks. Test interruption between batches, deletion of old decorations, distant references/fences, font/theme changes, selection/scroll stability, and unchanged undo/dirty state. Re-run the full Markdown/style/layout/mode suite and event-loop benchmark. P03 is not accepted as the complete fix without P04. |
| P05 Make commands fast | P02; core owner: `EditorBehavior.swift`, `EditorCommand.swift` (`SourceEdit`), context index, core/native command tests; editor adapter changes serialized after P04 | Remove Return's full parse and discarded replacement copy. Exact existing Enter/Shift-Enter/toolbox/Unicode/CRLF behavior and one-step undo pass at beginning/middle/end, including immediately after fence/reference edits before background styling finishes. Cold-cache latency measured. |
| P06 Move services off main | P03 interface; persistence owner: `RecoveryStore.swift`, document service helpers, footer integration via coordinator | Revision-aware counts, serial recovery lifecycle barriers, async external observation. Test delayed writes versus Save/Discard/undo/close, failed I/O, forced termination, external replacement/deletion, baseline/path changes, and multi-window fairness. Profile service-inclusive typing; no weakening of conflict checks. Shared document/window edits integrated serially after P04. |
| P07 Resolve residual layout/load cost | P04–P06 and evidence; editor owner: `MarkdownLayoutManager.swift`, window/loading adapter | Profile remaining stalls, long lines, spell checking, resize, and initial open. Evaluate lazy/noncontiguous TextKit 1 layout if justified. Run a bounded TextKit 2 spike only if native layout still fails gates; select it only with Markdown, geometry, IME, accessibility, Find, and undo evidence. No unconditional engine rewrite. |
| P08 Accept and document | All above; coordinator plus reviewer | Release-config 1/10 MiB report meets agreed gates, bounded memory, current core/source/native suites, manual composition/VoiceOver and light/dark checks, original-user-workload replay when available. Remove ablation/debug code. Update this plan, M02/M09 evidence, and native README with results and remaining limits. No push or release implied. |

Ready order: **P01 → P02 → P03 → P04 → P05/P06 → P07 → P08**. Core-only P05 work and service-helper P06 work may proceed independently after their prerequisites, using the frozen interfaces; the editor owner serializes changes to shared text-view/document/window files. Do not parallelize timing runs or let agents independently introduce competing revision/recovery owners.

Implementation handoff: “Implement PXX from this plan. Read its dependencies, behavior/coverage/mode contracts, repository guidance, and named files. Preserve the original benchmark as a comparison. Submit patch, exact validation output, performance/configuration evidence, and unresolved risks. Do not mark dependent tasks accepted while a correctness or responsiveness gate fails.”

## Plan review and revisions

1. **Initial proposal: defer full restyling.** Review found that a timer still runs the same blocking work on the main actor and queued tasks can accumulate. Revised to efficient analysis, genuine background execution, one in-flight/latest-pending request, and bounded application.
2. **Correctness review: style only the changed line.** Rejected because fences/references affect distant text. Revised to full semantic context, interval indexing, actual-applied-state diff, stale-result checks at every batch, and a separate current-context path for Return. Deferred rendering alone cannot pass P01's expanded gate.
3. **Lifecycle/services review.** Added composition and native-edit revision coverage, invalidation after close/reload, serial recovery cleanup barriers, path/baseline checks, and service-inclusive measurements. Explicit Save remains within its existing safety contract.
4. **Evidence review.** Storage-only styling reproduces the slowdown, so an engine migration is conditional rather than the first task. The semantic-search ablation was negative; comparing generated strings alone had understated the actual parser/mapper cost. Added representation probes and moved immutable UTF-8 snapshot handling to the first optimization. Added reproducible small failure, capped larger runs, explicit unmeasured gates, and P01's missing event/draw/memory coverage. Implementation acceptance requires measurements rather than a declaration that the app feels faster.

The execution request activated this workflow. The reference machine is macOS 26.7.1, Apple M4 Max, 64 GiB RAM. The user authorized a local original-file replay; synthetic workload results must remain distinct from that replay and production release acceptance. Published evidence includes numeric metadata and timings, never the private source or its path.


## Implementation review

- A single canonical body run can cover megabytes. Time budgets around whole runs were insufficient: one attribute enumeration blocked the main actor for 176 ms. Application now bounds source pieces to 4,096 UTF-16 units, preserves grapheme boundaries, and applies paragraph geometry to whole paragraphs only when it changes. Target paragraph geometry is checked for uniformity in the native parity fixture.
- Visible-first work splits coalesced runs at viewport paragraph boundaries. It does not begin at the start of a multi-megabyte run containing the caret.
- The full Foundation parser alone took 3.21 seconds for 10 MiB prose. An initial 32 KiB prefix provides **provisional** heading/code presentation; only the full revision-matching analysis establishes distant references and complete semantics. Late preview results cannot replace a received full plan. Both readiness times are reported separately.
- Native storage edits invalidate Return checkpoints synchronously. Complete background analyses seed checkpoints only for their matching revision. Cold scans retain exact lexical behavior without a semantic parse.
- Presentation changes invalidate resolved attributes independently of source revisions. Loads reset preview/context readiness; close cancels work. Native tests verify immutable snapshots, superseded loads, composition, undo, and unchanged source/dirty state.
- Controlled result delivery supplements real-worker smoke checks: hold preview/full results through composition and font/theme changes, deliver complete semantics before a late preview, reload before delivery, and close with held results. Checks inspect marked ranges and attributes as well as source. Provisional prefix cuts preserve complete composed characters, including combining/ZWJ sequences.
- Source edits cancel obsolete operations. Foundation parsing cannot be interrupted mid-call, but a cancelled snapshot skips style-plan construction afterward; a successor starts only after the old operation exits. Finished operations with held results release their worker slot independently of result delivery. Worker serials prevent old completions from clearing newer work. Controlled regressions reproduce both cancellation orders without the fix, then verify successor progress and latest-only code styling with it.
- Final style runs intern immutable descriptors without changing value equality or source ranges. Measured run stride is 24 bytes versus the prior 144; 3,472,500 runs save approximately 397 MiB of logical vector payload. This is a representation measurement, not a claim about total process memory; native differential checks and all 25 core groups pass, and updated runtime peaks remain separate measurements.
- Normal Quit waits asynchronously for native Save/Discard/Cancel decisions and serial recovery cleanup, including already-closed documents. Cancel keeps the dirty document open. Recovery snapshots are requested every 0.5 seconds during continuous input; actual disk completion depends on worker/I/O latency.
- Native selection initially triggered lazy font repair across a 10 MiB document. Eager attribute fixing removed that stall, but requires a character-revision-cached storage string to avoid repeated bridging during layout. Single-key/longest-range lookups forward to the concrete attributed backing, preserving native font fallback while avoiding full Swift-dictionary bridging for fragmented styles. Unicode fallback, effective-range clipping, edit notifications, immutable snapshots, and secure coding have permanent parity checks.
- Bundled font registration and queued registration notifications finish before application/document creation. Live font changes remain enabled. Benchmark events and RunLoop turns use autorelease pools matching native event lifetimes; unpooled diagnostic memory is not treated as application retention.
- A bounded TextKit 1/2 spike found that neither engine meets the long-paragraph stall gate. TextKit 2 deferred callbacks exceeded two seconds at 1 MiB. Character wrapping also failed. Keep the production engine and wrapping contract while testing supported sizing/typesetter seams; engine replacement requires evidence, not a lower explicit-key duration alone.
- Fixed view height, ASCII-only bidi suppression, and a native 32-line typesetter cap were negative long-line experiments. Native storage invalidation already covered one edited character. Custom TextKit 2 content elements bounded the processing, but raw 4,096-character cuts failed wrap and logical-paragraph checks; that prototype is not a production fix. Continue with wrap-aligned elements and a supported paragraph-navigation adapter before integration.
- Native `NSTextLayoutFragment.layoutQueue` was tested without splitting source paragraphs. A serial queue initially preserved complete geometry and reduced 1 MiB key p95/max to 10.56/11.43 ms, but repeated editing reproduced native null-content-location exceptions at both 1 MiB and 10 MiB. Retaining each fragment's text element did not fix the race. Reject this route for production: fast isolated trials do not establish safe asynchronous mutation, and waiting for giant-paragraph layout before each edit would restore the original stall.
- Wrap-aligned synthetic elements matched the unsplit engine's 18,093 visual-row source ranges and native word/paragraph navigation at 1 MiB, but distant viewport jumps produced incorrect global row origins. Matching row counts alone is insufficient. Require complete coordinate parity and bounded revision-correct geometry before selecting the content-element route; supported TextKit 1 paragraph/typesetter seams remain alternatives.
- A supported fragment-frame override matched exported source/geometry rows after 100 keys at both 1 MiB and 10 MiB, but independent native point-to-source checks returned EOF at middle/chunk-boundary positions. Reject that getter-only proof. Acceptance must include native hit testing after jumps in both directions, visible rendering, viewport/document extent, and selection dragging; public coordinates must agree with the framework's interaction path.

Release-only checks remain separate: human IME/VoiceOver use, extended original-file command/multi-window workloads, older supported macOS versions, Intel, and forced process termination during filesystem operations. Automated marked-text and lifecycle tests do not certify those manual/platform gates.
