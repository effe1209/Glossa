//
//  MigrationSession.swift
//  Glossa
//
//  What the offer window is doing, apart from how it looks: the phase it is in and what each button
//  does. It holds no UI, so the flow can be tested. The window only shows `phase` and calls these.
//
//    choosing -> (Import) running -> finished
//                                 -> confirmingLargeAttachments -> (Copy / Not Now) -> finished
//                                 -> failed -> (Back / Close)
//             -> (Not Now) closes, nothing written
//             -> (Don't Import Ever) closes, the refusals written
//
//  Once the preferences (unit A) have been applied, `preferencesApplied` stays true for the rest of the
//  session, through errors and `backToChoice`: every way out of the window then asks for the restart,
//  because the stores still hold the old preferences and would write them back over the imported ones.
//  An error after that point is told as such: the settings were imported.
//

import Foundation
import Observation

/// A flag the copy polls from its background task and the window sets from the main actor.
final class MigrationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

@MainActor
@Observable
final class MigrationSession {
    enum Phase: Equatable {
        case choosing
        case running
        /// The attachments are large: nothing is copied until the reader says so.
        case confirmingLargeAttachments(bytes: Int64)
        case finished(MigrationResult)
        case failed(String)
        /// Nothing is left to import (a choice that could not be completed left no offer, or the offer
        /// went away): said plainly, never shown as a finished import.
        case nothingLeft(String)
    }

    /// What the reader is shown at the end.
    struct MigrationResult: Equatable {
        var preferences: MigrationSummary?
        var files: FilesResultSummary?
        /// The reader left the large attachments for later.
        var filesPostponed = false
        var needsRestart = false

        init(needsRestart: Bool = false) { self.needsRestart = needsRestart }

        /// Whether everything that was offered is done: the files are copied (or there were none) and none was
        /// left for later. A partial, cancelled or failed copy is not, and the window does not say "finished".
        var isComplete: Bool { !filesPostponed && (files?.completed ?? true) }

        /// The heading of the result.
        var title: String { isComplete ? "Import finished" : "Import not complete" }
    }

    private(set) var phase: Phase = .choosing
    /// What the window offers; read again after an error, because a choice may have changed it.
    private(set) var prompt: MigrationPrompt
    /// The preferences were applied at some point in this session. Never reset.
    private(set) var preferencesApplied = false
    private let coordinator: CombinedMigrationCoordinator
    /// Called when the window should close; `true` asks for the restart.
    private let finish: (_ relaunch: Bool) -> Void
    /// Whether the import runs on the next turn of the run loop (so the window can show it), as in the app.
    private let defersWork: Bool
    @ObservationIgnored private var carried = MigrationResult()
    @ObservationIgnored private var work: Task<Void, Never>?
    /// A job holds the coordinator from `perform` until its outcome is applied. At most one at a time.
    @ObservationIgnored private var jobInFlight = false
    /// `finish` was called: the window is gone, and no further action is accepted.
    @ObservationIgnored private var closed = false
    /// The reader asked to cancel and the copy has not yet stopped.
    private(set) var isCancelling = false
    /// The copy has begun moving files into place: it cannot be cancelled any more and is finishing.
    private(set) var isPastPointOfNoReturn = false
    /// Whether the window offers Cancel: a copy is running, can still be stopped and was not asked to.
    var canCancel: Bool { !closed && jobInFlight && phase == .running && !isPastPointOfNoReturn && !isCancelling }

    init(prompt: MigrationPrompt, coordinator: CombinedMigrationCoordinator, defersWork: Bool = true,
         finish: @escaping (_ relaunch: Bool) -> Void) {
        self.prompt = prompt
        self.coordinator = coordinator
        self.defersWork = defersWork
        self.finish = finish
    }

    // MARK: Buttons

    /// A choice is accepted only while choosing, and never while a job runs.
    @discardableResult
    func choose(_ choice: MigrationChoice) -> Bool {
        guard !closed, !jobInFlight, case .choosing = phase else { return false }
        switch choice {
        case .notNow:
            _ = coordinator.choose(.notNow)
            leave()
        case .neverImport:
            let outcome = coordinator.choose(.neverImport)
            if let failure = outcome.failure { phase = .failed(failure) } else { leave() }
        case .importNow:
            phase = .running
            let coordinator = coordinator
            perform { cancelled, past in coordinator.choose(.importNow, isCancelled: cancelled, pointOfNoReturn: past) }
        }
        return true
    }

    /// The answer to "copy the large attachments?". Accepted only while that question is on screen.
    @discardableResult
    func confirmLargeAttachments(_ copy: Bool) -> Bool {
        guard !closed, !jobInFlight, case .confirmingLargeAttachments = phase else { return false }
        guard copy else {
            // Not now: the files stay where they are, nothing is written, and the offer comes back.
            var result = carried
            result.filesPostponed = true
            conclude(result)
            return true
        }
        phase = .running
        let coordinator = coordinator
        perform { cancelled, past in coordinator.copyFiles(confirmLargeAttachments: true, isCancelled: cancelled, pointOfNoReturn: past) }
        return true
    }

    /// Asks the running copy to stop. It stops at its next check if it has not passed the point where
    /// files start to be moved into place; otherwise it finishes, and the result says what happened.
    func cancel() {
        guard canCancel else { return }
        isCancelling = true
        work?.cancel()
    }

    /// The copy tells it has passed the point where it can be stopped. A cancel asked a moment too late is
    /// dropped from the display: the copy finishes, and the result says what was done. Ignored unless a
    /// copy is running.
    private func copyPassedPointOfNoReturn() {
        guard !closed, jobInFlight, case .running = phase else { return }
        isPastPointOfNoReturn = true
        isCancelling = false
    }

    /// Waits for the background work to be done and its result applied. For tests.
    func waitForWork() async { await work?.value }

    deinit { work?.cancel() }

    /// Whether the window has reached the end of what it can show: a result, an error or "nothing left".
    private var isEndPhase: Bool {
        switch phase {
        case .finished, .failed, .nothingLeft: return true
        case .choosing, .running, .confirmingLargeAttachments: return false
        }
    }

    /// The restart, once the preferences were applied. Refused while anything is running or being asked.
    @discardableResult
    func restart() -> Bool {
        guard !closed, !jobInFlight, preferencesApplied, isEndPhase else { return false }
        closed = true
        finish(true)
        return true
    }

    /// Leaves the window. After the preferences were applied that is a restart, whichever button said so.
    /// Refused while a job runs or while the choice or a question is still on screen.
    @discardableResult
    func close() -> Bool {
        guard !closed, !jobInFlight, isEndPhase else { return false }
        leave()
        return true
    }

    /// Back to the choice, with the offer read again: a refusal that was only half saved, or a copy that
    /// can no longer be offered, may have left nothing to choose from. Accepted only after an error.
    @discardableResult
    func backToChoice() -> Bool {
        guard !closed, !jobInFlight, case .failed = phase else { return false }
        carried = MigrationResult(needsRestart: preferencesApplied)
        prompt = coordinator.evaluate()
        phase = prompt.hasOffer ? .choosing : .nothingLeft(nothingLeftText())
        return true
    }

    private func leave() {
        closed = true
        finish(preferencesApplied)
    }

    private func nothingLeftText() -> String {
        let reasons = prompt.explanations
        return "There is nothing left to import." + (reasons.isEmpty ? "" : "\n\n" + reasons.joined(separator: "\n"))
    }

    // MARK: Work

    /// Runs `job` off the main actor and applies its outcome here. A job that is cancelled sees it through
    /// `isCancelled`; its outcome is applied all the same, so the phase always says what really happened.
    private func perform(_ job: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool,
                                                    _ pointOfNoReturn: @escaping @Sendable () -> Void) -> CombinedOutcome) {
        guard !jobInFlight else { return }      // never a second job: the coordinator belongs to the one that runs
        let token = MigrationCancellation()
        isCancelling = false
        isPastPointOfNoReturn = false
        jobInFlight = true
        guard defersWork else {
            // On the main actor already: the signal is applied at once.
            let outcome = job({ token.isCancelled }, { MainActor.assumeIsolated { self.copyPassedPointOfNoReturn() } })
            jobInFlight = false
            isPastPointOfNoReturn = false
            apply(outcome)
            return
        }
        work = Task { [weak self] in
            let signal: @Sendable () -> Void = { Task { @MainActor in self?.copyPassedPointOfNoReturn() } }
            let outcome = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) { job({ token.isCancelled }, signal) }.value
            } onCancel: {
                token.cancel()
            }
            guard let self else { return }
            self.jobInFlight = false
            self.isCancelling = false
            self.isPastPointOfNoReturn = false
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: CombinedOutcome) {
        // What was applied is remembered first, so that a failure after it cannot lose it.
        if let preferences = outcome.preferences, case .imported(let report) = preferences {
            carried.preferences = MigrationSummary(report)
        }
        if outcome.needsRestart { preferencesApplied = true }
        carried.needsRestart = preferencesApplied
        if let failure = outcome.failure { phase = .failed(failure); return }
        if outcome.preferences == nil, outcome.files == nil, outcome.filesNeedConfirmation == nil {
            // Nothing was offered any more: say so instead of reporting an import that did nothing.
            prompt = coordinator.evaluate()
            phase = .nothingLeft(nothingLeftText())
            return
        }
        if let bytes = outcome.filesNeedConfirmation {
            phase = .confirmingLargeAttachments(bytes: bytes)
            return
        }
        if let report = outcome.files { carried.files = FilesResultSummary(report) }
        conclude(carried)
    }

    private func conclude(_ result: MigrationResult) {
        phase = .finished(result)
    }
}
