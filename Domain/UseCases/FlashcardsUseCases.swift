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
//  A DAY is one practice (`PracticeDay`, kept by `PracticeDayStoring`): the first Start of the day draws
//  today's set and remembers it; the user may stop at any point, and Start continues the same set —
//  its unanswered cards, plus learning cards coming back within the day's limit
//  (`PracticeDay.maxAnswersPerCard` answers per card per day, so a hard card can't loop the day).
//
//  The DAILY GOAL (a minimum: 25 / 50 / 75 / 100 / 150 cards, Settings) sizes the set:
//  - today's set holds the goal (distinct cards answered today count); if the goal is raised during
//    the day the set is topped up; once the goal is met, "more" adds an extra set of
//    `DailyGoalOptions.extraSet` (25) to the day, whatever the goal —
//    studying more, less, or skipping a day all just move today's numbers, nothing is lost: an
//    unanswered due card stays due;
//  - LEARNING cards (mid-steps, including forgotten ones) go in first, up to the set's size — mistakes
//    are dealt with before anything new arrives;
//  - the rest is split among young, mature and new PROPORTIONALLY to what's available today
//    (`SetComposer.quotas`). New cards count at most the remaining room, so a deck of thousands of new
//    cards can't crowd out the reviews; the bigger the backlog, the smaller the new share;
//  - within a stage the cards are drawn AT RANDOM, weighted by how overdue they are (an overdue card
//    is likelier, so none is postponed forever); among new cards, RECALL cards that are ready come
//    first — the phrases you already recognise get their reverse direction before fresh phrases start;
//    both directions of one expression aren't put in the same set while other cards can fill it; the
//    set is shuffled;
//  - available today: learning cards, review cards due before the end of today, and new cards — a
//    recall card only once its recognition card has graduated to review on an earlier day (not while
//    it's still being learned or relearned after a lapse).
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
    /// Distinct cards answered today (what the day's draws count against the goal).
    public let studied: Int
    /// Of them, the ones still learning that come back today — answered, not finished.
    public let comingBack: Int
    /// Today's set, still to do — unanswered cards and learning cards coming back — by stage.
    public let pending: StageCounts
    /// Cards that could still be drawn into today's set, by stage.
    public let available: StageCounts
    /// What Start brings next (the rest of today's set and any top-up), by stage.
    public let nextSet: StageCounts

    public var remaining: Int { max(0, goal - studied) }
    /// Cards done for today: answered and not coming back today — what today's progress shows.
    public var finished: Int { max(0, studied - comingBack) }
    public var goalReached: Bool { studied >= goal }
    /// What "more" asks for: the rest of the goal, or — once it's met — an extra set.
    public var moreSize: Int { goalReached ? DailyGoalOptions.extraSet : remaining }
    /// Learning and review cards still due today — the backlog included.
    public var due: Int {
        pending.learning + pending.young + pending.mature + available.learning + available.young + available.mature
    }
    /// Anything left to practise today (today's set, or more to draw).
    public var hasMore: Bool { pending.total > 0 || available.total > 0 }

    public init(goal: Int, studied: Int, comingBack: Int = 0, pending: StageCounts = StageCounts(),
                available: StageCounts, nextSet: StageCounts) {
        self.goal = goal
        self.studied = studied
        self.comingBack = comingBack
        self.pending = pending
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
    /// Today's practice from where it stopped: the rest of today's set, topped up to the goal — or,
    /// `extra`, with an extra set (`DailyGoalOptions.extraSet`) drawn beyond it.
    func queue(now: Date, extra: Bool) async throws -> [Flashcard]
    /// How many times each card was answered today (the day's per-card limit).
    func answersToday(now: Date) async throws -> [UUID: Int]
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
    /// The size of each set beyond a met goal ("25 more"), whatever the goal.
    public static let extraSet = 25
}

public struct FlashcardsInteractor: FlashcardsUseCase {
    private let expressions: ExpressionRepository
    private let cards: ReviewCardRepository
    private let scheduler: FSRS
    private let dailyGoal: @Sendable () -> Int
    private let days: PracticeDayStoring
    private let calendar: Calendar
    private let makeRandom: @Sendable () -> any RandomNumberGenerator
    private let analytics: (any AnalyticsTracking)?
    /// The plan: on the free one the goal is `AccessTier.freeDailyCards` and there are no extra sets.
    private let access: (any SubscriptionManaging)?
    public let learnAhead: TimeInterval = 20 * 60   // Anki's default

    public init(expressions: ExpressionRepository, cards: ReviewCardRepository, scheduler: FSRS = FSRS(),
                dailyGoal: @escaping @Sendable () -> Int = { DailyGoalOptions.default },
                days: PracticeDayStoring = InMemoryPracticeDayStore(),
                calendar: Calendar = .current,
                makeRandom: @escaping @Sendable () -> any RandomNumberGenerator = { SystemRandomNumberGenerator() },
                analytics: (any AnalyticsTracking)? = nil,
                access: (any SubscriptionManaging)? = nil) {
        self.access = access
        self.expressions = expressions
        self.cards = cards
        self.scheduler = scheduler
        self.dailyGoal = dailyGoal
        self.days = days
        self.calendar = calendar
        self.makeRandom = makeRandom
        self.analytics = analytics
    }

    public func stats(now: Date) async throws -> StudyStats {
        let deck = try await loadDeck()
        let today = try await today(deck, now: now)

        var distribution = CardDistribution()
        for card in deck.cards { distribution[card.stage] += 1 }

        let (goal, extras) = await limits()
        let pending = StageCounts(today.pending)
        let available = StageCounts(today.drawable)
        let topUp = drawSize(goal: goal, today: today, extra: extras && today.studied >= goal && today.pending.isEmpty)
        let next = SetComposer.quotas(size: topUp, available: available)
        let comingBack = today.pending.filter { today.answers[$0.id] != nil }.count
        let plan = DailyPlan(goal: goal, studied: today.studied, comingBack: comingBack, pending: pending, available: available,
                             nextSet: StageCounts(new: pending.new + next.new, learning: pending.learning + next.learning,
                                                  young: pending.young + next.young, mature: pending.mature + next.mature))

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
        var today = try await today(deck, now: now)
        let (goal, extras) = await limits()
        let size = drawSize(goal: goal, today: today, extra: extra && extras)
        var drawn: [Flashcard] = []
        if size > 0 {
            var random = AnyRandom(makeRandom())
            var pools: [CardStage: [Flashcard]] = [:]
            for card in today.drawable { pools[card.card.stage, default: []].append(card) }
            drawn = SetComposer.compose(size: size, pools: pools, now: now, random: &random)
        }
        if !drawn.isEmpty || today.isNew {
            today.day.cardIDs += drawn.map(\.id)
            await days.save(today.day)
        }
        // Learning cards already due come first, then the rest of the set, then today's new draw, then
        // learning cards due a little later.
        let comingBack = today.pending.filter { today.answers[$0.id] != nil }
        let dueNow = comingBack.filter { $0.card.due <= now }.sorted { $0.card.due < $1.card.due }
        let later = comingBack.filter { $0.card.due > now }.sorted { $0.card.due < $1.card.due }
        let unanswered = today.pending.filter { today.answers[$0.id] == nil }
        return dueNow + unanswered + drawn + later
    }

    public func answersToday(now: Date) async throws -> [UUID: Int] {
        try await answers(since: calendar.startOfDay(for: now))
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

    /// Today's practice as it stands: the day's set, what's left of it, what could still be drawn.
    private struct Today {
        var day: PracticeDay
        /// The day had no set yet (the first Start of the day saves one, even if empty).
        let isNew: Bool
        let answers: [UUID: Int]
        /// Distinct cards answered today.
        let studied: Int
        /// The day's set, still to do: unanswered, or learning and under the day's limit.
        let pending: [Flashcard]
        /// Cards that could join the day: waiting today, not in the set, under the day's limit.
        let drawable: [Flashcard]
    }

    private func today(_ deck: Deck, now: Date) async throws -> Today {
        let startOfToday = calendar.startOfDay(for: now)
        let stored = await days.load()
        let isNew = stored?.day != startOfToday
        let day = isNew ? PracticeDay(day: startOfToday) : stored!
        let answers = try await answers(since: startOfToday)

        var byID: [UUID: Flashcard] = [:]
        for expression in deck.enrolled {
            for card in (deck.byExpression[expression.id] ?? [:]).values {
                byID[card.id] = Flashcard(card: card, expression: expression)
            }
        }
        let limit = PracticeDay.maxAnswersPerCard
        var inSet = Set<UUID>()
        var pending: [Flashcard] = []
        for id in day.cardIDs where inSet.insert(id).inserted {
            guard let card = byID[id] else { continue }               // deleted since
            let answered = answers[id] ?? 0
            let learning = card.card.state == .learning || card.card.state == .relearning
            if answered == 0 || (learning && answered < limit) { pending.append(card) }
        }
        let drawable = available(deck, now: now).byStage.values.joined()
            .filter { !inSet.contains($0.id) && (answers[$0.id] ?? 0) < limit }
        let studied = answers.keys.filter { byID[$0] != nil }.count
        return Today(day: day, isNew: isNew, answers: answers, studied: studied, pending: pending,
                     drawable: Array(drawable))
    }

    /// How many cards to draw now: up to the goal (cards still to do in the set count), or an extra
    /// set beyond it.
    /// Today's goal and whether extra sets are allowed — by the plan.
    private func limits() async -> (goal: Int, extras: Bool) {
        guard let access, await access.currentTier() == .free else { return (dailyGoal(), true) }
        return (AccessTier.freeDailyCards, false)
    }

    private func drawSize(goal: Int, today: Today, extra: Bool) -> Int {
        if extra { return DailyGoalOptions.extraSet }
        let unanswered = today.pending.filter { today.answers[$0.id] == nil }.count
        return max(0, goal - today.studied - unanswered)
    }

    private func answers(since start: Date) async throws -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for log in try await cards.logs(since: start) { counts[log.cardID, default: 0] += 1 }
        return counts
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
                    // Recall waits until the phrase is recognised: recognition in review, not since today.
                    if card.direction == .recall {
                        guard let recognition = cards[.recognition], recognition.state == .review,
                              (recognition.lastReview ?? .distantPast) < startOfToday else { continue }
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

extension StageCounts {
    /// Cards counted by stage.
    init(_ cards: [Flashcard]) {
        self.init()
        for card in cards { self[card.card.stage] += 1 }
    }
}

/// Builds a practice set from today's available cards (pure; the random source is injected).
public enum SetComposer {
    /// Learning cards first (up to `size`); the rest split among young, mature and new proportionally to
    /// what's available — new cards counting at most the remaining room — rounding by largest remainders
    /// and passing any stage's shortfall on to the others.
    public static func quotas(size: Int, available: StageCounts) -> StageCounts {
        var quotas = StageCounts()
        quotas.learning = min(available.learning, size)
        let room = size - quotas.learning
        let stages: [CardStage] = [.young, .mature, .new]
        let target = min(room, available.young + available.mature + available.new)
        guard target > 0 else { return quotas }
        let weight: (CardStage) -> Double = { stage in
            Double(stage == .new ? min(available.new, room) : available[stage])
        }
        let totalWeight = stages.map(weight).reduce(0, +)
        var remainders: [(CardStage, Double)] = []
        for stage in stages {
            let exact = Double(target) * weight(stage) / totalWeight
            quotas[stage] = min(Int(exact.rounded(.down)), available[stage])
            remainders.append((stage, exact - exact.rounded(.down)))
        }
        // Hand out what rounding (or a capped stage) left: largest remainder first, then any stage
        // with cards to spare.
        var left = target - (quotas.total - quotas.learning)
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

    /// The set: `quotas` per stage, drawn at random — weighted by days overdue, ready recall cards before
    /// recognition among the new ones, one direction per expression while others can fill the quota —
    /// then shuffled.
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
            }.sorted { lhs, rhs in
                // New cards: the reverse direction of phrases already recognised comes first.
                let lhsRecall = stage == .new && lhs.0.card.direction == .recall
                let rhsRecall = stage == .new && rhs.0.card.direction == .recall
                if lhsRecall != rhsRecall { return lhsRecall }
                return lhs.1 > rhs.1
            }.map(\.0)
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
