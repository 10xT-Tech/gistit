//
//  IncompleteCardsViewModel.swift
//  EnglishHelper — Presentation
//
//  Fix cards → "Incomplete cards": every phrase in flashcards that lacks an example, synonyms or a note,
//  with what it lacks and whether the model already answered for it and found nothing to add ("an
//  elbow" has no synonyms). Each can be fixed by hand — the card goes to the model alone — and the row
//  then says what came of it: filled in, nothing to add, or the error, in words and with its detail.
//

import Foundation
import Domain

@MainActor
@Observable
public final class IncompleteCardsViewModel {
    public enum RowStatus: Equatable {
        case fixing
        /// The model filled in what was missing: the card is complete now.
        case filled
        /// The model answered and still left these empty.
        case nothingToAdd([CardField])
        /// No answer for the card: why, in words, and the technical detail to pass on.
        case failed(message: String, detail: String, needsSubscription: Bool)
    }

    public private(set) var cards: [IncompleteCard] = []
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public private(set) var statuses: [UUID: RowStatus] = [:]

    private let fixCards: any FixCardsUseCase
    private let studiedLanguage: () -> String
    private let nativeLanguage: () -> String

    public init(fixCards: any FixCardsUseCase,
                studiedLanguage: @escaping () -> String = { StudiedLanguage.current.promptName },
                nativeLanguage: @escaping () -> String = { TargetLanguage.current.promptName }) {
        self.fixCards = fixCards
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
    }

    /// Still to fix — the model hasn't answered for them yet.
    public var toFix: [IncompleteCard] { cards.filter { !$0.nothingToAdd } }
    /// The model answered for them and had nothing to add.
    public var nothingToAdd: [IncompleteCard] { cards.filter(\.nothingToAdd) }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            cards = try await fixCards.incompleteCards()
            loadError = nil
        } catch {
            loadError = presentableError(error).message
        }
    }

    public func status(of card: IncompleteCard) -> RowStatus? { statuses[card.id] }

    /// Send this card to the model alone; the row says what came of it.
    public func fix(_ card: IncompleteCard) {
        guard statuses[card.id] != .fixing else { return }
        statuses[card.id] = .fixing
        let studied = studiedLanguage(), native = nativeLanguage()
        Task { [weak self] in
            guard let self else { return }
            do {
                let fixed = try await self.fixCards.fix(card.expression, studiedLanguage: studied, nativeLanguage: native)
                let missing = FixCardsInteractor.missing(fixed)
                if let index = self.cards.firstIndex(where: { $0.id == card.id }) {
                    self.cards[index] = IncompleteCard(expression: fixed, missing: missing.isEmpty ? card.missing : missing,
                                                       nothingToAdd: !missing.isEmpty)
                }
                self.statuses[card.id] = missing.isEmpty ? .filled : .nothingToAdd(missing)
            } catch {
                let presentable = presentableError(error)
                self.statuses[card.id] = .failed(message: presentable.message, detail: Self.detail(of: error),
                                                 needsSubscription: presentable.needsSubscription)
            }
        }
    }

    /// The error as it came — the case and what the service said — for the user to read or pass on.
    static func detail(of error: Error) -> String {
        switch error as? LLMError {
        case .requestFailed(let detail)?: "requestFailed: \(detail)"
        case .requestRejected(let detail)?: "requestRejected: \(detail)"
        case .invalidOutput(let detail)?: "invalidOutput: \(detail)"
        case let other?: String(describing: other)
        case nil: String(describing: error)
        }
    }
}
