import AppKit
import EditorCore

private enum MarkdownWorkers {
    static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "mdwrite.markdown-analysis"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
}

enum MarkdownAnalysisPhase { case preview, complete }

/// One storage owner and one in-flight snapshot per document. UI edits never
/// wait for this worker; every application batch checks the current revision.
@MainActor
final class MarkdownAnalysisCoordinator: NSObject, @preconcurrency NSTextStorageDelegate {
    private weak var editor: MarkdownTextView?
    private weak var storage: NSTextStorage?
    private let deliverAnalysis: @MainActor (MarkdownAnalysisPhase, @escaping @MainActor () -> Void) -> Void
    private let afterAnalysis: @Sendable () -> Void
    private let afterWorkerCompletion: @Sendable () -> Void
    private(set) var revision: UInt64 = 0
    private var generation: UInt64 = 0
    private var closed = false
    private var workerRunning = false
    private var hasCompletedAnalysis = false
    private var workerOperation: BlockOperation?
    private var workerSerial: UInt64 = 0
    private var sourceRequestQueued = false
    private var analysisNeeded = false
    private var analysisTimer: Timer?
    private var applicationTimer: Timer?
    private var latestPlan: (revision: UInt64, plan: MarkdownStylePlan)?
    private var cursor: ApplicationCursor?
    private var attributes: [MarkdownStyle: [NSAttributedString.Key: Any]] = [:]
    private var fontSize: CGFloat = 20
    private(set) var backgroundPhaseMaxima: [String: Double] = [:]
    private(set) var mainThreadStageMaxima: [String: Double] = [:]
    private func record(_ stage: String, since started: TimeInterval) {
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        mainThreadStageMaxima[stage] = max(mainThreadStageMaxima[stage] ?? 0, elapsed)
    }

    private struct ApplicationCursor {
        let plan: MarkdownStylePlan
        let revision: UInt64
        let generation: UInt64
        let ranges: [ApplicationGroup]
        var group = 0
        var index = 0
        var offset = 0
    }

    private struct ApplicationGroup {
        let indices: Range<Int>
        let source: NSRange
    }

    var isPending: Bool {
        !closed && (workerRunning || analysisNeeded || analysisTimer != nil || cursor != nil || sourceRequestQueued)
    }
    var pendingDescription: String {
        let position = cursor.map { "group=\($0.group),index=\($0.index),offset=\($0.offset),generation=\($0.generation)/\(generation)" } ?? "none"
        return "worker=\(workerRunning) needed=\(analysisNeeded) timer=\(analysisTimer != nil) applicationTimer=\(applicationTimer != nil) composition=\(editor?.defersStyling ?? false) queued=\(sourceRequestQueued) cursor=\(position)"
    }

    init(editor: MarkdownTextView, storage: NSTextStorage,
         afterAnalysis: @escaping @Sendable () -> Void = {},
         afterWorkerCompletion: @escaping @Sendable () -> Void = {},
         deliverAnalysis: @escaping @MainActor (MarkdownAnalysisPhase, @escaping @MainActor () -> Void) -> Void = { _, work in work() }) {
        self.editor = editor
        self.storage = storage
        self.deliverAnalysis = deliverAnalysis
        self.afterAnalysis = afterAnalysis
        self.afterWorkerCompletion = afterWorkerCompletion
        super.init()
        storage.delegate = self
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !closed else { return }
        editor?.returnCache.invalidate(fromUTF16: editedRange.location)
        revision &+= 1
        generation &+= 1
        latestPlan = nil
        cursor = nil
        applicationTimer?.invalidate()
        applicationTimer = nil
        analysisNeeded = true
        // Foundation parsing itself is not interruptible. Skip later phases
        // of an obsolete snapshot, without starting another worker alongside it.
        workerOperation?.cancel()
        // A completed operation will not run its completion block again.
        // Drop its held result now; request remains deferred until after editing.
        if workerOperation?.isFinished == true {
            workerSerial &+= 1
            workerRunning = false
            workerOperation = nil
        }
        // Never rewrite attributes while storage is delivering a character edit.
        if !sourceRequestQueued {
            sourceRequestQueued = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sourceRequestQueued = false
                self.request()
            }
        }
    }

    func request() {
        guard !closed, let editor, let storage else { return }
        if fontSize != editor.writerFontSize {
            fontSize = editor.writerFontSize
            attributes.removeAll(keepingCapacity: true)
            generation &+= 1
        }
        guard !editor.defersStyling else { analysisNeeded = true; return }
        editor.typingAttributes = MarkdownStyler.baseAttributes(fontSize: fontSize)
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .textColor
        if storage.length < 8192 {
            analysisTimer?.invalidate(); analysisTimer = nil
            applicationTimer?.invalidate(); applicationTimer = nil
            cursor = nil
            analysisNeeded = false
            editor.typingAttributes = MarkdownStyler.apply(to: storage, fontSize: fontSize)
            editor.needsDisplay = true
            return
        }
        if let latestPlan, latestPlan.revision == revision {
            beginApplication(latestPlan.plan)
            return
        }
        analysisNeeded = true
        guard !workerRunning, analysisTimer == nil else { return }
        analysisTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.analysisTimer = nil
                self?.startWorker()
            }
        }
    }

    func invalidatePresentation() {
        attributes.removeAll(keepingCapacity: true)
        generation &+= 1
        request()
    }

    func didLoadSource() {
        hasCompletedAnalysis = false
        editor?.returnCache = MarkdownReturnCache()
    }

    private func startWorker() {
        guard !closed, !workerRunning, let editor, let storage, !editor.defersStyling else { return }
        let snapshotStarted = ProcessInfo.processInfo.systemUptime
        let snapshot = storage.string // Swift value snapshot; materialization happens on the worker.
        record("source-snapshot", since: snapshotStarted)
        let requestedRevision = revision
        let needsPreview = !hasCompletedAnalysis && storage.length > 131072
        workerRunning = true
        workerSerial &+= 1
        let requestedSerial = workerSerial
        let afterAnalysis = self.afterAnalysis
        let afterWorkerCompletion = self.afterWorkerCompletion
        analysisNeeded = false
        let operation = BlockOperation()
        operation.completionBlock = { [weak self, weak operation] in
            let cancelled = operation?.isCancelled == true
            afterWorkerCompletion()
            guard cancelled else { return }
            Task { @MainActor [weak self] in self?.workerCancelled(serial: requestedSerial) }
        }
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            // Make the first page readable without waiting for a multi-megabyte
            // Foundation parse. This provisional prefix never becomes the full
            // analysis: distant references and unfinished constructs converge
            // when the complete, same-revision plan arrives below.
            if needsPreview {
                let preview = autoreleasepool {
                    let text = snapshot as NSString
                    var end = min(text.length, 32768)
                    let newline = text.range(of: "\n", options: .backwards,
                                             range: NSRange(location: 0, length: end))
                    if newline.location != NSNotFound { end = NSMaxRange(newline) }
                    else if end < text.length {
                        end = EditorBehavior.composedCharacterRange(at: end, in: text).location
                    }
                    return MarkdownStylePlanBuilder.build(MarkdownAnalysis.analyze(text.substring(to: end)))
                }
                guard operation?.isCancelled == false else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.deliverAnalysis(.preview) { [weak self] in
                        guard let self, !self.closed, self.revision == requestedRevision,
                              self.latestPlan?.revision != requestedRevision else { return }
                        self.beginApplication(preview, provisional: true)
                    }
                }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result: (MarkdownStylePlan, MarkdownReturnCache, Double, Double)? = autoreleasepool {
                let analysis = MarkdownAnalysis.analyze(snapshot)
                afterAnalysis()
                guard operation?.isCancelled == false else { return nil }
                let analyzed = ProcessInfo.processInfo.systemUptime
                let plan = MarkdownStylePlanBuilder.build(analysis)
                return (plan, analysis.returnCache, (analyzed - started) * 1000,
                        (ProcessInfo.processInfo.systemUptime - analyzed) * 1000)
            }
            guard operation?.isCancelled == false, let (plan, returnCache, analysisMilliseconds, planMilliseconds) = result else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deliverAnalysis(.complete) { [weak self] in
                    self?.backgroundPhaseMaxima["analysis"] = max(self?.backgroundPhaseMaxima["analysis"] ?? 0, analysisMilliseconds)
                    self?.backgroundPhaseMaxima["style-plan"] = max(self?.backgroundPhaseMaxima["style-plan"] ?? 0, planMilliseconds)
                    self?.receive(plan, returnCache: returnCache, revision: requestedRevision,
                                  serial: requestedSerial)
                }
            }
        }
        workerOperation = operation
        MarkdownWorkers.queue.addOperation(operation)
    }

    private func workerCancelled(serial: UInt64) {
        guard serial == workerSerial else { return }
        // Invalidate delayed result callbacks before releasing this worker.
        workerSerial &+= 1
        workerRunning = false
        workerOperation = nil
        if !closed && analysisNeeded { request() }
    }

    private func receive(_ plan: MarkdownStylePlan, returnCache: MarkdownReturnCache,
                         revision requestedRevision: UInt64, serial requestedSerial: UInt64) {
        guard requestedSerial == workerSerial else { return }
        workerRunning = false
        workerOperation = nil
        guard !closed else { return }
        guard requestedRevision == revision else { request(); return }
        hasCompletedAnalysis = true
        editor?.returnCache = returnCache
        // Source revisions can introduce arbitrary quote/list indentation.
        // Retain resolved styles for this plan, not every historical revision.
        attributes.removeAll(keepingCapacity: true)
        latestPlan = (revision, plan)
        if editor?.defersStyling != true { beginApplication(plan) }
        else { analysisNeeded = true }
    }

    private func beginApplication(_ plan: MarkdownStylePlan, provisional: Bool = false) {
        guard let editor, let storage, plan.length == storage.length || provisional && plan.length <= storage.length,
              !editor.defersStyling else { return }
        generation &+= 1
        analysisNeeded = false
        applicationTimer?.invalidate(); applicationTimer = nil
        let visibleStarted = ProcessInfo.processInfo.systemUptime
        var visible = editor.visibleSourceRange()
        record("visible-glyph-lookup", since: visibleStarted)
        let text = storage.string as NSString
        visible = NSIntersectionRange(text.paragraphRange(for: visible), NSRange(location: 0, length: plan.length))
        var low = 0, high = plan.runs.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(plan.runs[mid].range) <= visible.location { low = mid + 1 } else { high = mid }
        }
        let start = low
        while low < plan.runs.count && plan.runs[low].range.location <= NSMaxRange(visible) { low += 1 }
        let end = low
        let visibleEnd = NSMaxRange(visible)
        let prefixEnd = start < plan.runs.count && plan.runs[start].range.location < visible.location ? start + 1 : start
        let suffixStart = end > 0 && NSMaxRange(plan.runs[end - 1].range) > visibleEnd ? end - 1 : end
        let groups = [
            ApplicationGroup(indices: start..<end, source: visible),
            ApplicationGroup(indices: 0..<prefixEnd, source: NSRange(location: 0, length: visible.location)),
            ApplicationGroup(indices: suffixStart..<plan.runs.count,
                             source: NSRange(location: visibleEnd, length: plan.length - visibleEnd))
        ].filter { !$0.indices.isEmpty && $0.source.length > 0 }
        cursor = ApplicationCursor(plan: plan, revision: revision, generation: generation,
                                   ranges: groups, index: groups.first?.indices.lowerBound ?? 0,
                                   offset: groups.first.map { max(plan.runs[$0.indices.lowerBound].range.location, $0.source.location) } ?? 0)
        applyBatch()
    }

    private func applyBatch() {
        applicationTimer = nil
        guard !closed, let storage, let editor, !editor.defersStyling,
              var state = cursor, state.revision == revision, state.generation == generation else { return }
        let started = ProcessInfo.processInfo.systemUptime
        storage.beginEditing()
        while state.group < state.ranges.count {
            let group = state.ranges[state.group]
            if state.index >= group.indices.upperBound {
                state.group += 1
                if state.group < state.ranges.count {
                    let next = state.ranges[state.group]
                    state.index = next.indices.lowerBound
                    state.offset = max(state.plan.runs[state.index].range.location, next.source.location)
                }
                // Flush before jumping to a nonadjacent source segment. Native
                // eager font fixing must not see a union spanning megabytes.
                break
            }
            let run = state.plan.runs[state.index]
            let resolved: [NSAttributedString.Key: Any]
            if let cached = attributes[run.style] { resolved = cached }
            else {
                resolved = MarkdownStyler.attributes(for: run.style, fontSize: fontSize)
                attributes[run.style] = resolved
            }
            // A canonical style run may span megabytes of plain text. Bound
            // enumeration itself, not just the number of outer run iterations.
            let start = max(state.offset, run.range.location)
            let runEnd = min(NSMaxRange(run.range), NSMaxRange(group.source))
            var end = min(runEnd, start + 4096)
            if end < runEnd {
                let text = storage.string as NSString
                let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: start, length: end - start))
                if newline.location != NSNotFound { end = NSMaxRange(newline) }
                else {
                    let cluster = EditorBehavior.composedCharacterRange(at: end, in: text)
                    end = min(runEnd, cluster.location > start ? cluster.location : NSMaxRange(cluster))
                }
            }
            let applyStarted = ProcessInfo.processInfo.systemUptime
            MarkdownStyler.applyChanged(resolved, to: storage, range: NSRange(location: start, length: end - start))
            record("attribute-diff-application", since: applyStarted)
            state.offset = end
            if end >= runEnd {
                state.index += 1
                if state.index < group.indices.upperBound { state.offset = max(state.plan.runs[state.index].range.location, group.source.location) }
            }
            if ProcessInfo.processInfo.systemUptime - started >= 0.003 { break }
        }
        let endStarted = ProcessInfo.processInfo.systemUptime
        storage.endEditing()
        record("storage-endEditing", since: endStarted)
        // Native fixing/layout can deliver reentrant appearance notifications.
        // Do not overwrite a replacement cursor with this older local copy.
        guard !closed, state.revision == revision, state.generation == generation else { return }
        editor.needsDisplay = true
        if state.group >= state.ranges.count {
            cursor = nil
        } else {
            cursor = state
            applicationTimer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyBatch() }
            }
        }
    }

    func shutdown() {
        closed = true
        workerOperation?.cancel(); workerOperation = nil
        generation &+= 1
        analysisTimer?.invalidate(); applicationTimer?.invalidate()
        analysisTimer = nil; applicationTimer = nil; cursor = nil; latestPlan = nil
        attributes.removeAll()
        if storage?.delegate === self { storage?.delegate = nil }
    }
}
