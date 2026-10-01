import AppKit
import ObjectiveC

/// Deterministic ordering checks use an isolated temporary journal; no user
/// recovery directory, named document, or clipboard is accessed.
@MainActor
enum NativeServiceChecks {
    static func run() async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.services", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory.appendingPathComponent("journal", isDirectory: true))
        let writer = DocumentRecoveryWriter()
        let id = UUID()
        func record(_ text: String) -> RecoveryRecord {
            RecoveryRecord(version: 1, id: id, text: text, sourceURL: nil,
                           sourceBaseline: nil, updated: Date())
        }

        let obsolete = writer.token(revision: 1)
        writer.write(record("before save"), store: store, token: obsolete)
        writer.invalidate(remove: id, store: store)
        try expect(!writer.write(record("stale request"), store: store, token: obsolete),
                   "Pre-save request was accepted after cleanup")
        await writer.flush()
        try expect(try store.records().isEmpty, "Cleanup was overtaken by an older write")

        writer.write(record("new unsaved source"), store: store, token: writer.token(revision: 5))
        writer.write(record("late old revision"), store: store, token: writer.token(revision: 4))
        await writer.flush()
        try expect(try store.records().first?.text == "new unsaved source", "Out-of-order revision replaced newer recovery")

        for revision in 6...105 {
            writer.write(record("revision \(revision)"), store: store, token: writer.token(revision: UInt64(revision)))
        }
        await writer.flush()
        try expect(try store.records().first?.text == "revision 105", "Coalesced writes did not preserve the latest revision")

        // A new epoch can have a lower revision after loading/restoring. Its
        // write follows the cleanup barrier and must survive it.
        writer.invalidate(remove: id, store: store)
        writer.write(record("after reload"), store: store, token: writer.token(revision: 0))
        await writer.flush()
        try expect(try store.records().first?.text == "after reload", "New epoch was removed by an obsolete cleanup")

        let other = DocumentRecoveryWriter()
        let otherID = UUID()
        let otherRecord = RecoveryRecord(version: 1, id: otherID, text: "second document", sourceURL: nil,
                                         sourceBaseline: nil, updated: Date())
        other.write(otherRecord, store: store, token: other.token(revision: 1))
        writer.close(remove: id, store: store)
        try expect(!writer.write(record("after close"), store: store, token: writer.token(revision: 10)),
                   "Closed writer accepted new work")
        await writer.flush()
        try expect(try store.records().map(\.id) == [otherID], "Closing one document removed another journal")
        other.close(remove: otherID, store: store)
        await other.flush()
        try expect(try store.records().isEmpty, "Close left a queued recovery write")

        let blockedPath = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blockedPath)
        let failureWriter = DocumentRecoveryWriter()
        let badStore = RecoveryStore(directory: blockedPath)
        let failed: Result<Bool, BackgroundServiceFailure> = await withCheckedContinuation { continuation in
            failureWriter.write(record("cannot write"), store: badStore, token: failureWriter.token(revision: 1)) {
                continuation.resume(returning: $0)
            }
        }
        if case .success = failed { try expect(false, "Recovery failure was reported as success") }

        let externalURL = directory.appendingPathComponent("external.md")
        let original = Data("outside".utf8)
        try original.write(to: externalURL)
        let read = await DocumentBackgroundServices.read(url: externalURL)
        try expect(read.url == externalURL && read.data == original && read.failure == nil,
                   "Asynchronous external read lost bytes or path")
        try FileManager.default.removeItem(at: externalURL)
        let missing = await DocumentBackgroundServices.read(url: externalURL)
        try expect(missing.data == nil && missing.failure != nil, "Missing external file did not report failure")
        let count = await DocumentBackgroundServices.wordCount(snapshot: "one **two** 👩‍💻 three")
        try expect(count == 3, "Background word count changed existing Markdown/Unicode behavior")
        try await runExternalSheetChecks(directory: directory, store: store)
        try await runTerminationChecks(store: store)
        print("PASS: recovery epochs/revisions/close/failures, external reads, counts, and normal-Quit fencing")
    }

    private static func runExternalSheetChecks(directory: URL, store: RecoveryStore) async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "mdwrite.external-sheet", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitUntil(_ condition: @MainActor () -> Bool) async throws {
            let deadline = Date(timeIntervalSinceNow: 3)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try expect(condition(), "External conflict sheet did not complete")
        }
        // Exercise AppKit's actual asynchronous sheet callback in this private
        // native process. Every named file and journal belongs to the fixture.
        for scenario in ["current", "reload", "path", "close"] {
            let url = directory.appendingPathComponent("sheet-\(scenario).md")
            let original = "# Original\n"
            let outside = "# Older external version\n"
            try Data(original.utf8).write(to: url)
            let document = MarkdownDocument()
            document.recoveryStore = store
            try document.read(from: url, ofType: "net.daringfireball.markdown")
            document.fileURL = url
            document.makeWindowControllers()
            let window = document.editorController!.window!
            defer { document.close() }
            try Data(outside.utf8).write(to: url)
            document.checkExternalChange()
            try await waitUntil { window.attachedSheet != nil }
            let sheet = window.attachedSheet!
            let expected: String
            switch scenario {
            case "reload":
                expected = "# Newer loaded source\n"
                try document.read(from: Data(expected.utf8), ofType: "net.daringfireball.markdown")
                document.updateChangeCount(.changeCleared)
            case "path":
                expected = original
                document.baselineURL = directory.appendingPathComponent("different-source.md")
            case "close":
                expected = original
                document.close()
            default: expected = outside
            }
            if window.attachedSheet === sheet {
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            }
            try await waitUntil { window.attachedSheet == nil }
            // endSheet detaches immediately; its completion is delivered later.
            try await Task.sleep(for: .milliseconds(30))
            try expect(document.sourceStorage.string == expected,
                       "\(scenario): obsolete external Reload overwrote current source")
            try expect(!document.isDocumentEdited,
                       "\(scenario): obsolete external response changed native dirty state")
            await document.flushRecovery()
            try expect(try store.records().allSatisfy { $0.id != document.recoveryID },
                       "\(scenario): obsolete external response created a recovery journal")
        }
        print("PASS: current and superseded external-sheet reload/path/close responses")
    }

    private static func runTerminationChecks(store: RecoveryStore) async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "mdwrite.termination", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        // This check runs only in the isolated native-test process, whose shared
        // controller must be empty. Never operate on an existing user's windows.
        guard let controller = NSDocumentController.shared as? MarkdownDocumentController,
              controller.documents.isEmpty else {
            try expect(false, "Termination check requires an isolated, empty document controller")
            return
        }
        let document = MarkdownDocument()
        document.recoveryStore = store
        document.sourceStorage.mutableString.setString(String(repeating: "unsaved source\n", count: 600_000))
        document.updateChangeCount(.changeDone)
        // Existing evidence plus an in-flight encode makes premature replies
        // observable. Clearing native dirty state avoids opening a real dialog.
        try store.write(RecoveryRecord(version: 1, id: document.recoveryID, text: "previous recovery",
                                       sourceURL: nil, sourceBaseline: nil, updated: Date()))
        document.writeRecovery()
        document.updateChangeCount(.changeCleared)
        controller.addDocument(document)
        var laterReply = false
        var duplicateLaterReply = false
        let accepted = await withCheckedContinuation { continuation in
            let delegate = ApplicationDelegate(documents: controller, terminationReply: {
                continuation.resume(returning: $0)
            })
            laterReply = delegate.applicationShouldTerminate(NSApp) == .terminateLater
            duplicateLaterReply = delegate.applicationShouldTerminate(NSApp) == .terminateLater
        }
        try expect(laterReply && duplicateLaterReply && accepted, "Normal Quit did not defer and accept termination")
        try expect(controller.documents.isEmpty, "Normal Quit replied before documents closed")
        try expect(try store.records().isEmpty, "Normal Quit replied before recovery cleanup drained")

        // Closing the last window before Quit leaves no document in the
        // controller snapshot, but its already-submitted cleanup must drain.
        let previouslyClosed = MarkdownDocument()
        previouslyClosed.recoveryStore = store
        previouslyClosed.sourceStorage.mutableString.setString(String(repeating: "pending cleanup\n", count: 600_000))
        previouslyClosed.updateChangeCount(.changeDone)
        try store.write(RecoveryRecord(version: 1, id: previouslyClosed.recoveryID, text: "previously closed recovery",
                                       sourceURL: nil, sourceBaseline: nil, updated: Date()))
        previouslyClosed.writeRecovery()
        previouslyClosed.close()
        let emptyAccepted = await withCheckedContinuation { continuation in
            let delegate = ApplicationDelegate(documents: controller, terminationReply: {
                continuation.resume(returning: $0)
            })
            _ = delegate.applicationShouldTerminate(NSApp)
        }
        try expect(emptyAccepted && controller.documents.isEmpty, "Quit with no open documents did not complete")
        try expect(try store.records().isEmpty, "Quit with no open documents bypassed pending recovery cleanup")

        let cancelled = NativeCancelCloseDocument()
        cancelled.updateChangeCount(.changeDone)
        controller.addDocument(cancelled)
        let declined = await withCheckedContinuation { continuation in
            let delegate = ApplicationDelegate(documents: controller, terminationReply: {
                continuation.resume(returning: $0)
            })
            _ = delegate.applicationShouldTerminate(NSApp)
        }
        try expect(!declined && cancelled.isDocumentEdited && controller.documents.contains(cancelled),
                   "Cancel terminated or discarded the open document")
        cancelled.close()
    }

}


/// Substitute only the user's Cancel decision. NSDocumentController's actual
/// close-all callback path remains under test, without presenting a modal panel.
@MainActor
private final class NativeCancelCloseDocument: NSDocument {
    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        guard let selector = shouldCloseSelector, let receiver = delegate as? NSObject,
              let implementation = class_getMethodImplementation(type(of: receiver), selector) else {
            preconditionFailure("Missing native document-close delegate callback")
        }
        typealias Reply = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        let reply = unsafeBitCast(implementation, to: Reply.self)
        reply(receiver, selector, self, false, contextInfo)
    }
}
