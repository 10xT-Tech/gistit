//
//  FixCardsViewModel.swift
//  EnglishHelper — Presentation
//
//  In flashcards → "Fix cards", one sheet from start to end: it reads the phrases (with progress) and
//  counts what each mode would cover; the user picks a mode — only the incomplete ones, all, continue
//  all, start over — and the run goes through them with a two-part progress: sent to the model (grey)
//  and answered (green). Stop keeps what's done and where it stopped.
//

import Foundation
import Domain

@MainActor
@Observable
public final class FixCardsViewModel: Identifiable {
    public enum Phase: Equatable { case surveying, choosing, running, done, stopped, failed }

    public let id = UUID()
    public private(set) var phase: Phase = .surveying
    /// Reading the phrases before a run, and — once read — what each mode covers.
    public private(set) var survey = FixSurvey(checked: 0, total: 0)
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

    /// What the modes cover: all phrases (start / continue / start over), only the incomplete ones.
    public var all: FixCounts? { survey.all }
    public var incomplete: FixCounts? { survey.incomplete }

    /// Read the phrases and count what each mode covers.
    public func prepare() {
        guard task == nil, phase == .surveying else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await step in self.fixCards.survey() { self.survey = step }
                self.phase = (self.survey.all?.total ?? 0) > 0 ? .choosing : .done
            } catch is CancellationError {
                self.phase = .stopped
            } catch {
                self.errorMessage = presentableError(error).message
                self.phase = .failed
            }
            self.task = nil
        }
    }

    /// Go through the scope's phrases — `restart`: all of them again, not from where its last run stopped.
    public func run(_ scope: FixScope, restart: Bool) {
        guard task == nil, phase == .choosing else { return }
        phase = .running
        let studied = studiedLanguage(), native = nativeLanguage()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let steps = self.fixCards(scope, studiedLanguage: studied, nativeLanguage: native, restart: restart)
                for try await step in steps {
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
            self.task = nil
        }
    }

    public var isRunning: Bool { phase == .running }
    public var isSurveying: Bool { phase == .surveying }
    /// Reading or running — Stop is offered instead of Done.
    public var isBusy: Bool { phase == .surveying || phase == .running }

    /// Stop reading, or stop after the current batch; everything fixed so far stays, and the next run
    /// continues.
    public func stop() {
        task?.cancel()
    }
}
