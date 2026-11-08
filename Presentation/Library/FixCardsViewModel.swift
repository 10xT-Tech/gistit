//
//  FixCardsViewModel.swift
//  EnglishHelper — Presentation
//
//  In flashcards → "Fix cards": one run over the phrases in flashcards (from where the last run
//  stopped, or from the start), with progress; Stop keeps what's done and where it stopped.
//

import Foundation
import Domain

@MainActor
@Observable
public final class FixCardsViewModel: Identifiable {
    public enum Phase: Equatable { case running, done, stopped, failed }

    public let id = UUID()
    public private(set) var phase: Phase = .running
    public private(set) var progress = FixProgress(processed: 0, total: 0, changed: 0, failed: 0)
    public private(set) var errorMessage: String?
    /// The plan's limit stopped the run: offer the subscription.
    public private(set) var needsSubscription = false

    private let fixCards: any FixCardsUseCase
    private let studiedLanguage: () -> String
    private let nativeLanguage: () -> String
    private var task: Task<Void, Never>?

    public init(fixCards: any FixCardsUseCase,
                studiedLanguage: @escaping () -> String = { StudiedLanguage.current.promptName },
                nativeLanguage: @escaping () -> String = { TargetLanguage.current.promptName }) {
        self.fixCards = fixCards
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
    }

    /// Go through the phrases — `restart`: all of them again, not from where the last run stopped.
    public func run(restart: Bool) {
        guard task == nil else { return }
        phase = .running
        let studied = studiedLanguage(), native = nativeLanguage()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await step in self.fixCards(studiedLanguage: studied, nativeLanguage: native, restart: restart) {
                    self.progress = step
                }
                self.phase = .done
            } catch is CancellationError {
                self.phase = .stopped
            } catch LLMError.cancelled {
                self.phase = .stopped
            } catch {
                let presentable = presentableError(error)
                self.errorMessage = presentable.message
                self.needsSubscription = presentable.needsSubscription
                self.phase = .failed
            }
        }
    }

    public var isRunning: Bool { phase == .running }

    /// Stop after the current batch; everything fixed so far stays, and the next run continues.
    public func stop() {
        task?.cancel()
    }
}
