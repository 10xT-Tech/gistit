//
//  ScreenshotDeck.swift
//  EnglishHelper — App
//
//  DEBUG only: a believable French deck for the App Store screenshots (`-screenshotDeck` with
//  `-uiTestStubs`) — phrases in Caught, the rest in flashcards at every stage (new, learning, young,
//  mature), a week of reviews and today's practice under way. Studied French, native English.
//

#if DEBUG
import Foundation
import Domain

enum ScreenshotDeck {
    struct Phrase {
        let fr: String, en: String, example: String, synonyms: [String], note: String
    }

    // swiftlint:disable line_length
    static let phrases: [Phrase] = [
        Phrase(fr: "ça ne casse pas trois pattes à un canard", en: "it's nothing special", example: "le film ? ça ne casse pas trois pattes à un canard.", synonyms: ["rien d'extraordinaire", "bof"], note: "Casual and humorous; about a film, a meal or an idea that leaves you unimpressed."),
        Phrase(fr: "pas terrible", en: "not great, meh", example: "le resto d'hier soir était pas terrible.", synonyms: ["bof", "moyen", "pas génial"], note: "A false friend: it never means \"not terrible\" — it's a polite way to say something was poor."),
        Phrase(fr: "avoir la flemme", en: "to not be bothered", example: "j'ai la flemme de sortir ce soir.", synonyms: ["ne pas avoir envie", "être paresseux"], note: "Very common and casual; with friends, not with your boss."),
        Phrase(fr: "poser un lapin", en: "to stand someone up", example: "il m'a posé un lapin samedi.", synonyms: ["faire faux bond"], note: "Used when someone doesn't show up to a date or a meeting."),
        Phrase(fr: "coûter les yeux de la tête", en: "to cost an arm and a leg", example: "ce sac coûte les yeux de la tête.", synonyms: ["coûter une fortune", "hors de prix"], note: "Neutral to casual; about anything far too expensive."),
        Phrase(fr: "tomber dans les pommes", en: "to faint", example: "elle est tombée dans les pommes à cause de la chaleur.", synonyms: ["s'évanouir", "perdre connaissance"], note: "Everyday, slightly playful; \"s'évanouir\" is the neutral word."),
        Phrase(fr: "en avoir marre", en: "to be fed up", example: "j'en ai marre de ce temps.", synonyms: ["en avoir assez", "en avoir ras le bol"], note: "Casual; very frequent in speech."),
        Phrase(fr: "faire la grasse matinée", en: "to sleep in", example: "dimanche, je fais la grasse matinée.", synonyms: ["dormir tard"], note: "Neutral; often shortened to \"faire la grasse mat'\"."),
        Phrase(fr: "un coup de main", en: "a hand, some help", example: "tu peux me donner un coup de main ?", synonyms: ["de l'aide"], note: "Friendly, everyday; \"donner un coup de main\" = to help out."),
        Phrase(fr: "avoir le cafard", en: "to feel down", example: "j'ai un peu le cafard depuis la rentrée.", synonyms: ["déprimer", "avoir le moral à zéro"], note: "Casual; a mild, passing sadness."),
        Phrase(fr: "c'est la galère", en: "it's a nightmare, a hassle", example: "trouver un appart à Paris, c'est la galère.", synonyms: ["c'est compliqué", "c'est l'enfer"], note: "Casual; about anything difficult or exhausting."),
        Phrase(fr: "tirer les vers du nez", en: "to worm it out of someone", example: "j'ai dû lui tirer les vers du nez pour savoir.", synonyms: ["faire parler"], note: "Neutral to casual; getting information out of someone reluctant."),
        Phrase(fr: "boire un coup", en: "to grab a drink", example: "on va boire un coup après le boulot ?", synonyms: ["prendre un verre"], note: "Casual and friendly; an invitation."),
        Phrase(fr: "mettre les pieds dans le plat", en: "to put your foot in it", example: "il a mis les pieds dans le plat en parlant du divorce.", synonyms: ["faire une gaffe"], note: "Bringing up an awkward subject bluntly."),
        Phrase(fr: "être dans la lune", en: "to be daydreaming", example: "désolé, j'étais dans la lune.", synonyms: ["rêvasser", "être distrait"], note: "Gentle and neutral."),
        Phrase(fr: "avoir un poil dans la main", en: "to be bone idle", example: "lui, il a un poil dans la main.", synonyms: ["être fainéant"], note: "Humorous and a little mocking."),
        Phrase(fr: "à la bonne franquette", en: "casually, no fuss", example: "on dîne à la bonne franquette.", synonyms: ["simplement", "sans façon"], note: "Warm and relaxed; about meals with friends."),
        Phrase(fr: "chercher la petite bête", en: "to nitpick", example: "arrête de chercher la petite bête.", synonyms: ["pinailler", "chipoter"], note: "Casual; a bit reproachful."),
        Phrase(fr: "se casser la tête", en: "to rack your brains", example: "ne te casse pas la tête, c'est simple.", synonyms: ["se creuser la tête"], note: "Casual; often in the negative: don't overthink it."),
        Phrase(fr: "au pif", en: "at a guess, roughly", example: "j'ai mis le sel au pif.", synonyms: ["à vue de nez", "approximativement"], note: "Casual; \"le pif\" is slang for the nose."),
        Phrase(fr: "un truc de ouf", en: "something crazy", example: "ce concert, c'était un truc de ouf !", synonyms: ["incroyable", "dingue"], note: "Slang (\"ouf\" = \"fou\" backwards); young and very casual."),
        Phrase(fr: "laisser tomber", en: "to drop it, to give up", example: "laisse tomber, ce n'est pas grave.", synonyms: ["abandonner", "oublier"], note: "Everyday; \"laisse tomber\" also means \"never mind\"."),
        Phrase(fr: "il pleut des cordes", en: "it's pouring", example: "prends un parapluie, il pleut des cordes.", synonyms: ["il pleut à verse"], note: "Neutral, very common."),
        Phrase(fr: "avoir du pain sur la planche", en: "to have a lot on your plate", example: "cette semaine, j'ai du pain sur la planche.", synonyms: ["être débordé"], note: "Neutral; lots of work ahead."),
        Phrase(fr: "faire la queue", en: "to queue", example: "on a fait la queue pendant une heure.", synonyms: ["attendre son tour"], note: "Neutral, everyday."),
        Phrase(fr: "c'est pas la mer à boire", en: "it's not the end of the world", example: "un peu de ménage, c'est pas la mer à boire.", synonyms: ["ce n'est pas si difficile"], note: "Reassuring; says a task is easier than it looks."),
        Phrase(fr: "être à l'ouest", en: "to be out of it", example: "je suis complètement à l'ouest ce matin.", synonyms: ["être dans les vapes"], note: "Casual; tired or confused."),
        Phrase(fr: "faire un tabac", en: "to be a big hit", example: "sa chanson a fait un tabac.", synonyms: ["cartonner", "avoir du succès"], note: "Neutral; about a show, a song, a product."),
        Phrase(fr: "rouler quelqu'un", en: "to rip someone off", example: "le vendeur m'a roulé.", synonyms: ["arnaquer", "avoir"], note: "Casual; being tricked or overcharged."),
        Phrase(fr: "prendre un râteau", en: "to get turned down", example: "il a pris un râteau à la soirée.", synonyms: ["se faire recaler"], note: "Slang; rejected when flirting."),
        Phrase(fr: "ça me saoule", en: "it's doing my head in", example: "ce bruit, ça me saoule.", synonyms: ["ça m'énerve", "ça me gonfle"], note: "Casual; annoyance, not drinking."),
        Phrase(fr: "un pot de départ", en: "a leaving do", example: "il y a un pot de départ vendredi.", synonyms: ["une fête d'adieu"], note: "Office culture: drinks when a colleague leaves."),
        Phrase(fr: "avoir la pêche", en: "to be full of beans", example: "aujourd'hui, j'ai la pêche !", synonyms: ["avoir la forme"], note: "Casual and cheerful."),
        Phrase(fr: "être crevé", en: "to be exhausted", example: "je suis crevé après cette journée.", synonyms: ["être épuisé", "être claqué"], note: "Casual; very common."),
        Phrase(fr: "filer à l'anglaise", en: "to slip away unnoticed", example: "il a filé à l'anglaise avant le dessert.", synonyms: ["s'éclipser"], note: "Neutral and a little humorous."),
        Phrase(fr: "raconter des salades", en: "to tell tall stories", example: "arrête de me raconter des salades.", synonyms: ["mentir", "raconter des histoires"], note: "Casual; gently accusing someone of lying."),
        Phrase(fr: "avoir le coup de foudre", en: "to fall in love at first sight", example: "ils ont eu le coup de foudre à Lyon.", synonyms: ["tomber amoureux"], note: "Neutral; also for places and things."),
        Phrase(fr: "se faire avoir", en: "to be had", example: "je me suis fait avoir avec ce forfait.", synonyms: ["se faire rouler"], note: "Casual; tricked or overcharged."),
        Phrase(fr: "à tout à l'heure", en: "see you later", example: "à tout à l'heure, au café !", synonyms: ["à plus tard", "à plus"], note: "Neutral; later the same day."),
        Phrase(fr: "être aux anges", en: "to be over the moon", example: "elle est aux anges depuis la nouvelle.", synonyms: ["être ravi"], note: "Neutral; delighted."),
        Phrase(fr: "donner sa langue au chat", en: "to give up guessing", example: "je donne ma langue au chat, c'est qui ?", synonyms: ["abandonner"], note: "Playful; when you can't find the answer."),
        Phrase(fr: "avoir les dents longues", en: "to be very ambitious", example: "le nouveau stagiaire a les dents longues.", synonyms: ["être ambitieux"], note: "Neutral, sometimes slightly critical."),
        Phrase(fr: "c'est du gâteau", en: "it's a piece of cake", example: "l'examen ? c'était du gâteau.", synonyms: ["c'est facile", "c'est simple comme bonjour"], note: "Casual; very easy."),
        Phrase(fr: "ne pas y aller par quatre chemins", en: "to not beat about the bush", example: "elle n'y est pas allée par quatre chemins.", synonyms: ["aller droit au but"], note: "Neutral; speaking frankly."),
        // Caught — not in flashcards yet.
        Phrase(fr: "faire le pont", en: "to take a long weekend", example: "jeudi férié, on fait le pont vendredi.", synonyms: ["prendre un jour de congé"], note: "A French classic: the day off that bridges a holiday and the weekend."),
        Phrase(fr: "avoir un trou de mémoire", en: "to have a mental blank", example: "désolé, j'ai un trou de mémoire.", synonyms: ["oublier"], note: "Neutral; a sudden blank."),
        Phrase(fr: "bosser", en: "to work", example: "je bosse demain matin.", synonyms: ["travailler"], note: "Casual everyday slang for working."),
        Phrase(fr: "avoir le seum", en: "to be gutted", example: "j'ai le seum, on a perdu le match.", synonyms: ["être dégoûté", "être frustré"], note: "Youth slang from Arabic; disappointment and frustration."),
        Phrase(fr: "être sur son trente-et-un", en: "to be dressed to the nines", example: "pour le mariage, il était sur son trente-et-un.", synonyms: ["être bien habillé", "être tiré à quatre épingles"], note: "Neutral and a little humorous; dressed up for an occasion."),
    ]
    // swiftlint:enable line_length

    /// Expressions (oldest first), their cards and a week of answers, as of `now`.
    static func make(now: Date = Date()) -> (expressions: [Domain.Expression], cards: [ReviewCard], logs: [ReviewLog]) {
        let day: TimeInterval = 86_400
        let caughtCount = 5
        var expressions: [Domain.Expression] = []
        var cards: [ReviewCard] = []
        for (index, phrase) in phrases.enumerated() {
            let enrolled = index < phrases.count - caughtCount
            // Lists show the newest first: the well-known phrases are the latest moved in, Caught the latest of all.
            let created = enrolled ? now.addingTimeInterval(-Double(index + 10) * day)
                                   : now.addingTimeInterval(-Double(phrases.count - index) * 3600)
            let expression = Domain.Expression(en: phrase.fr, ru: phrase.en, example: phrase.example,
                                               synonyms: phrase.synonyms, context: phrase.note, createdAt: created)
            expressions.append(expression)
            guard enrolled else { continue }
            for direction in CardDirection.allCases {
                cards.append(card(for: expression.id, direction: direction, index: index, now: now))
            }
        }
        // A week of answers: today's 23 on distinct cards of the young and mature ones.
        let perDay = [31, 44, 0, 52, 38, 47, 23]
        var logs: [ReviewLog] = []
        let answered = cards.filter { $0.state == .review }
        for (offset, count) in perDay.enumerated() {
            let date = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(perDay.count - 1 - offset) * day + 9 * 3600)
            for n in 0..<count {
                let card = answered[n % answered.count]
                logs.append(ReviewLog(cardID: card.id, rating: n % 7 == 0 ? .hard : .good, state: .review,
                                      reviewedAt: min(date.addingTimeInterval(Double(n) * 60), now.addingTimeInterval(-60))))
            }
        }
        return (expressions, cards, logs)
    }

    /// Stages by position: mature (18 phrases), young (12, a few due today), learning (2), new (the rest).
    private static func card(for expressionID: UUID, direction: CardDirection, index: Int, now: Date) -> ReviewCard {
        let day: TimeInterval = 86_400
        switch index {
        case 0..<18:
            let interval = Double(24 + (index * 7) % 40)
            let last = now.addingTimeInterval(-Double(3 + index % 9) * day)
            return ReviewCard(expressionID: expressionID, direction: direction, state: .review,
                              due: last.addingTimeInterval(interval * day), stability: interval, difficulty: 4.5,
                              reps: 6 + index % 5, lastReview: last, firstReview: now.addingTimeInterval(-60 * day))
        case 18..<30:
            let interval = Double(2 + index % 12)
            let dueToday = index % 2 == 0
            let last = dueToday ? now.addingTimeInterval(-interval * day - 3600) : now.addingTimeInterval(-day)
            return ReviewCard(expressionID: expressionID, direction: direction, state: .review,
                              due: last.addingTimeInterval(interval * day), stability: interval, difficulty: 5.5,
                              reps: 3 + index % 3, lastReview: last, firstReview: now.addingTimeInterval(-20 * day))
        case 30..<32:
            return ReviewCard(expressionID: expressionID, direction: direction, state: .learning,
                              due: now.addingTimeInterval(300), stability: 0.5, difficulty: 6, step: 1, reps: 1,
                              lastReview: now.addingTimeInterval(-600), firstReview: now.addingTimeInterval(-600))
        default:
            return ReviewCard(expressionID: expressionID, direction: direction, due: now.addingTimeInterval(-day))
        }
    }
}
#endif
