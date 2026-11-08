//
//  FlashcardsInteractorTests.swift
//  EnglishHelperTests
//
//  Moving saved expressions into flashcards, the daily goal and practice sets (proportional stages,
//  random picks weighted by overdue days, no two directions of one expression in a set, recognition
//  before recall), answering a card, the dashboard numbers, and cards leaving with their expression.
//

import Testing
import Foundation
import Domain
import Adapters

/// Reproducible randomness for the set tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct FlashcardsInteractorTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func expression(_ en: String, ageDays: Double = 1) -> Domain.Expression {
        Domain.Expression(en: en, ru: "ru " + en, createdAt: now.addingTimeInterval(-ageDays * day))
    }

    /// The two never-answered cards an expression gets when moved in at `movedAt`.
    private func newCards(_ e: Domain.Expression, movedAt: Date) -> [ReviewCard] {
        CardDirection.allCases.map { ReviewCard(expressionID: e.id, direction: $0, due: movedAt) }
    }

    /// A review card of `e` due `dueInDays` from now (negative = overdue), last seen `interval` days before due.
    private func review(_ e: Domain.Expression, _ direction: CardDirection = .recognition, dueInDays: Double,
                        interval: Double = 5) -> ReviewCard {
        let due = now.addingTimeInterval(dueInDays * day)
        return ReviewCard(expressionID: e.id, direction: direction, state: .review, due: due, stability: interval,
                          difficulty: 5, reps: 3, lastReview: due.addingTimeInterval(-interval * day),
                          firstReview: now.addingTimeInterval(-40 * day))
    }

    private func make(_ expressions: [Domain.Expression], cards: [ReviewCard] = [], logs: [ReviewLog] = [],
                      goal: Int = 50, seed: UInt64 = 1,
                      days: PracticeDayStoring = InMemoryPracticeDayStore()) -> (FlashcardsInteractor, MockReviewCardRepository) {
        let repo = MockReviewCardRepository(seed: cards, logs: logs)
        let interactor = FlashcardsInteractor(expressions: MockExpressionRepository(seed: expressions), cards: repo,
                                              dailyGoal: { goal }, days: days, calendar: calendar,
                                              makeRandom: { SplitMix64(seed: seed) })
        return (interactor, repo)
    }

    // MARK: Moving in

    @Test func caughtIsNotPractised() async throws {
        let (sut, _) = make([expression("a"), expression("b")])
        #expect(try await sut.queue(now: now).isEmpty)
        #expect(try await sut.enrolledExpressionIDs().isEmpty)
    }

    /// Moving in creates both cards (once); the first day asks recognition only.
    @Test func movingInCreatesBothCardsAndStartsWithRecognition() async throws {
        let e = expression("break the ice")
        let (sut, repo) = make([e])
        try await sut.enroll(e.id, now: now)
        try await sut.enroll(e.id, now: now)                       // idempotent
        let cards = try await repo.all()
        #expect(cards.count == 2)
        #expect(Set(cards.map(\.direction)) == [.recognition, .recall])
        #expect(cards.allSatisfy { $0.state == .new })
        let queue = try await sut.queue(now: now)
        #expect(queue.map(\.card.direction) == [.recognition])
    }

    /// Recall comes once recognition was first answered on an EARLIER day — not the same day.
    @Test func recallFollowsRecognitionFromAnEarlierDay() async throws {
        let e = expression("a", ageDays: 3)
        var recognition = review(e, dueInDays: 2)
        recognition.firstReview = now.addingTimeInterval(-day)
        let recall = ReviewCard(expressionID: e.id, direction: .recall, due: now.addingTimeInterval(-2 * day))
        let (sut, _) = make([e], cards: [recognition, recall])
        #expect(try await sut.queue(now: now).map(\.card.direction) == [.recall])

        recognition.firstReview = now.addingTimeInterval(-60)
        let (sameDay, _) = make([e], cards: [recognition, recall])
        #expect(try await sameDay.queue(now: now).isEmpty)
    }

    // MARK: Proportions

    @Test func quotasAreProportionalToWhatIsWaiting() {
        // A fresh deck: everything new.
        #expect(SetComposer.quotas(size: 50, available: StageCounts(new: 9_887)) == StageCounts(new: 50))
        // A mix: new counts at most the set's size (50 of 9,000), the rest by their numbers.
        #expect(SetComposer.quotas(size: 50, available: StageCounts(new: 9_000, learning: 5, young: 60, mature: 40))
                == StageCounts(new: 16, learning: 2, young: 19, mature: 13))
        // A backlog: the bigger it is, the smaller the new share.
        #expect(SetComposer.quotas(size: 50, available: StageCounts(new: 9_000, young: 400))
                == StageCounts(new: 6, young: 44))
        // Fewer cards than the set: all of them.
        #expect(SetComposer.quotas(size: 50, available: StageCounts(new: 10, young: 5)) == StageCounts(new: 10, young: 5))
        #expect(SetComposer.quotas(size: 50, available: StageCounts()) == StageCounts())
        // Shares always add up to the set.
        for size in DailyGoalOptions.all {
            #expect(SetComposer.quotas(size: size, available: StageCounts(new: 333, learning: 7, young: 91, mature: 12)).total == size)
        }
    }

    // MARK: The day is one practice

    /// Start draws today's set; stopping and starting again continues the SAME set where it stopped;
    /// with the goal met, "more" adds a new goal-sized draw.
    @Test func theDayIsOnePracticeThatContinues() async throws {
        let phrases = (0..<40).map { expression("p\($0)") }
        let cards = phrases.flatMap { newCards($0, movedAt: now.addingTimeInterval(-day)) }
        let days = InMemoryPracticeDayStore()
        let (sut, _) = make(phrases, cards: cards, goal: 10, seed: 3, days: days)

        let first = try await sut.queue(now: now)
        #expect(first.count == 10)
        // Interrupted before answering anything: the same set, same order — even with another random draw.
        let (otherSeed, _) = make(phrases, cards: cards, goal: 10, seed: 99, days: days)
        #expect(try await otherSeed.queue(now: now).map(\.id) == first.map(\.id))

        // Four answered (Easy graduates them), then a pause: the other six, in the same order.
        for card in first.prefix(4) { _ = try await sut.rate(card.card, .easy, now: now) }
        let resumed = try await sut.queue(now: now.addingTimeInterval(3_600))
        #expect(resumed.map(\.id) == first.dropFirst(4).map(\.id))
        var plan = try await sut.stats(now: now).today
        #expect(plan.studied == 4 && plan.pending.total == 6 && !plan.goalReached)

        // The rest answered: the goal is met, nothing owed — "more" draws ten new cards.
        for card in resumed { _ = try await sut.rate(card.card, .easy, now: now) }
        #expect(try await sut.queue(now: now).isEmpty)
        plan = try await sut.stats(now: now).today
        #expect(plan.goalReached && plan.pending.total == 0 && plan.hasMore)
        let more = try await sut.queue(now: now, extra: true)
        #expect(more.count == 10)
        #expect(Set(more.map(\.id)).isDisjoint(with: first.map(\.id)))

        // A new day: a new set.
        let tomorrow = now.addingTimeInterval(day)
        #expect(try await sut.queue(now: tomorrow).map(\.id) != more.map(\.id))
    }

    /// Raising the goal during the day tops today's set up.
    @Test func raisingTheGoalTopsTheDayUp() async throws {
        let phrases = (0..<40).map { expression("p\($0)") }
        let cards = phrases.flatMap { newCards($0, movedAt: now.addingTimeInterval(-day)) }
        let days = InMemoryPracticeDayStore()
        let (small, _) = make(phrases, cards: cards, goal: 10, days: days)
        let first = try await small.queue(now: now)
        let (bigger, _) = make(phrases, cards: cards, goal: 25, days: days)
        let topped = try await bigger.queue(now: now)
        #expect(topped.count == 25)
        #expect(Array(topped.prefix(10)).map(\.id) == first.map(\.id))     // the day's set first
    }

    /// A card answered three times today is done for the day — restarting the practice can't bring
    /// it back, and it isn't drawn again.
    @Test func threeAnswersADayPerCard() async throws {
        let hard = expression("hard"), easy = expression("easy")
        let cards = newCards(hard, movedAt: now.addingTimeInterval(-day)) + newCards(easy, movedAt: now.addingTimeInterval(-day))
        let (sut, _) = make([hard, easy], cards: cards, goal: 2)
        let set = try await sut.queue(now: now)
        var card = try #require(set.first { $0.expression.id == hard.id }).card
        for minute in 0..<PracticeDay.maxAnswersPerCard {
            card = try await sut.rate(card, .again, now: now.addingTimeInterval(Double(minute) * 60))
        }
        #expect(card.state == .learning)                                     // still not learned…
        let later = try await sut.queue(now: now.addingTimeInterval(600))
        #expect(!later.contains { $0.expression.id == hard.id })            // …but done for today
        #expect(try await sut.queue(now: now.addingTimeInterval(600), extra: true)
                    .allSatisfy { $0.expression.id != hard.id })
        #expect(try await sut.answersToday(now: now)[card.id] == PracticeDay.maxAnswersPerCard)
        // Tomorrow it's back.
        #expect(try await sut.queue(now: now.addingTimeInterval(day)).contains { $0.id == card.id })
    }

    // MARK: Randomness

    @Test func setsAreRandomButReproducible() async throws {
        let phrases = (0..<40).map { expression("p\($0)") }
        let cards = phrases.flatMap { newCards($0, movedAt: now.addingTimeInterval(-day)) }
        func ids(_ seed: UInt64) async throws -> [UUID] {
            try await make(phrases, cards: cards, goal: 10, seed: seed).0.queue(now: now).map(\.id)
        }
        #expect(try await ids(7) == ids(7))
        #expect(try await ids(7) != ids(8))
        // Different draws cover different cards — no fixed first ten.
        var seen = Set<UUID>()
        for seed in UInt64(1)...20 { seen.formUnion(try await ids(seed)) }
        #expect(seen.count > 30)
    }

    /// Overdue cards are likelier, so none is postponed forever; a card due today still gets picked.
    @Test func overdueCardsAreLikelier() async throws {
        let late = expression("late"), onTime = expression("on time")
        let cards = [review(late, dueInDays: -30), review(onTime, dueInDays: 0)]
        var lateFirst = 0
        for seed in UInt64(1)...200 {
            let picked = try await make([late, onTime], cards: cards, goal: 1, seed: seed).0.queue(now: now)
            if picked.first?.expression.id == late.id { lateFirst += 1 }
        }
        #expect(lateFirst > 150 && lateFirst < 200)
    }

    /// Both directions of one expression aren't put in one set while other cards can fill it.
    @Test func oneDirectionPerExpressionPerSet() async throws {
        let both = expression("both"), other = expression("other")
        let cards = [review(both, .recognition, dueInDays: -1), review(both, .recall, dueInDays: -1),
                     review(other, dueInDays: -1)]
        for seed in UInt64(1)...30 {
            let set = try await make([both, other], cards: cards, goal: 2, seed: seed).0.queue(now: now)
            #expect(Set(set.map(\.expression.id)) == [both.id, other.id])
        }
        // …but when nothing else is waiting, the sibling still comes.
        let alone = try await make([both], cards: Array(cards.prefix(2)), goal: 2).0.queue(now: now)
        #expect(alone.count == 2)
    }

    // MARK: Answers and numbers

    @Test func answeringStoresTheCardAndLogsIt() async throws {
        let e = expression("a")
        let (sut, repo) = make([e])
        try await sut.enroll(e.id, now: now)
        let card = try #require(try await sut.queue(now: now).first).card
        let answered = try await sut.rate(card, .good, now: now)
        #expect(answered.state == .learning)
        #expect(try await repo.all().first { $0.id == card.id } == answered)
        let logs = try await repo.logs(since: now.addingTimeInterval(-60))
        #expect(logs.map(\.rating) == [.good])
        #expect(logs.first?.state == .new)
        // Still waiting today — it's mid-steps.
        #expect(try await sut.queue(now: now.addingTimeInterval(60)).map(\.card.id) == [card.id])
        #expect(sut.previews(for: answered, now: now)[.again] == 60)
    }

    /// The dashboard: the day against the goal, phrases in study vs caught, cards by stage (young vs
    /// mature at 21 days), answers per day for the last week.
    @Test func statsForTheDashboard() async throws {
        let studied = expression("studied", ageDays: 40), caught = expression("caught")
        let cards = [review(studied, .recognition, dueInDays: 30, interval: 31),
                     review(studied, .recall, dueInDays: -0.001, interval: 4)]
        let logs = [
            ReviewLog(cardID: cards[0].id, rating: .good, state: .review, reviewedAt: now.addingTimeInterval(-60)),
            ReviewLog(cardID: cards[1].id, rating: .again, state: .review, reviewedAt: now.addingTimeInterval(-120)),
            ReviewLog(cardID: cards[1].id, rating: .good, state: .review, reviewedAt: now.addingTimeInterval(-2 * day)),
            ReviewLog(cardID: cards[1].id, rating: .good, state: .review, reviewedAt: now.addingTimeInterval(-30 * day)),
        ]
        let (sut, _) = make([studied, caught], cards: cards, logs: logs, goal: 25)
        let stats = try await sut.stats(now: now)
        #expect(stats.today.goal == 25)
        #expect(stats.today.available == StageCounts(young: 1))
        #expect(stats.today.nextSet == StageCounts(young: 1))
        #expect(stats.today.due == 1)
        #expect(stats.inStudy == 1)
        #expect(stats.caught == 1)
        #expect(stats.distribution == CardDistribution(new: 0, learning: 0, young: 1, mature: 1))
        #expect(stats.reviewsByDay.map(\.count) == [0, 0, 0, 0, 1, 0, 2])   // the 30-day-old answer is out
        #expect(stats.reviewsByDay.last?.day == calendar.startOfDay(for: now))
    }

    @Test func deletingAnExpressionDeletesItsCards() async throws {
        let e = expression("a")
        let expressions = MockExpressionRepository(seed: [e])
        let cards = MockReviewCardRepository(seed: newCards(e, movedAt: now)
            + [ReviewCard(expressionID: UUID(), direction: .recognition, due: now)])
        try await StudyListInteractor(repository: expressions, cards: cards).delete(id: e.id)
        #expect(try await cards.all().count == 1)
    }
}
