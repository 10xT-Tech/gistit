//
//  FlashcardsUseCases.swift
//  EnglishHelper — Domain (use cases)
//
//  Flashcard practice over the saved expressions: moving an expression into flashcards, the daily
//  plan and practice sets, answering a card (FSRS scheduling), and the Study dashboard's numbers.
//
//  Saving from Say it / Get it / See it (or catching cards from a phrase or photos) puts an expression
//  on the Caught list. The user moves the ones worth learning into flashcards (`enroll`), which creates
//  its two cards — recognition and recall — as `.new`. Caught = expressions without cards; deleting an
//  expression deletes its cards (StudyListInteractor).
//
//  The DAILY GOAL (a minimum: 25 / 50 / 75 / 100 / 150 cards, Settings) sizes the practice set:
//  - a set holds what's left of today's goal (distinct cards answered today count); once the goal is
//    met, "more" sets of the goal's size can follow — studying more, less, or skipping a day all just
//    move today's numbers, nothing is lost: an unanswered due card stays due;
//  - the set is split among the stages — learning, young, mature, new — PROPORTIONALLY to what's
//    available today (`SetComposer.quotas`). New cards count at most the set's size, so a deck of
//    thousands of new cards can't crowd out the reviews; the bigger the review backlog, the smaller
//    the new share;
//  - within a stage the cards are drawn AT RANDOM, weighted by how overdue they are (an overdue card
//    is likelier, so none is postponed forever), and both directions of one expression aren't put in
//    the same set while other cards can fill it; the set is shuffled;
//  - available today: learning cards, review cards due before the end of today, and new cards — a
//    recall card only after its recognition card was first answered on an earlier day.
//

import Foundation

/// A card together with the expression it asks about.
public struct Flashcard: Sendable, Equatable, Identifiable {
    public let card: ReviewCard
    public let expression: Expression
    public var id: UUID { card.id }

    public init(card: ReviewCard, expression: Expression) {
        self.card = card
        self.expression = expression
    }
}

/// How many cards of each stage a set holds (or could hold).
public struct StageCounts: Sendable, Equatable {
    public var new: Int
    public var learning: Int
    public var young: Int
    public var mature: Int
    public var total: Int { new + learning + young + mature }

    public init(new: Int = 0, learning: Int = 0, young: Int = 0, mature: Int = 0) {
        self.new = new
        self.learning = learning
        self.young = young
        self.mature = mature
    }

    public subscript(stage: CardStage) -> Int {
        get {
            switch stage {
            case .new: new
            case .learning: learning
            case .young: young
            case .mature: mature
            }
        }
        set {
            switch stage {
            case .new: new = newValue
            case .learning: learning = newValue
            case .young: young = newValue
            case .mature: mature = newValue
            }
        }
    }
}

/// Today against the daily goal.
public struct DailyPlan: Sendable, Equatable {
    /// The daily goal (a minimum).
    public let goal: Int
    /// Distinct cards answered today.
    public let studied: Int
    /// Cards waiting today, by stage (learning, reviews due, new available).
    public let available: StageCounts
    /// What the next set would hold, by stage.
    public let nextSet: StageCounts

    public var remaining: Int { max(0, goal - studied) }
    public var goalReached: Bool { studied >= goal }
    /// Learning and review cards due today — the backlog included.
    public var due: Int { available.learning + available.young + available.mature }

    public init(goal: Int, studied: Int, available: StageCounts, nextSet: StageCounts) {
        self.goal = goal
        self.studied = studied
        self.available = available
        self.nextSet = nextSet
    }
}

/// Cards by how well they're known — the dashboard's distribution bar.
public typealias CardDistribution = StageCounts

/// Answers given on one calendar day.
public struct DailyReviews: Sendable, Equatable {
    /// Start of the day.
    public let day: Date
    public let count: Int

    public init(day: Date, count: Int) {
        self.day = day
        self.count = count
    }
}

/// Everything the Study dashboard shows.
public struct StudyStats: Sendable, Equatable {
    public let today: DailyPlan
    /// Expressions in flashcards.
    public let inStudy: Int
    /// Expressions caught (saved, not in flashcards yet).
    public let caught: Int
    public let distribution: CardDistribution
    /// The last `StudyStats.days` days, oldest first; the last entry is today.
    public let reviewsByDay: [DailyReviews]
    public var reviewsToday: Int { reviewsByDay.last?.count ?? 0 }

    public static let days = 7

    public init(today: DailyPlan, inStudy: Int, caught: Int, distribution: CardDistribution,
                reviewsByDay: [DailyReviews]) {
        self.today = today
        self.inStudy = inStudy
        self.caught = caught
        self.distribution = distribution
        self.reviewsByDay = reviewsByDay
    }
}

public protocol FlashcardsUseCase: Sendable {
    func stats(now: Date) async throws -> StudyStats
    /// A practice set: what's left of today's goal, or — `extra` — another goal-sized set beyond it.
    func queue(now: Date, extra: Bool) async throws -> [Flashcard]
    /// Move a caught expression into flashcards (both directions). No-op if it's already there.
    func enroll(_ expressionID: UUID, now: Date) async throws
    /// Expressions that are in flashcards — everything else is on the Caught list.
    func enrolledExpressionIDs() async throws -> Set<UUID>
    /// The cards of the saved expressions (two per expression in flashcards).
    func enrolledCards() async throws -> [ReviewCard]
    /// Answer a card: reschedules it, stores it, logs the answer and returns the card's new state.
    func rate(_ card: ReviewCard, _ rating: ReviewRating, now: Date) async throws -> ReviewCard
    /// How long until the card returns for each possible answer.
    func previews(for card: ReviewCard, now: Date) -> [ReviewRating: TimeInterval]
    /// Learning cards due within this window come back in the current session rather than later.
    var learnAhead: TimeInterval { get }
}

public extension FlashcardsUseCase {
    func queue(now: Date) async throws -> [Flashcard] { try await queue(now: now, extra: false) }
}

/// The goals Settings offers.
public enum DailyGoalOptions {
    public static let all = [25, 50, 75, 100, 150]
    public static let `default` = 50
}

public struct FlashcardsInteractor: FlashcardsUseCase {
    private let expressions: ExpressionRepository
    private let cards: ReviewCardRepository
    private let scheduler: FSRS
    private let dailyGoal: @Sendable () -> Int
    private let calendar: Calendar
    private let makeRandom: @Sendable () -> any RandomNumberGenerator
    private let analytics: (any AnalyticsTracking)?
    public let learnAhead: TimeInterval = 20 * 60   // Anki's default

    public init(expressions: ExpressionRepository, cards: ReviewCardRepository, scheduler: FSRS = FSRS(),
                dailyGoal: @escaping @Sendable () -> Int = { DailyGoalOptions.default },
                calendar: Calendar = .current,
                makeRandom: @escaping @Sendable () -> any RandomNumberGenerator = { SystemRandomNumberGenerator() },
                analytics: (any AnalyticsTracking)? = nil) {
        self.expressions = expressions
        self.cards = cards
        self.scheduler = scheduler
        self.dailyGoal = dailyGoal
        self.calendar = calendar
        self.makeRandom = makeRandom
        self.analytics = analytics
    }

    public func stats(now: Date) async throws -> StudyStats {
        let deck = try await loadDeck()
        let pools = available(deck, now: now)

        var distribution = CardDistribution()
        for card in deck.cards { distribution[card.stage] += 1 }

        let goal = dailyGoal()
        let studied = studiedToday(deck, now: now)
        let size = studied >= goal ? goal : goal - studied
        let plan = DailyPlan(goal: goal, studied: studied, available: pools.counts,
                             nextSet: SetComposer.quotas(size: size, available: pools.counts))

        let startOfToday = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(StudyStats.days - 1), to: startOfToday) ?? startOfToday
        let logs = try await cards.logs(since: firstDay)
        var perDay: [Date: Int] = [:]
        for log in logs { perDay[calendar.startOfDay(for: log.reviewedAt), default: 0] += 1 }
        let reviewsByDay = (0..<StudyStats.days).compactMap { offset -> DailyReviews? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyReviews(day: day, count: perDay[day] ?? 0)
        }

        return StudyStats(today: plan, inStudy: deck.enrolled.count,
                          caught: deck.expressions.count - deck.enrolled.count,
                          distribution: distribution, reviewsByDay: reviewsByDay)
    }

    public func queue(now: Date, extra: Bool) async throws -> [Flashcard] {
        let deck = try await loadDeck()
        let goal = dailyGoal()
        let size = extra ? goal : max(0, goal - studiedToday(deck, now: now))
        guard size > 0 else { return [] }
        var random = AnyRandom(makeRandom())
        return SetComposer.compose(size: size, pools: available(deck, now: now).byStage, now: now, random: &random)
    }

    public func enroll(_ expressionID: UUID, now: Date) async throws {
        let existing = Set(try await cards.all().filter { $0.expressionID == expressionID }.map(\.direction))
        for direction in CardDirection.allCases where !existing.contains(direction) {
            try await cards.save(ReviewCard(expressionID: expressionID, direction: direction, due: now))
        }
    }

    public func enrolledExpressionIDs() async throws -> Set<UUID> {
        Set(try await cards.all().map(\.expressionID))
    }

    public func enrolledCards() async throws -> [ReviewCard] {
        try await loadDeck().cards
    }

    public func rate(_ card: ReviewCard, _ rating: ReviewRating, now: Date) async throws -> ReviewCard {
        let next = scheduler.review(card, rating: rating, at: now)
        try await cards.save(next)
        // The answer is stored; the log only feeds the counts, so it mustn't fail the answer.
        try? await cards.appendLog(ReviewLog(cardID: card.id, rating: rating, state: card.state, reviewedAt: now))
        analytics?.track(.flashcardReviewed)
        return next
    }

    public func previews(for card: ReviewCard, now: Date) -> [ReviewRating: TimeInterval] {
        scheduler.preview(card, at: now).mapValues { $0.timeIntervalSince(now) }
    }

    // MARK: Deck

    /// The saved expressions and the cards of those still on the list (orphans are ignored).
    private struct Deck {
        let expressions: [Expression]
        let cards: [ReviewCard]
        let enrolled: [Expression]
        let byExpression: [UUID: [CardDirection: ReviewCard]]
    }

    private func loadDeck() async throws -> Deck {
        let expressions = try await self.expressions.all()
        let ids = Set(expressions.map(\.id))
        let cards = try await self.cards.all().filter { ids.contains($0.expressionID) }
        var byExpression: [UUID: [CardDirection: ReviewCard]] = [:]
        for card in cards { byExpression[card.expressionID, default: [:]][card.direction] = card }
        let enrolled = expressions.filter { byExpression[$0.id] != nil }
        return Deck(expressions: expressions, cards: cards, enrolled: enrolled, byExpression: byExpression)
    }

    private func studiedToday(_ deck: Deck, now: Date) -> Int {
        let startOfToday = calendar.startOfDay(for: now)
        return deck.cards.filter { ($0.lastReview ?? .distantPast) >= startOfToday }.count
    }

    /// What's waiting today, by stage.
    private func available(_ deck: Deck, now: Date) -> (byStage: [CardStage: [Flashcard]], counts: StageCounts) {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        var pools: [CardStage: [Flashcard]] = [:]
        for expression in deck.enrolled {
            let cards = deck.byExpression[expression.id] ?? [:]
            for card in cards.values {
                switch card.state {
                case .new:
                    if card.direction == .recall {
                        guard let first = cards[.recognition]?.firstReview, first < startOfToday else { continue }
                    }
                case .learning, .relearning:
                    break                                   // mid-steps: always waiting
                case .review:
                    guard card.due < endOfToday else { continue }
                }
                pools[card.stage, default: []].append(Flashcard(card: card, expression: expression))
            }
        }
        var counts = StageCounts()
        for (stage, cards) in pools { counts[stage] = cards.count }
        return (pools, counts)
    }
}

/// Builds a practice set from today's available cards (pure; the random source is injected).
public enum SetComposer {
    /// Split `size` among the stages proportionally to what's available — new cards counting at most
    /// `size` — rounding by largest remainders and passing any stage's shortfall on to the others.
    public static func quotas(size: Int, available: StageCounts) -> StageCounts {
        let stages = CardStage.allCases
        let target = min(size, available.total)
        guard target > 0 else { return StageCounts() }
        let weight: (CardStage) -> Double = { stage in
            Double(stage == .new ? min(available.new, size) : available[stage])
        }
        let totalWeight = stages.map(weight).reduce(0, +)
        var quotas = StageCounts()
        var remainders: [(CardStage, Double)] = []
        for stage in stages {
            let exact = Double(target) * weight(stage) / totalWeight
            quotas[stage] = min(Int(exact.rounded(.down)), available[stage])
            remainders.append((stage, exact - exact.rounded(.down)))
        }
        // Hand out what rounding (or a capped stage) left: largest remainder first, then any stage
        // with cards to spare.
        var left = target - quotas.total
        for (stage, _) in remainders.sorted(by: { $0.1 > $1.1 }) where left > 0 && quotas[stage] < available[stage] {
            quotas[stage] += 1
            left -= 1
        }
        while left > 0, let stage = stages.first(where: { quotas[$0] < available[$0] }) {
            let add = min(left, available[stage] - quotas[stage])
            quotas[stage] += add
            left -= add
        }
        return quotas
    }

    /// The set: `quotas` per stage, drawn at random — weighted by days overdue, one direction per
    /// expression while others can fill the quota — then shuffled.
    public static func compose<R: RandomNumberGenerator>(size: Int, pools: [CardStage: [Flashcard]], now: Date,
                                                         random: inout R) -> [Flashcard] {
        var counts = StageCounts()
        for (stage, cards) in pools { counts[stage] = cards.count }
        let quotas = quotas(size: size, available: counts)
        var picked: [Flashcard] = []
        var usedExpressions = Set<UUID>()
        // Learning first (mid-steps, most urgent), then reviews, then new.
        for stage in [CardStage.learning, .mature, .young, .new] {
            let quota = quotas[stage]
            guard quota > 0, let pool = pools[stage] else { continue }
            // Efraimidis–Spirakis weighted sampling: key = u^(1/w), take the largest keys.
            let ranked = pool.map { card -> (Flashcard, Double) in
                let overdueDays = max(0, now.timeIntervalSince(card.card.due) / 86_400)
                let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &random)
                return (card, pow(u, 1 / (1 + overdueDays)))
            }.sorted { $0.1 > $1.1 }.map(\.0)
            var chosen: [Flashcard] = [], siblings: [Flashcard] = []
            for card in ranked where chosen.count < quota {
                if usedExpressions.contains(card.expression.id) {
                    siblings.append(card)
                } else {
                    chosen.append(card)
                    usedExpressions.insert(card.expression.id)
                }
            }
            // A sibling only when nothing else could fill the quota.
            for card in siblings where chosen.count < quota { chosen.append(card) }
            picked += chosen
        }
        picked.shuffle(using: &random)
        return picked
    }
}

/// Type-erases a random number generator so it can be passed `inout`.
struct AnyRandom: RandomNumberGenerator {
    private var base: any RandomNumberGenerator
    init(_ base: any RandomNumberGenerator) { self.base = base }
    mutating func next() -> UInt64 { base.next() }
}
