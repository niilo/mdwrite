# Repository Guidelines

## Project Structure & Module Organization

Omawrite is a Qt 6 Markdown editor using C++17 and Qt Quick. `src/` contains the C++ backend, Markdown highlighter, system-theme integration, QML components, and `EditorMutations.js`. `src/Main.qml` defines the main window. `src/resources.qrc` bundles QML, JavaScript, and fonts from `fonts/`. Register new compiled sources in `omawrite.pro` and bundled assets in the resource file.

`tests/tst_omawrite.cpp` holds automated tests; `tests/tests.pro` configures their build. `bin/` contains development scripts, and `pkgbuild/` contains Arch packaging, desktop integration, and the application icon.

## Build, Test, and Development Commands

Install Qt 6 development modules listed in `README.md`, plus `make` and a C++ compiler. Ensure `qmake6` or a Qt 6 `qmake` is on your path. File dialogs require `xdg-desktop-portal` and a portal backend.

- `./bin/build`: build the application in `build/` using qmake and make.
- `./build/omawrite`: launch the locally built editor.
- `./bin/test`: build tests in `build-tests/` and run them with the offscreen Qt platform.
- `./bin/install`: build and install the Arch package using `makepkg -fsi`; requires an Arch packaging environment.

## Coding Style & Naming Conventions

Follow existing four-space indentation in C++, QML, and JavaScript, with opening braces on the declaration line. Use PascalCase for C++ classes and QML component filenames, camelCase for functions and properties, and `m_` prefixes for private C++ members. C++ implementation filenames are lowercase. Prefer existing Qt idioms such as signals, properties, and `QStringLiteral`. No formatter or linter configuration is committed; match neighboring code.

## Testing Guidelines

Use Qt Test, with descriptive camelCase test methods under `private slots` in `OmawriteTest`. Add regression cases for changed editor behavior, file handling, or highlighting. Use temporary directories for filesystem fixtures and `QSignalSpy` for signal assertions. Run `./bin/test` before submitting. No numeric coverage threshold is configured. For visual changes, also inspect the running app across light/dark themes and relevant scaling settings.

## Security

This editor handles arbitrary files the user opens, so treat document content as untrusted input throughout. Markdown parsing must stay memory-safe: every source range derived from a document has to be bounds-checked before it reaches `substring`, `lineRange`, or an attributed string. A malformed document that produces a range past the end of its text is a crash, not a cosmetic bug. The projection layer is the usual source of these, because it maps between two different coordinate spaces; assert there that a mapped range never leaves the source, and add a regression case with a real fixture whenever that mapping changes.

Recovery journals under Application Support hold full unsaved document text plus the source file path, in plaintext. Treat them as sensitive: never copy a real user document, recovery journal, or file path into a test, fixture, commit message, CI log, or issue. Tests and native checks must build their own input in temporary directories, as the existing checks do.

The app has no network client and its entitlements deliberately omit network access; URLs in a document are parsed and styled, never fetched. Do not introduce a network dependency, or a sandbox entitlement beyond what `macos/mdwrite.entitlements` already grants, without calling that out in review.

Signing is local and ad-hoc, with the provisional identifier `dev.mdwrite.prototype`; this is not a notarized distribution. A Developer ID, notarization, or app-store credential belongs in the keychain or the environment and must never be committed, inlined into `bin/build-macos`, or baked into `macos/Info.plist`. Keep the build working without any credential present.

Diagnostics must not leak what they measured. `bin/benchmark-macos-typing --file` edits a private copy and prints metadata rather than the input path or contents; preserve that property when changing the harness.

No credentials, keys, or tokens belong in this repository at any point, and the editor has no reason to hold any. `./bin/scan-secrets` runs gitleaks over both the commit history and the working tree; it needs gitleaks on the path (`brew install gitleaks`). Run it before pushing, and prefer it over hand-written grep patterns.

The `.github/workflows/secret-scan.yml` workflow runs the same two passes on every push and pull request, against a full-depth checkout so a secret that was committed and later removed is still caught. It pins the scanner version and verifies the release checksum, and publishes SARIF to code scanning. Keep that pinned version and checksum updated together; a scan that silently resolves to an unpinned binary is not a check.

When a rule does fire, prefer fixing the commit over suppressing it. A false positive from a bundled binary asset belongs in a narrowly scoped `gitleaks:allow` comment or a path allowlist entry that names the file, never in a blanket ignore. Treat a real finding as compromised: rotate the credential, then rewrite the history that carried it.

## Commit & Pull Request Guidelines

Recent commits use short, imperative, sentence-case subjects, such as “Scale text with the desktop text size.” Follow that style. In pull requests, explain the behavior change, link relevant issues, and report validation commands and results. Include screenshots for visible UI changes. Never commit a credential, and keep real user documents and file paths out of commits; see the security section for the history scan to run before pushing.
