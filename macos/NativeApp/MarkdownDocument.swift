import AppKit
import EditorCore
import UniformTypeIdentifiers

@MainActor
final class MarkdownDocument: NSDocument {
    let sourceStorage = NSTextStorage()
    var encoding = try! MarkdownEncoding(data: Data())
    var baseline: Data?
    var baselineURL: URL?
    var recoveryID = UUID()
    var recoveryStore: RecoveryStore?
    var editorController: EditorWindowController?
    private var recoveryTimer: Timer?
    private var observationTimer: Timer?
    private var observedExternalData: Data?
    private var observedMissingFile = false
    private var conflictIsShown = false
    private var isLoading = false

    override init() {
        super.init()
        hasUndoManager = true
        recoveryStore = try? RecoveryStore.applicationStore()
    }

    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override var autosavingFileType: String? { nil } // The app-owned journal is the only recovery writer.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func makeWindowControllers() {
        let controller = EditorWindowController(document: self)
        editorController = controller
        addWindowController(controller)
        startObservation()
    }

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        try MainActor.assumeIsolated { try load(data) }
    }

    private func load(_ data: Data) throws {
        let decoded: MarkdownEncoding
        do { decoded = try MarkdownEncoding(data: data) }
        catch {
            throw NSError(domain: "mdwrite", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "This file is not valid UTF-8 Markdown.",
                NSLocalizedRecoverySuggestionErrorKey: "Open a UTF-8 text file. The original file has not been changed."
            ])
        }
        isLoading = true
        sourceStorage.setAttributedString(NSAttributedString(string: decoded.text))
        encoding = decoded
        baseline = data
        isLoading = false
        editorController?.editor.restyle()
    }

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url)
        try MainActor.assumeIsolated {
            try load(data)
            baselineURL = url
        }
    }

    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                         for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    override func data(ofType typeName: String) throws -> Data {
        encoding.data(for: sourceStorage.string)
    }

    nonisolated override func writeSafely(to url: URL, ofType typeName: String,
                                          for saveOperation: NSDocument.SaveOperationType) throws {
        try MainActor.assumeIsolated { try coordinatedWrite(to: url, ofType: typeName, for: saveOperation) }
    }

    private func coordinatedWrite(to url: URL, ofType typeName: String,
                                   for saveOperation: NSDocument.SaveOperationType) throws {
        let snapshot = try data(ofType: typeName)
        let coordinator = NSFileCoordinator(filePresenter: self)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                if saveOperation != .autosaveElsewhereOperation,
                   let original = baselineURL, original.standardizedFileURL == target.standardizedFileURL,
                   let baseline {
                    let disk = try? Data(contentsOf: target)
                    if disk != baseline {
                        throw NSError(domain: "mdwrite", code: 409,
                                      userInfo: [NSLocalizedDescriptionKey: "This file changed outside mdwrite. Save a copy or reload before replacing it."])
                    }
                }
                // Preserve NSDocument's atomic-save, backup, and file-attribute behavior.
                try super.writeSafely(to: target, ofType: typeName, for: saveOperation)
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
        if saveOperation != .autosaveElsewhereOperation {
            baseline = snapshot
            baselineURL = url
            encoding = try MarkdownEncoding(data: snapshot)
            observedExternalData = nil
            observedMissingFile = false
            do { try recoveryStore?.remove(recoveryID) }
            catch { editorController?.showStatus("Saved; recovery cleanup failed: \(error.localizedDescription)") }
        }
    }


    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if fileURL == nil {
            savePanel.nameFieldStringValue = EditorBehavior.suggestedFilename(sourceStorage.string)
        }
        return true
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        let view = MarkdownPrintRenderer.makeView(source: sourceStorage.string,
                                                 width: info.paperSize.width - info.leftMargin - info.rightMargin)
        return NSPrintOperation(view: view, printInfo: info)
    }

    func sourceChanged() {
        guard !isLoading else { return }
        // NSDocument observes the document undo manager; do not double-count edits here.
        editorController?.scheduleFooter()
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeRecovery() }
        }
    }

    func writeRecovery() {
        guard isDocumentEdited else {
            do { try recoveryStore?.remove(recoveryID) }
            catch { editorController?.showStatus("Recovery cleanup failed: \(error.localizedDescription)") }
            return
        }
        let record = RecoveryRecord(version: 1, id: recoveryID, text: sourceStorage.string,
                                    sourceURL: fileURL, sourceBaseline: baseline, updated: Date())
        do { try recoveryStore?.write(record) }
        catch { editorController?.showStatus("Recovery could not be saved: \(error.localizedDescription)") }
    }

    func restore(_ record: RecoveryRecord) {
        recoveryID = record.id
        sourceStorage.setAttributedString(NSAttributedString(string: record.text))
        // Recover as an untitled copy; stale or inaccessible source URLs cannot be overwritten.
        updateChangeCount(.changeDone)
    }

    override func close() {
        recoveryTimer?.invalidate()
        observationTimer?.invalidate()
        try? recoveryStore?.remove(recoveryID)
        super.close()
    }

    private func startObservation() {
        observationTimer?.invalidate()
        // Recheck the path instead of watching a replaceable inode. This also observes
        // uncoordinated writes and delete/recreate events missed by file presenters.
        observationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkExternalChange() }
        }
    }

    func checkExternalChange() {
        guard let url = baselineURL, let baseline, !conflictIsShown else { return }
        let disk = try? Data(contentsOf: url)
        guard disk != baseline else {
            observedExternalData = nil
            observedMissingFile = false
            return
        }
        if let disk, disk == observedExternalData { return }
        if disk == nil && observedMissingFile { return }
        guard let window = editorController?.window, window.attachedSheet == nil else { return }
        observedExternalData = disk
        observedMissingFile = disk == nil
        conflictIsShown = true
        writeRecovery()
        let alert = NSAlert()
        alert.messageText = disk == nil ? "The file is no longer available" : "The file changed outside mdwrite"
        alert.informativeText = "Your text is preserved. Reload uses the version on disk; keep your text and use Save As to create a copy."
        alert.addButton(withTitle: "Keep My Text")
        alert.addButton(withTitle: "Reload")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.conflictIsShown = false
            if response == .alertSecondButtonReturn, let disk {
                do {
                    try self.read(from: disk, ofType: "net.daringfireball.markdown")
                    self.undoManager?.removeAllActions()
                    self.updateChangeCount(.changeCleared)
                    try self.recoveryStore?.remove(self.recoveryID)
                    self.editorController?.refreshFooter()
                } catch { self.presentError(error) }
            } else {
                if !self.isDocumentEdited { self.updateChangeCount(.changeDone) }
                self.writeRecovery()
                self.editorController?.showStatus("External change detected — use Save As to keep both versions")
            }
        }
    }
}
