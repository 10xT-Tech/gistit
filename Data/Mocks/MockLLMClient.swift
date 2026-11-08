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
        try template.decode(Self.cannedJSON(for: template.id))
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
               "synonyms":["limit","boundary","cutoff"]},
              {"expression":"discard","translation":"отбросить / отклонить",
               "example":"we decided to discard the old approach and start fresh.",
               "synonyms":["drop","reject","abandon"]}
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
