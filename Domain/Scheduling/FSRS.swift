//
//  FSRS.swift
//  EnglishHelper — Domain
//
//  The FSRS-5 spaced-repetition scheduler (Free Spaced Repetition Scheduler, open-spaced-repetition —
//  the algorithm in modern Anki) with its published default parameters, plus Anki-style learning
//  steps for new and forgotten cards. Pure: (card, answer, time) → the card's next state.
//
//  Model: each card has a stability S (days until recall probability drops to 90%) and a difficulty
//  D (1…10). Recall probability after t days is R = (1 + F·t/S)^C. A successful answer grows S — more
//  so for easy cards, low R (a hard-won recall) and low S; "Again" collapses it. The next interval is
//  the time until R falls to the desired retention (90% → exactly S days).
//
//  No interval fuzz: the schedule is deterministic (and so are the tests).
//

import Foundation

public struct FSRS: Sendable {
    /// FSRS-5 weights w0…w18.
    public var parameters: [Double]
    /// Target recall probability when a review card comes due.
    public var desiredRetention: Double
    /// Same-day steps for a new card before it graduates to day intervals (seconds).
    public var learningSteps: [TimeInterval]
    /// Same-day steps for a forgotten card before it returns to day intervals (seconds).
    public var relearningSteps: [TimeInterval]
    /// Longest interval, in days.
    public var maximumInterval: Int

    /// FSRS-5 default parameters (trained on a large body of Anki review history).
    public static let defaultParameters: [Double] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ]

    public init(
        parameters: [Double] = FSRS.defaultParameters,
        desiredRetention: Double = 0.9,
        learningSteps: [TimeInterval] = [60, 600],      // 1 min, 10 min (Anki's defaults)
        relearningSteps: [TimeInterval] = [600],        // 10 min
        maximumInterval: Int = 36_500
    ) {
        precondition(parameters.count == 19, "FSRS-5 takes 19 parameters")
        self.parameters = parameters
        self.desiredRetention = desiredRetention
        self.learningSteps = learningSteps
        self.relearningSteps = relearningSteps
        self.maximumInterval = maximumInterval
    }

    // MARK: Scheduling

    /// The card after answering it with `rating` at `now`.
    public func review(_ card: ReviewCard, rating: ReviewRating, at now: Date) -> ReviewCard {
        var next = card
        let elapsedDays = card.lastReview.map { max(0, now.timeIntervalSince($0) / Self.day) }

        switch card.state {
        case .new:
            next.stability = initialStability(rating)
            next.difficulty = initialDifficulty(rating)
            next.state = .learning
            next.step = 0
            schedule(&next, rating: rating, steps: learningSteps, at: now)

        case .learning, .relearning:
            next.stability = updatedStability(card, rating: rating, elapsedDays: elapsedDays)
            next.difficulty = nextDifficulty(card.difficulty, rating)
            schedule(&next, rating: rating,
                     steps: card.state == .learning ? learningSteps : relearningSteps, at: now)

        case .review:
            let r = retrievability(elapsedDays: elapsedDays ?? 0, stability: card.stability)
            next.difficulty = nextDifficulty(card.difficulty, rating)
            if rating == .again {
                next.stability = forgetStability(difficulty: card.difficulty, stability: card.stability,
                                                 retrievability: r)
                next.lapses += 1
                if relearningSteps.isEmpty {
                    next.due = now.addingTimeInterval(Double(interval(for: next.stability)) * Self.day)
                } else {
                    next.state = .relearning
                    next.step = 0
                    next.due = now.addingTimeInterval(relearningSteps[0])
                }
            } else {
                next.stability = recallStability(difficulty: card.difficulty, stability: card.stability,
                                                 retrievability: r, rating: rating)
                next.due = now.addingTimeInterval(Double(interval(for: next.stability)) * Self.day)
            }
        }

        next.reps += 1
        next.lastReview = now
        if next.firstReview == nil { next.firstReview = now }
        return next
    }

    /// When the card would come back for each answer — the labels under the rating buttons.
    public func preview(_ card: ReviewCard, at now: Date) -> [ReviewRating: Date] {
        Dictionary(uniqueKeysWithValues: ReviewRating.allCases.map { ($0, review(card, rating: $0, at: now).due) })
    }

    /// Learning / relearning steps (Anki's rules): Again restarts, Hard repeats the step (between the
    /// first two on step 0), Good advances or graduates, Easy graduates at once.
    private func schedule(_ card: inout ReviewCard, rating: ReviewRating, steps: [TimeInterval], at now: Date) {
        guard !steps.isEmpty, card.step < steps.count else { return graduate(&card, at: now) }
        switch rating {
        case .again:
            card.step = 0
            card.due = now.addingTimeInterval(steps[0])
        case .hard:
            let delay: TimeInterval
            if card.step == 0 {
                delay = steps.count >= 2 ? (steps[0] + steps[1]) / 2 : steps[0] * 1.5
            } else {
                delay = steps[card.step]
            }
            card.due = now.addingTimeInterval(delay)
        case .good:
            if card.step + 1 >= steps.count {
                graduate(&card, at: now)
            } else {
                card.step += 1
                card.due = now.addingTimeInterval(steps[card.step])
            }
        case .easy:
            graduate(&card, at: now)
        }
    }

    private func graduate(_ card: inout ReviewCard, at now: Date) {
        card.state = .review
        card.step = 0
        card.due = now.addingTimeInterval(Double(interval(for: card.stability)) * Self.day)
    }

    /// Stability after an answer in a (re)learning step: the short-term formula for a same-day
    /// repeat, the long-term one if a day or more has passed since the last answer.
    private func updatedStability(_ card: ReviewCard, rating: ReviewRating, elapsedDays: Double?) -> Double {
        guard let elapsed = elapsedDays, elapsed >= 1 else {
            return shortTermStability(card.stability, rating)
        }
        let r = retrievability(elapsedDays: elapsed, stability: card.stability)
        return rating == .again
            ? forgetStability(difficulty: card.difficulty, stability: card.stability, retrievability: r)
            : recallStability(difficulty: card.difficulty, stability: card.stability, retrievability: r, rating: rating)
    }

    // MARK: FSRS-5 formulas

    static let day: TimeInterval = 86_400
    static let decay = -0.5
    /// Chosen so that R = 0.9 exactly when t = S.
    static let factor = pow(0.9, 1 / decay) - 1

    /// Probability of recalling a card `elapsedDays` after its last review.
    public func retrievability(elapsedDays: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + Self.factor * elapsedDays / stability, Self.decay)
    }

    /// Days until recall probability falls to `desiredRetention`, rounded and clamped.
    public func interval(for stability: Double) -> Int {
        let days = stability / Self.factor * (pow(desiredRetention, 1 / Self.decay) - 1)
        return min(max(Int(days.rounded()), 1), maximumInterval)
    }

    func initialStability(_ rating: ReviewRating) -> Double {
        max(w(rating.rawValue - 1), 0.1)
    }

    func initialDifficulty(_ rating: ReviewRating) -> Double {
        clampDifficulty(rawInitialDifficulty(rating))
    }

    private func rawInitialDifficulty(_ rating: ReviewRating) -> Double {
        w(4) - exp(w(5) * Double(rating.rawValue - 1)) + 1
    }

    /// Linear damping towards 10 plus mean reversion towards the "Easy" starting difficulty.
    func nextDifficulty(_ difficulty: Double, _ rating: ReviewRating) -> Double {
        let delta = -w(6) * Double(rating.rawValue - 3)
        let damped = difficulty + delta * (10 - difficulty) / 9
        return clampDifficulty(w(7) * rawInitialDifficulty(.easy) + (1 - w(7)) * damped)
    }

    func shortTermStability(_ stability: Double, _ rating: ReviewRating) -> Double {
        max(stability * exp(w(17) * (Double(rating.rawValue) - 3 + w(18))), 0.1)
    }

    func recallStability(difficulty: Double, stability: Double, retrievability: Double,
                         rating: ReviewRating) -> Double {
        let hardPenalty = rating == .hard ? w(15) : 1
        let easyBonus = rating == .easy ? w(16) : 1
        return stability * (1 + exp(w(8)) * (11 - difficulty) * pow(stability, -w(9))
            * (exp((1 - retrievability) * w(10)) - 1) * hardPenalty * easyBonus)
    }

    /// Post-lapse stability — never above what the card had before forgetting it.
    func forgetStability(difficulty: Double, stability: Double, retrievability: Double) -> Double {
        let s = w(11) * pow(difficulty, -w(12)) * (pow(stability + 1, w(13)) - 1) * exp((1 - retrievability) * w(14))
        return max(min(s, stability), 0.1)
    }

    private func clampDifficulty(_ d: Double) -> Double { min(max(d, 1), 10) }
    private func w(_ i: Int) -> Double { parameters[i] }
}
