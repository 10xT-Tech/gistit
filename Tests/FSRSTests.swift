//
//  FSRSTests.swift
//  EnglishHelperTests
//
//  The FSRS-5 scheduler: the forgetting curve, learning steps, and how review answers move
//  stability, difficulty and the next interval.
//

import Testing
import Foundation
import Domain

@Suite struct FSRSTests {
    private let fsrs = FSRS()
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400

    private func newCard() -> ReviewCard {
        ReviewCard(expressionID: UUID(), direction: .recognition, due: now)
    }

    /// A graduated card last seen `elapsedDays` ago.
    private func reviewCard(stability: Double, difficulty: Double, elapsedDays: Double) -> ReviewCard {
        ReviewCard(expressionID: UUID(), direction: .recognition, state: .review, due: now,
                   stability: stability, difficulty: difficulty, reps: 3,
                   lastReview: now.addingTimeInterval(-elapsedDays * day),
                   firstReview: now.addingTimeInterval(-30 * day))
    }

    @Test func recallProbabilityIsNinetyPercentAfterStabilityDays() {
        #expect(abs(fsrs.retrievability(elapsedDays: 10, stability: 10) - 0.9) < 1e-9)
        #expect(fsrs.retrievability(elapsedDays: 0, stability: 10) == 1)
        #expect(fsrs.retrievability(elapsedDays: 30, stability: 10) < 0.9)
    }

    @Test func intervalAtNinetyPercentRetentionIsTheStability() {
        #expect(fsrs.interval(for: 10) == 10)
        #expect(fsrs.interval(for: 0.2) == 1)                       // never below a day
        #expect(fsrs.interval(for: 1_000_000) == fsrs.maximumInterval)
    }

    /// A new card's first answer: Again 1 min, Hard 5.5 min (between the two steps), Good the next
    /// step (10 min), Easy straight to review with the "Easy" initial stability (~16 days).
    @Test func firstAnswerOnANewCard() {
        let card = newCard()
        let again = fsrs.review(card, rating: .again, at: now)
        #expect(again.state == .learning)
        #expect(again.due == now.addingTimeInterval(60))
        #expect(fsrs.review(card, rating: .hard, at: now).due == now.addingTimeInterval(330))
        let good = fsrs.review(card, rating: .good, at: now)
        #expect(good.state == .learning && good.step == 1)
        #expect(good.due == now.addingTimeInterval(600))
        let easy = fsrs.review(card, rating: .easy, at: now)
        #expect(easy.state == .review)
        #expect(easy.due == now.addingTimeInterval(16 * day))
        #expect(easy.reps == 1 && easy.firstReview == now && easy.lastReview == now)
    }

    /// Good, then Good again at the next step: the card graduates to a few days.
    @Test func learningGraduatesAfterTheLastStep() {
        let first = fsrs.review(newCard(), rating: .good, at: now)
        let later = now.addingTimeInterval(600)
        let graduated = fsrs.review(first, rating: .good, at: later)
        #expect(graduated.state == .review)
        let days = graduated.due.timeIntervalSince(later) / day
        #expect(days >= 3 && days <= 5)
        #expect(graduated.firstReview == now)                     // the first answer, not the latest
    }

    /// Review answers: Hard < Good < Easy, and the longer it's been (lower recall probability), the
    /// more a successful recall grows stability.
    @Test func reviewIntervalsAreOrdered() {
        let card = reviewCard(stability: 10, difficulty: 5, elapsedDays: 10)
        let preview = fsrs.preview(card, at: now)
        let hard = preview[.hard]!, good = preview[.good]!, easy = preview[.easy]!
        #expect(hard < good && good < easy)
        #expect(good.timeIntervalSince(now) > 10 * day)            // remembered at R = 0.9 → longer than before

        let earlyGood = fsrs.review(reviewCard(stability: 10, difficulty: 5, elapsedDays: 2), rating: .good, at: now)
        let lateGood = fsrs.review(card, rating: .good, at: now)
        #expect(lateGood.stability > earlyGood.stability)
    }

    /// "Again" on a review card is a lapse: relearning in 10 minutes, with stability cut.
    @Test func lapseGoesToRelearning() {
        let card = reviewCard(stability: 10, difficulty: 5, elapsedDays: 10)
        let lapsed = fsrs.review(card, rating: .again, at: now)
        #expect(lapsed.state == .relearning)
        #expect(lapsed.due == now.addingTimeInterval(600))
        #expect(lapsed.lapses == 1)
        #expect(lapsed.stability < card.stability)
        #expect(lapsed.difficulty > card.difficulty)

        let relearned = fsrs.review(lapsed, rating: .good, at: now.addingTimeInterval(600))
        #expect(relearned.state == .review)
    }

    /// Stages: new → learning (incl. relearning) → young → mature at a 21-day interval.
    @Test func stageFollowsStateAndInterval() {
        #expect(newCard().stage == .new)
        #expect(fsrs.review(newCard(), rating: .good, at: now).stage == .learning)
        #expect(fsrs.review(reviewCard(stability: 10, difficulty: 5, elapsedDays: 10), rating: .again, at: now).stage == .learning)
        var young = reviewCard(stability: 5, difficulty: 5, elapsedDays: 0)
        young.lastReview = now
        young.due = now.addingTimeInterval(20 * day)
        #expect(young.stage == .young)
        var mature = young
        mature.due = now.addingTimeInterval(21 * day)
        #expect(mature.stage == .mature)
    }

    @Test func difficultyFollowsTheAnswersAndStaysInRange() {
        let card = reviewCard(stability: 10, difficulty: 5, elapsedDays: 10)
        #expect(fsrs.review(card, rating: .again, at: now).difficulty > 5)
        #expect(fsrs.review(card, rating: .easy, at: now).difficulty < 5)
        var hardest = card
        for _ in 0..<50 { hardest = fsrs.review(hardest, rating: .again, at: now) }
        #expect(hardest.difficulty <= 10 && hardest.difficulty >= 1)
    }
}
