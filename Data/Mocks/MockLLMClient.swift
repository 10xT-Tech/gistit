//
//  MockLLMClient.swift
//  EnglishHelper — Data (mock adapter)
//
//  Boots the app without the network. Returns canned JSON per template and decodes it through
//  the template's OWN decoder, so mocks exercise the real schema/contract path.
//

import Foundation
import Domain

public final class MockLLMClient: LLMClient {
    public init() {}

    public func run<Template: PromptTemplate>(
        _ template: Template,
        input: Template.Input
    ) async throws -> Template.Output {
        try template.decode(Self.cannedJSON(for: template, input: input))
    }

    /// Canned output — computed from the input where a fixed answer can't fit (`fixCards` answers
    /// card by card, `dedupeCards` group by group, by id).
    static func cannedJSON<Template: PromptTemplate>(for template: Template, input: Template.Input) -> String {
        if let cards = input as? [FixCardItem] {
            // Echo every card, filling what's missing — the way the real model completes a card.
            let fixed = cards.map { card in
                FixCardItem(id: card.id, expression: card.expression, translation: card.translation,
                            example: card.example.isEmpty ? "An example with \(card.expression)." : card.example,
                            synonyms: card.synonyms.isEmpty ? ["similar"] : card.synonyms,
                            context: card.context.isEmpty ? "Нейтрально." : card.context)
            }
            let data = (try? JSONEncoder().encode(FixCardsResult(cards: fixed))) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        if let groups = input as? [DuplicateGroupItem] {
            // Per group: cards with the same translation are a duplicate; the rest written exactly alike
            // are one expression's senses; anything else stays apart.
            let verdicts = groups.map { group -> DuplicateVerdict in
                var left = group.cards
                var merges: [DuplicateMergeAnswer] = []
                func merge(_ cards: [FixCardItem], _ verdict: DuplicateKind) {
                    guard cards.count > 1, let first = cards.first else { return }
                    let numbered = cards.enumerated().map { "\($0.offset + 1)) \($0.element.translation)" }
                    let synonyms = Array(Set(cards.flatMap(\.synonyms)).sorted().prefix(4))
                    merges.append(DuplicateMergeAnswer(ids: cards.map(\.id), verdict: verdict, card: CardText(
                        expression: first.expression,
                        translation: verdict == .duplicate ? first.translation : numbered.joined(separator: " "),
                        example: cards.first { !$0.example.isEmpty }?.example ?? "An example with \(first.expression).",
                        synonyms: synonyms.isEmpty ? ["similar"] : synonyms,
                        context: cards.first { !$0.context.isEmpty }?.context ?? "Нейтрально.")))
                    left.removeAll { card in cards.contains { $0.id == card.id } }
                }
                for translation in group.cards.map({ $0.translation.lowercased() }) {
                    merge(left.filter { $0.translation.lowercased() == translation }, .duplicate)
                }
                for expression in left.map({ $0.expression.lowercased() }) {
                    merge(left.filter { $0.expression.lowercased() == expression }, .senses)
                }
                return DuplicateVerdict(id: group.id, merges: merges)
            }
            let data = (try? JSONEncoder().encode(DuplicatesResult(groups: verdicts))) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        return cannedJSON(for: template.id)
    }

    static func cannedJSON(for templateID: String) -> String {
        switch templateID {
        case "howToSay":
            return """
            {"variants":[
              {"en":"Could you help me with this?","register":"formal","context_ru":"Вежливо — для коллег и незнакомых."},
              {"en":"Can you give me a hand?","register":"casual","context_ru":"Нейтрально — для друзей и быта."},
              {"en":"Gimme a hand, will ya?","register":"slang","context_ru":"Сленг, очень неформально."}
            ]}
            """
        case "whatToSay":
            return """
            {"variants":[
              {"en":"I have an appointment with Dr. Smith at 3 p.m.","register":"casual","context_ru":"На стойке регистрации."},
              {"en":"Could you tell me where the waiting room is?","register":"casual","context_ru":"Чтобы сориентироваться."},
              {"en":"I'd like to describe my symptoms.","register":"casual","context_ru":"В кабинете у врача."},
              {"en":"Do I need a follow-up visit?","register":"casual","context_ru":"В конце приёма."}
            ]}
            """
        case "understand":
            return #"{"studied":"bank","variants":[{"text":"банк","context":"финансовое учреждение"},{"text":"берег","context":"берег реки"}]}"#
        case "explainExpression":
            return """
            {"studied":"give me a hand",
             "meaning":"Просьба помочь с чем-то конкретным.",
             "register":"Нейтрально-вежливый тон, уместен почти везде.",
             "context":"Так обычно просят о небольшой помощи у коллег или знакомых.",
             "analogy":"По-русски это как сказать «выручи меня» — лёгкая дружелюбная просьба."}
            """
        case "photoBlocks":
            return """
            {"blocks":[
              {"en":"Mind the gap","ru":"Осторожно, зазор между поездом и платформой"},
              {"en":"Please stand clear of the closing doors","ru":"Пожалуйста, отойдите от закрывающихся дверей"}
            ]}
            """
        case "photoExplain":
            return #"{"title":"Колизей","details":"Древнеримский амфитеатр в центре Рима, построен в I веке н. э. Здесь проходили гладиаторские бои. Сегодня это один из главных символов Италии и объект Всемирного наследия ЮНЕСКО."}"#
        case "healthCheck":
            return #"{"ok":true}"#
        case "photoCards":
            return """
            {"cards":[
              {"expression":"threshold","translation":"порог / граница",
               "example":"the system triggers an alert when the value exceeds the threshold.",
               "synonyms":["limit","boundary","cutoff"],"context":"нейтрально; о пределе значения."},
              {"expression":"discard","translation":"отбросить / отклонить",
               "example":"we decided to discard the old approach and start fresh.",
               "synonyms":["drop","reject","abandon"],"context":"нейтрально; об отказе от ненужного."}
            ]}
            """
        case "enrichCard":
            return """
            {"ru":"я ценю это","example":"Thanks for covering my shift — I really appreciate it.",
             "synonyms":["I'm grateful","thank you"]}
            """
        default:
            return "{}"
        }
    }
}
