import Foundation
import EditorCore

/// Only immutable, value-semantic inputs and outputs cross the worker boundary.
struct BackgroundServiceFailure: Error, LocalizedError, Sendable {
    let message: String
    init(_ error: any Error) { message = error.localizedDescription }
    var errorDescription: String? { message }
}

struct ExternalFileRead: Sendable {
    let url: URL
    let data: Data?
    let failure: BackgroundServiceFailure?
}

enum DocumentBackgroundServices {
    // Bound service concurrency separately from semantic analysis. A caller must
    // keep at most one pending read/count per document and validate its generation.
    private static let reads = DispatchQueue(label: "mdwrite.external-reads", qos: .utility,
                                            autoreleaseFrequency: .workItem)
    private static let counts = DispatchQueue(label: "mdwrite.word-counts", qos: .utility,
                                             autoreleaseFrequency: .workItem)

    nonisolated static func read(url: URL) async -> ExternalFileRead {
        await withCheckedContinuation { continuation in
            reads.async {
                do {
                    continuation.resume(returning: ExternalFileRead(url: url, data: try Data(contentsOf: url), failure: nil))
                } catch {
                    continuation.resume(returning: ExternalFileRead(url: url, data: nil, failure: BackgroundServiceFailure(error)))
                }
            }
        }
    }

    nonisolated static func wordCount(snapshot: String) async -> Int {
        await withCheckedContinuation { continuation in
            counts.async { continuation.resume(returning: EditorBehavior.wordCount(snapshot)) }
        }
    }
}

struct RecoveryWriteToken: Equatable, Sendable {
    let epoch: UInt64
    let revision: UInt64
}

/// Commands are submitted synchronously by the main actor, then performed in
/// order by one I/O owner. Cleanup barriers cannot be overtaken by old writes.
@MainActor
final class DocumentRecoveryWriter {
    typealias Completion = @MainActor @Sendable (Result<Bool, BackgroundServiceFailure>) -> Void

    // The only mutable non-main state is confined to this serial queue. It never
    // stores AppKit objects or accesses the document/text storage.
    private final class WorkerState: @unchecked Sendable {
        var epoch: UInt64 = 0
        var latestRevision: UInt64?
    }
    private static let queue = DispatchQueue(label: "mdwrite.recovery-owner", qos: .utility,
                                            autoreleaseFrequency: .workItem)
    private let state = WorkerState()
    private(set) var epoch: UInt64 = 0
    private var closed = false
    private struct Request: Sendable {
        let record: RecoveryRecord
        let store: RecoveryStore
        let token: RecoveryWriteToken
        let completion: Completion?
    }
    private var active = false
    private var pending: Request?
    private var latestRequestedRevision: UInt64?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    func token(revision: UInt64) -> RecoveryWriteToken {
        RecoveryWriteToken(epoch: epoch, revision: revision)
    }

    /// Returns false for an obsolete epoch/revision. While a write is active,
    /// only the latest pending snapshot is retained. Superseded requests have no
    /// completion; current failures/successes are delivered on the main actor.
    @discardableResult
    func write(_ record: RecoveryRecord, store: RecoveryStore,
               token: RecoveryWriteToken, completion: Completion? = nil) -> Bool {
        guard !closed, token.epoch == epoch,
              latestRequestedRevision.map({ token.revision >= $0 }) ?? true else { return false }
        latestRequestedRevision = token.revision
        let request = Request(record: record, store: store, token: token, completion: completion)
        if active {
            // Retain at most the newest snapshot while disk work is in progress.
            pending = request
        } else {
            submit(request)
        }
        return true
    }

    private func submit(_ request: Request) {
        active = true
        let state = self.state
        let token = request.token
        Self.queue.async { [weak self] in
            let result: Result<Bool, BackgroundServiceFailure>
            if token.epoch != state.epoch || state.latestRevision.map({ token.revision < $0 }) == true {
                result = .success(false)
            } else {
                // Advance before I/O so a failed latest write cannot be followed
                // by an older snapshot that appears to be the current recovery.
                state.latestRevision = token.revision
                do {
                    try request.store.write(request.record)
                    result = .success(true)
                } catch { result = .failure(BackgroundServiceFailure(error)) }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.active = false
                if let next = self.pending {
                    self.pending = nil
                    self.submit(next)
                }
                if self.epoch == token.epoch, !self.closed,
                   self.latestRequestedRevision == token.revision { request.completion?(result) }
                // A completion is allowed to enqueue new work synchronously.
                if !self.active {
                    let waiters = self.drainWaiters
                    self.drainWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            }
        }
    }

    /// Use for Save, undo-to-clean, reload, and discard. New unsaved edits must
    /// request a fresh token after this call; cleanup never removes those writes.
    func invalidate(remove id: UUID, store: RecoveryStore?, completion: Completion? = nil) {
        epoch &+= 1
        pending = nil
        latestRequestedRevision = nil
        let barrierEpoch = epoch
        let state = self.state
        Self.queue.async { [weak self] in
            state.epoch = barrierEpoch
            state.latestRevision = nil
            let result: Result<Bool, BackgroundServiceFailure>
            do {
                try store?.remove(id)
                result = .success(true)
            } catch { result = .failure(BackgroundServiceFailure(error)) }
            if let completion {
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == barrierEpoch else { return }
                    completion(result)
                }
            }
        }
    }

    func close(remove id: UUID, store: RecoveryStore?, completion: Completion? = nil) {
        guard !closed else { return }
        closed = true
        invalidate(remove: id, store: store, completion: completion)
    }

    /// Testing/termination preparation only: suspend, never block the main
    /// actor. No production edit/save callback should wait for this barrier.
    func flush() async {
        if active {
            await withCheckedContinuation { continuation in
                drainWaiters.append(continuation)
            }
        }
        // The queue barrier also includes cleanup commands, which do not retain
        // source snapshots or need a main-actor completion to advance.
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume() }
        }
    }

    /// Includes cleanup from documents already removed from NSDocumentController.
    static func flushCommands() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
