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

## Commit & Pull Request Guidelines

Recent commits use short, imperative, sentence-case subjects, such as “Scale text with the desktop text size.” Follow that style. In pull requests, explain the behavior change, link relevant issues, and report validation commands and results. Include screenshots for visible UI changes.
