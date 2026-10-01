# Native TextKit performance experiment

This P07 experiment isolates AppKit editing and wrapped layout from Markdown
analysis, custom backgrounds, recovery, and footer work. It does not change the
production editor. `MarkdownTextStorage` supplies the same cached, eager native
attribute-fixing storage to both engines. The TextKit 2 path never accesses
`NSTextView.layoutManager`, and verifies that its modern engine remains active.

Build and run each engine in a separate process with a logged-in macOS session:

```sh
python3 macos/Spikes/Performance/build-textkit-probe
build/textkit-probe/textkit-engine-probe --engine 1 --fixture longline --kib 1024 --edits 100 --fonts fonts
build/textkit-probe/textkit-engine-probe --engine 2 --fixture longline --kib 1024 --edits 100 --fonts fonts
```

Repeat with `--char-wrap` to test character wrapping. Use `--fixture prose` for
ordinary paragraphs. Bound each diagnostic process externally; the recorded
matrix used a 90-second timeout per process. Font-registration notifications are
drained before constructing the storage. Every event and run-loop iteration has
an autorelease pool. Source bytes are synthetic; no document files are written.

## Recorded 1 MiB long-paragraph results

Measured on October 1, 2026, with an optimized Swift 6 build, iA Writer Mono 20,
line spacing 5, horizontal padding 66, and 100 measured native typing events
after three warmups. Selection rotates through beginning, middle, and end.
The fixture contains the same short sentinels as the production baseline and
an `unbroken` body repeated to approximately 1 MiB.

| Engine | Wrapping | Key p95 / max (ms) | Heartbeat max (ms) |
| --- | --- | --- | --- |
| TextKit 1, noncontiguous | Word | 231.11 / 234.54 | 317.19 |
| TextKit 1, noncontiguous | Character | 156.48 / 162.18 | 195.98 |
| TextKit 2 | Word | 102.57 / 114.34 | 2074.48 |
| TextKit 2 | Character | 81.44 / 82.72 | 2026.59 |

All cases preserved exact source contents and their requested text engine.
Neither standard engine nor wrapping choice meets the performance plan's
16 ms key p95 and 100 ms maximum main-thread stall. TextKit 2's short explicit
display calls do not capture its substantial deferred work. A production
migration cannot be justified by these results. Paragraph-level layout needs a
separate bounded design and correctness proof.

These results cover plain native typing only. They provide no evidence about
Markdown styling, IME, custom decoration, accessibility, or document services.

## Follow-up controls

The probe also accepts `--fixed-height` (finish initial native sizing, then turn
only automatic vertical view resizing off), `--ascii-no-bidi` (TextKit 1,
ASCII-only source), `--line-cap 32` (custom native typesetter request cap), and
`--trace-edits` (record the first native changed/invalidated ranges without
changing them). `--no-background` disables TextKit 1 idle background layout for
diagnosis only. Every run checks exact source and caret visibility at the
beginning, middle, and end. Full layout digests are computed after timing.

Follow-up serial 1 MiB word-wrap runs, 100 measured keys:

| TextKit 1 variant | Key p95 / max (ms) | Heartbeat max (ms) |
| --- | --- | --- |
| Current baseline | 150.98 / 156.12 | 204.84 |
| Fixed initial full view height | 147.05 / 150.63 | 186.44 |
| ASCII, bidi disabled | 148.36 / 168.65 | 204.51 |

All three produced 18,093 identical visual lines and layout digest
`5df4e7f8f07188f5`; source and scrolling checks passed. Neither variant fixes the
long-line stall. These are a later paired comparison, not reruns of the earlier
engine matrix; compare each candidate to its paired baseline.

A six-key native edit trace showed each changed and invalidated range was
already exactly one UTF-16 character (`mask=3`, `delta=1`). The 32-line typesetter
cap retained the actual native return range, source, and identical wrapping,
but key maximum remained 147.97 ms versus 148.53 ms for its paired baseline.
One typesetter call still lasted 288.15 ms and returned up to 1,048,433 processed
characters. A line-fragment cap does not preempt this giant paragraph's native
processing. Narrowing native invalidation is unsupported by this evidence.

`--element-chunk 4096` is a provisional TextKit 2 feasibility diagnostic.
It overrides content-element enumeration and explicitly maps custom paragraph
content/separator ranges to unchanged underlying UTF-16 text. No newline is
inserted. A six-key efficacy run achieved an 11.04 ms key maximum and 24.25 ms
heartbeat maximum with source/caret checks passing. **Raw chunk boundaries are
not accepted behavior:** full wrapped-row geometry, logical paragraph actions,
IME, cross-boundary edits, undo, Find, and accessibility must be proven before
any production use. Custom paragraph elements require explicit range mapping;
using the default paragraph range cache caused a native exception in the first
throwaway attempt. The probe is not used by the production app.

Full TextKit 2 differential checks then proved why that efficacy result is not
an accepted fix. With six measured edits, the standard engine produced 18,093
visual rows (source-range digest `ecd0de794a4b20ea`), while raw 4,096-character
elements produced 18,190 (`27aa48379b56e89e`). Paragraph navigation also changed:
the original paragraph spanned UTF-16 66–1,048,501, but the chunked view moved to
524,296/524,354. The standard engine passed these navigation expectations.
The paired chunked key/heartbeat maxima were 9.50/18.99 ms versus
107.34/2,105.21 ms for standard TextKit 2. Exact source and caret visibility
passed both. Chunking bounds native work, but requires wrap-aligned element
boundaries and original logical-paragraph behavior before it can be considered.

`--aligned-chunks --logical-enumeration` adds two further diagnostics: bounded
native first-row calibration for the uniform unbroken ASCII fixture, and native
selection-data-source overrides that retain original source paragraph/word
boundaries. After the scroller settles, the actual container width is 711, with
701 usable points; sampling the earlier 860-point view incorrectly used 718.
Aligned 4,060-character elements match all 18,093 original row ranges and both
navigation checks. Six-key maximum fell to 7.02 ms versus 103.31 ms, and heartbeat
maximum to 25.80 ms versus 2,137.87 ms. However, global fragment positions form
incorrect estimated islands after middle/end caret jumps: the first mismatch is
row 9,038, with Y 125,804.93 instead of 271,140. Native viewport relocation,
full invalidation, element-lifetime invalidation, and size-estimating enumeration
did not repair that mismatch. This remains a blocked diagnostic, not a fix.
`--dump-rows PATH` exports complete source/geometry rows for differential checks.

`--native-layout-queue 1` tests the documented asynchronous layout property on
**unsplit** standard TextKit 2 fragments. One 100-key 1 MiB run passed native
geometry/navigation with key p95/max 10.56/11.43 ms and heartbeat maximum 8.96 ms.
It is **rejected for production**: the same serial queue crashed at 10 MiB,
and a strong-element-retention ablation (`--retain-layout-element`) crashed at
both sizes. The native background typesetter received a null content location
while editing invalidated its element. A two-worker queue also crashed. One
successful timing cannot establish safe asynchronous native editing.

`--exact-frame` is a supported fragment-frame override diagnostic. It indexes
uniform rows, captures native row height from two lines of one bounded fragment,
accounts for native first-fragment spacing, and excludes real paragraph
separators from wrapped-row counts. With 100 measured edits, all 18,093 rows at
1 MiB and 180,804 rows at 10 MiB matched an unsplit native final-source oracle
exactly, including global coordinates. Key p95/max was 8.65/14.40 ms and
11.38/20.73 ms respectively; heartbeat maxima were 29.97/35.79 ms. The oracle
(`--geometry-oracle`) builds the same final synthetic source before graph
creation; it is an output comparison, not an editing timing baseline.

**That frame proof is insufficient.** `--hit-test` independently round-trips
native caret rectangles through point-to-source insertion lookup, tests both
sides of chunk boundaries, and jumps beginning/middle/end in both directions.
It exposed native private placement-cache disagreement: distant chunk hits
returned EOF despite exact public frame coordinates. The custom frame route
therefore remains unaccepted. `--mapped-hit-test` investigates the supported
selection-data-source line-range seam; it is not enabled in production.

`--paragraph-cap 4060` tests the TextKit 1 paragraph setter and paragraph layout
hooks. Capturing the entry cursor in both native character and glyph layout is
necessary; an earlier stale-cursor attempt exceeded its 35-second watchdog.
With the corrected cursor, native paragraph calls were bounded (1.62 ms maximum),
but six-key maximum was 285.86 ms and heartbeat maximum 520.37 ms. Upstream
native work remained expensive. Exact source/navigation and row ranges passed;
this does not justify a production typesetter change.

### Frozen result: native interaction still fails

The mapped selection-data-source seam is called by actual `NSTextView.mouseDown`
and repaired distant chunk-boundary clicks in the synthetic fixture. A separate
view point-to-source adapter also repaired insertion-index round trips. Neither
establishes correct native interaction: the chunked view's final sentinel click
selected UTF-16 1,048,566 instead of 1,048,591.

An unsplit native control using the same source, window geometry, caret-derived
points, and synthetic mouse events selected all five beginning/middle/end/reverse
positions exactly, including 1,048,591 at the final sentinel. Both graphs exposed
the same 18,093 row coordinates through the public frame API, but native reported
usage height was 542,815 points for the control and 542,725 for the chunked graph:
a real 90-point extent disagreement. Document height was 542,905 in both. The
control rules out the synthetic mouse procedure as the explanation for that
EOF failure; matching public row coordinates does not prove native placement,
hit testing, or rendering correctness.

**This spike is frozen with no production recommendation.** Chunked layout,
frame mapping, selection adapters, and asynchronous native fragment layout must
remain outside the app. The latest line-selection override is compiled but
untested. General prose/Unicode wrapping, short-paragraph heights, Markdown font
changes, resizing, same-length replacement, arbitrary edits, IME, Find, undo,
accessibility, and drawn-pixel parity remain unproven. The timing and geometry
results above apply to synthetic uniform unbroken ASCII stress fixtures; they
do not establish the shape of the user's reported 4,996-line, 30,558-word file.
Production is already responsive on a synthetic fixture matching those reported
counts; the original document has not been tested.

If giant-line work resumes, first build a minimal native geometry differential
that checks usage extent, drawn rows, actual mouse selection, and insertion
indices at EOF and distant chunk boundaries against an unsplit control. Repair
the extent/placement disagreement through a supported geometry owner before
further timing or production integration; a frame-getter correction alone is
insufficient. Then require native interaction and source-preservation parity
across edits, formatting, and resize.

All fixture text is generated. Runtime logs, row CSVs, and optional viewport PNGs
are written under `/private/tmp`; the probe binary is under ignored `build/`.
No real document contents or generated artifacts are committed. The standard
EOF control log is `/private/tmp/mdwrite-standard-mouse-control.txt`; optional
synthetic screenshots use `/private/tmp/mdwrite-standard-mouse-*.png`.
