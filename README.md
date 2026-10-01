# mdwrite

A native Markdown editor for macOS, built with Swift and AppKit. Headings, code blocks, quotes, lists, and tables have distinct styling. Text wraps to the window, with system light/dark appearance.

## Build and run

Requires macOS 14 or later and Swift 6 through Apple Command Line Tools or Xcode. From the repository root:

```sh
./bin/build-macos
./bin/run-macos
```

The build creates `build/mdwrite.app`, signed for local development. A notarized release is not available yet.

## Using the editor

Documents open in read-only **View mode**. You can select, copy, search, and print. Press **E** in the document or click **Edit** to make changes; click **View** to lock editing again.

- Use the toolbar or **Format** menu to insert Markdown formatting.
- **Return** inserts a newline and continues lists or quotes; **Shift-Return** skips continuation.
- Use **⌘O** to open, **⌘S** to save, **⇧⌘S** to save as, **⌘F** to find, and **⌥⌘F** to find and replace.

Save changes explicitly. Unsaved drafts have recovery copies, and external-change checks help prevent overwriting work. Markdown markers such as `**` remain visible and dimmed.

## Development

```sh
./bin/test-macos
```

Tests require a logged-in macOS graphical session. See [native development](macos/README.md), [Markdown coverage](docs/macos-markdown-coverage.md), and [performance results](docs/macos-performance-results.md) for details and remaining limitations.

## Linux reference app

The original Qt 6 implementation remains in `src/`. It requires Qt 6 Base, Declarative, and Quick Controls 2, a C++ compiler, make, Qt 6 qmake, and an XDG desktop portal backend. Build with `./bin/build` and launch `./build/mdwrite`. On Arch Linux, `./bin/install` builds and installs the local package.

## License

See [LICENSE](LICENSE). The bundled iA Writer Mono font uses the [SIL Open Font License](fonts/OFL.txt).
