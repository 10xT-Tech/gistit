//
//  SettingsTests.swift
//  EnglishHelperTests
//
//  Settings: live health check ok/failed mapping + response-speed buckets, and persisted preferences.
//

import Testing
import Foundation
import SwiftUI
import Domain
import Adapters
import Presentation

@Suite @MainActor struct SettingsTests {

    @Test func healthOkOnMock() async {
        let vm = SettingsViewModel(
            connectionHealth: ConnectionHealthInteractor(llm: MockLLMClient()),
            transcriptionHealth: TranscriptionHealthInteractor(service: MockTranscriptionService()),
            cacheAdmin: TranslationCacheAdminInteractor(cache: nil),
            appVersion: "1.0"
        )
        await vm.check()
        // Every probe is green and timed; an in-process mock answers well inside the "fast" bucket.
        for health in [vm.translationHealth, vm.explanationHealth, vm.voiceHealth] {
            guard case .ok(let speed) = health else {
                Issue.record("expected .ok, got \(health)")
                continue
            }
            #expect(speed.level == .fast)
        }
    }

    /// Soniox failures surface independently: Claude can be green while Soniox reports its own error.
    @Test func sonioxFailureIsIndependentOfClaude() async {
        let vm = SettingsViewModel(
            connectionHealth: ConnectionHealthInteractor(llm: MockLLMClient()),
            transcriptionHealth: TranscriptionHealthInteractor(
                service: MockTranscriptionService(failure: .unauthorized)
            ),
            cacheAdmin: TranslationCacheAdminInteractor(cache: nil),
            appVersion: "1.0"
        )
        await vm.check()
        guard case .ok = vm.explanationHealth, case .ok = vm.translationHealth else {
            Issue.record("expected both Claude rows .ok")
            return
        }
        guard case .failed = vm.voiceHealth else {
            Issue.record("expected .failed voiceHealth, got \(vm.voiceHealth)")
            return
        }
    }

    /// No Soniox key → a "no key" failure (matching how a missing Claude key is shown), not a crash.
    @Test func sonioxNoKeyMapsToFailed() async {
        let health = await TranscriptionHealthInteractor(
            service: MockTranscriptionService(failure: .notConfigured)
        )()
        #expect(health == .failed(.noKey))
    }

    @Test func cacheStatsLoadAndClear() async {
        let cache = MockTranslationCache()
        await cache.setValue(Data([1]), forKey: "a")
        await cache.setValue(Data([2]), forKey: "b")
        _ = await cache.value(forKey: "a")   // one hit
        let vm = SettingsViewModel(
            connectionHealth: ConnectionHealthInteractor(llm: MockLLMClient()),
            transcriptionHealth: TranscriptionHealthInteractor(service: MockTranscriptionService()),
            cacheAdmin: TranslationCacheAdminInteractor(cache: cache),
            appVersion: "1.0"
        )
        await vm.loadCacheStats()
        #expect(vm.cacheStats.entryCount == 2)
        #expect(vm.cacheStats.hitCount == 1)

        await vm.clearCache()
        #expect(vm.cacheStats.entryCount == 0)   // emptied
        #expect(vm.cacheStats.hitCount == 0)     // hit counter reset
    }

    @Test func healthFailedWhenNotConfigured() async {
        let vm = SettingsViewModel(
            connectionHealth: ConnectionHealthInteractor(
                llm: StubLLMClient(behavior: .failure(.notConfigured), latency: .milliseconds(1))
            ),
            transcriptionHealth: TranscriptionHealthInteractor(service: MockTranscriptionService()),
            cacheAdmin: TranslationCacheAdminInteractor(cache: nil),
            appVersion: "1.0"
        )
        await vm.check()
        guard case .failed = vm.explanationHealth, case .failed = vm.translationHealth else {
            Issue.record("expected .failed Claude rows, got \(vm.explanationHealth) / \(vm.translationHealth)")
            return
        }
    }

    /// Speed buckets: Claude models are judged on a ~1.5 s ping, the voice service on a ~0.5 s one.
    @Test func responseSpeedBuckets() {
        #expect(ResponseSpeed.model(.milliseconds(1400)).level == .fast)
        #expect(ResponseSpeed.model(.milliseconds(2500)).level == .medium)
        #expect(ResponseSpeed.model(.milliseconds(4999)).level == .medium)
        #expect(ResponseSpeed.model(.seconds(5)).level == .slow)
        #expect(ResponseSpeed.voice(.milliseconds(500)).level == .fast)
        #expect(ResponseSpeed.voice(.milliseconds(1500)).level == .medium)
        #expect(ResponseSpeed.voice(.seconds(3)).level == .slow)
        #expect(ResponseSpeed.model(.milliseconds(1349)).secondsText == "1.3")
    }

    @Test func themePreferencePersists() {
        let key = "themePreference"
        UserDefaults.standard.removeObject(forKey: key)

        let store = ThemeStore()
        #expect(store.preference == .system)
        #expect(store.colorScheme == nil)

        store.preference = .dark
        let reloaded = ThemeStore()
        #expect(reloaded.preference == .dark)
        #expect(reloaded.colorScheme == .dark)

        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test func onboardingDefaultsIncompleteThenPersistsCompletion() {
        let key = "didCompleteOnboarding"
        UserDefaults.standard.removeObject(forKey: key)

        let store = OnboardingStore()
        #expect(store.isComplete == false)   // first launch → onboarding shown

        store.complete()
        #expect(store.isComplete)
        #expect(OnboardingStore().isComplete)   // persists across launches

        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test func nativeLanguageSupportsSixLanguages() {
        #expect(TargetLanguage.allCases.count == 6)
        #expect(TargetLanguage.french.promptName == "French")
        #expect(TargetLanguage.spanish.promptName == "Spanish")
        #expect(TargetLanguage.german.promptName == "German")
        #expect(TargetLanguage.italian.promptName == "Italian")
        #expect(TargetLanguage.french.speechLocale == "fr-FR")
        #expect(TargetLanguage.spanish.speechLocale == "es-ES")
        #expect(TargetLanguage.german.speechLocale == "de-DE")
        #expect(TargetLanguage.italian.speechLocale == "it-IT")
        #expect(Set(TargetLanguage.allCases.map(\.abbreviation)) == ["RU", "EN", "FR", "ES", "DE", "IT"])
    }

    @Test func studiedLanguageSupportsSixLanguagesDefaultEnglish() {
        let key = "studiedLanguage"
        UserDefaults.standard.removeObject(forKey: key)
        #expect(StudiedLanguage.current == .english)   // default is English
        #expect(StudiedLanguage.allCases.count == 6)
        #expect(StudiedLanguage.french.promptName == "French")
        #expect(StudiedLanguage.german.promptName == "German")
        #expect(StudiedLanguage.italian.promptName == "Italian")
        #expect(StudiedLanguage.german.speechLocale == "de-DE")
        #expect(StudiedLanguage.italian.speechLocale == "it-IT")
        #expect(Set(StudiedLanguage.allCases.map(\.abbreviation)) == ["RU", "EN", "FR", "ES", "DE", "IT"])

        let store = StudiedLanguageStore()
        store.language = .spanish
        #expect(StudiedLanguage.current == .spanish)   // persists
        UserDefaults.standard.removeObject(forKey: key)
    }
}
