import AppKit
import EditorCore
import UniformTypeIdentifiers

@MainActor
final class MarkdownDocument: NSDocument {
    let sourceStorage = MarkdownTextStorage()
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
    private var isClosed = false
    private var serviceEpoch: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private let recoveryWriter = DocumentRecoveryWriter()
    private var externalRead: Task<Void, Never>?
    private var observationRequested = false

    func flushRecovery() async { await recoveryWriter.flush() }

    private func clearRecovery(_ message: String = "Recovery cleanup failed") {
        recoveryWriter.invalidate(remove: recoveryID, store: recoveryStore) { [weak self] result in
            if case let .failure(error) = result { self?.editorController?.showStatus("\(message): \(error.localizedDescription)") }
        }
    }

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
        serviceEpoch &+= 1
        sourceRevision &+= 1
        recoveryTimer?.invalidate(); recoveryTimer = nil
        clearRecovery()
        isLoading = true
        sourceStorage.setAttributedString(NSAttributedString(string: decoded.text))
        encoding = decoded
        baseline = data
        isLoading = false
        editorController?.editor.didLoadSource()
        editorController?.editor.restyle()
        editorController?.scheduleFooter()
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
            serviceEpoch &+= 1
            clearRecovery("Saved; recovery cleanup failed")
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
        guard !isLoading, !isClosed else { return }
        sourceRevision &+= 1
        // NSDocument observes undo; never duplicate native dirty tracking.
        editorController?.scheduleFooter()
        // Bounded freshness even during continuous typing, rather than an
        // indefinitely postponed trailing debounce.
        if recoveryTimer == nil {
            recoveryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recoveryTimer = nil
                    self?.writeRecovery()
                }
            }
        }
    }

    func writeRecovery() {
        guard !isClosed else { return }
        guard isDocumentEdited else { clearRecovery(); return }
        guard let recoveryStore else { return }
        let token = recoveryWriter.token(revision: sourceRevision)
        let record = RecoveryRecord(version: 1, id: recoveryID, text: sourceStorage.string,
                                    sourceURL: fileURL, sourceBaseline: baseline, updated: Date())
        recoveryWriter.write(record, store: recoveryStore, token: token) { [weak self] result in
            if case let .failure(error) = result {
                self?.editorController?.showStatus("Recovery could not be saved: \(error.localizedDescription)")
            }
        }
    }

    func restore(_ record: RecoveryRecord) {
        serviceEpoch &+= 1
        sourceRevision &+= 1
        recoveryTimer?.invalidate(); recoveryTimer = nil
        clearRecovery()
        recoveryID = record.id
        sourceStorage.setAttributedString(NSAttributedString(string: record.text))
        // Recover as an untitled copy; stale or inaccessible source URLs cannot be overwritten.
        updateChangeCount(.changeDone)
        editorController?.editor.didLoadSource()
        editorController?.editor.restyle()
        editorController?.scheduleFooter()
    }

    override func close() {
        isClosed = true
        serviceEpoch &+= 1
        recoveryTimer?.invalidate(); recoveryTimer = nil
        observationTimer?.invalidate(); observationTimer = nil
        externalRead?.cancel()
        recoveryWriter.close(remove: recoveryID, store: recoveryStore)
        editorController?.editor.stopAnalysis()
        editorController?.stopServices()
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
        guard !isClosed, let url = baselineURL, baseline != nil, !conflictIsShown else { return }
        if externalRead != nil { observationRequested = true; return }
        let epoch = serviceEpoch
        externalRead = Task { [weak self] in
            let result = await DocumentBackgroundServices.read(url: url)
            guard let self else { return }
            self.externalRead = nil
            if !self.isClosed, self.serviceEpoch == epoch, self.baselineURL == url {
                self.handleExternalChange(result.data)
            }
            if self.observationRequested {
                self.observationRequested = false
                self.checkExternalChange()
            }
        }
    }

    private func handleExternalChange(_ disk: Data?) {
        guard let baseline, !isClosed, !conflictIsShown else { return }
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
        let conflictEpoch = serviceEpoch
        let conflictURL = baselineURL
        let documentURL = fileURL
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.conflictIsShown = false
            // A sheet response may arrive after Save As, another load, or close.
            // Its captured disk version belongs only to the original document.
            guard !self.isClosed, self.serviceEpoch == conflictEpoch,
                  self.baselineURL == conflictURL, self.fileURL == documentURL else { return }
            if response == .alertSecondButtonReturn, let disk {
                do {
                    try self.read(from: disk, ofType: "net.daringfireball.markdown")
                    self.undoManager?.removeAllActions()
                    self.updateChangeCount(.changeCleared)
                    self.clearRecovery()
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
