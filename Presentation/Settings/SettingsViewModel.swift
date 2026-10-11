//
//  SettingsViewModel.swift
//  EnglishHelper — Presentation
//

import Foundation
import Domain

@MainActor
@Observable
public final class SettingsViewModel {
    public enum Health: Equatable { case checking, ok(ResponseSpeed), failed(String) }

    /// Translation model (fast tier — Haiku): Get it / See it → Translate.
    public private(set) var translationHealth: Health = .checking
    /// Explanation model (standard tier — Sonnet): explanations and Say it.
    public private(set) var explanationHealth: Health = .checking
    /// Voice model (Soniox speech-to-text — online translation).
    public private(set) var voiceHealth: Health = .checking
    public let appVersion: String
    /// Translation-cache usage shown in Settings (entries stored + times served from cache).
    public private(set) var cacheStats = TranslationCacheStats(entryCount: 0, hitCount: 0)
    /// Disk usage of the app's stored data (cache / history / session audio) shown in Settings.
    public private(set) var storage = StorageUsage.zero

    private let connectionHealth: any ConnectionHealthUseCase
    private let transcriptionHealth: any TranscriptionHealthUseCase
    private let cacheAdmin: any TranslationCacheAdminUseCase
    private let storageUsage: any StorageUsageUseCase

    public init(
        connectionHealth: any ConnectionHealthUseCase,
        transcriptionHealth: any TranscriptionHealthUseCase,
        cacheAdmin: any TranslationCacheAdminUseCase,
        storageUsage: any StorageUsageUseCase = StorageUsageInteractor(reader: nil),
        appVersion: String
    ) {
        self.connectionHealth = connectionHealth
        self.transcriptionHealth = transcriptionHealth
        self.cacheAdmin = cacheAdmin
        self.storageUsage = storageUsage
        self.appVersion = appVersion
    }

    public func loadCacheStats() async { cacheStats = await cacheAdmin.stats() }

    public func loadStorage() async { storage = await storageUsage() }

    public func clearCache() async {
        await cacheAdmin.clear()
        cacheStats = await cacheAdmin.stats()
        storage = await storageUsage()   // the disk-usage card shows cache bytes — keep it in sync
    }

    /// Probe both Claude models AND Soniox concurrently; surface each status independently. Each
    /// probe is timed — its round-trip is the response-speed indicator shown next to the status.
    public func check() async {
        let prevTranslation = translationHealth, prevExplanation = explanationHealth, prevVoice = voiceHealth
        translationHealth = .checking
        explanationHealth = .checking
        voiceHealth = .checking
        let connectionHealth = connectionHealth, transcriptionHealth = transcriptionHealth
        async let translation = Self.timed { await connectionHealth(.fast) }
        async let explanation = Self.timed { await connectionHealth(.standard) }
        async let voice = Self.timed { await transcriptionHealth() }
        let (t, e, v) = await (translation, explanation, voice)
        translationHealth = Self.resolve(t.result, speed: .model(t.latency), previous: prevTranslation, service: "Claude")
        explanationHealth = Self.resolve(e.result, speed: .model(e.latency), previous: prevExplanation, service: "Claude")
        voiceHealth = Self.resolve(v.result, speed: .voice(v.latency), previous: prevVoice, service: "Soniox")
    }

    private nonisolated static func timed(
        _ probe: @Sendable () async -> ConnectionHealth
    ) async -> (result: ConnectionHealth, latency: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await probe()
        return (result, clock.now - start)
    }

    private static func resolve(_ result: ConnectionHealth, speed: ResponseSpeed, previous: Health,
                                service: String) -> Health {
        switch result {
        case .ok: .ok(speed)
        case .failed(let reason): .failed(message(for: reason, service: service))
        case .cancelled: previous   // check torn down — restore prior status, no false failure
        }
    }

    private static func message(for reason: ConnectionHealth.Reason, service: String) -> String {
        switch reason {
        case .noKey: Loc.t("Нет ключа \(service) API", "No \(service) API key")
        case .unauthorized: Loc.t("Сервис не принял ключ API", "The service rejected the API key")
        case .offline: Loc.t("Нет соединения", "No connection")
        case .timeout: Loc.t("Сервис не ответил вовремя", "The service didn't respond in time")
        case .overloaded: Loc.t("Сервис перегружен, попробуйте позже", "Service is overloaded — try later")
        case .badResponse: Loc.t("Неожиданный ответ сервиса", "Unexpected response from the service")
        case .unavailable: Loc.t("Сервис недоступен", "Service unavailable")
        case .unknown: Loc.t("Ошибка подключения", "Connection error")
        }
    }
}

/// How quickly a service answered its health probe, bucketed for the Settings speed indicator.
public struct ResponseSpeed: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case fast, medium, slow }

    public let latency: Duration
    public let level: Level

    public init(latency: Duration, fastBelow: Duration, slowFrom: Duration) {
        self.latency = latency
        level = latency < fastBelow ? .fast : latency < slowFrom ? .medium : .slow
    }

    /// Claude models. The tiny structured ping takes ~1.3–1.5 s straight to the API; our backend
    /// (and a first-time session open) adds a little on top.
    public static func model(_ latency: Duration) -> ResponseSpeed {
        ResponseSpeed(latency: latency, fastBelow: .milliseconds(2500), slowFrom: .seconds(5))
    }

    /// Soniox. Its probe is a plain HTTP round-trip (~0.5 s), so the bar is set lower.
    public static func voice(_ latency: Duration) -> ResponseSpeed {
        ResponseSpeed(latency: latency, fastBelow: .seconds(1), slowFrom: .milliseconds(2500))
    }

    /// Seconds with one decimal, e.g. "1.3".
    public var secondsText: String {
        let seconds = Double(latency.components.seconds) + Double(latency.components.attoseconds) / 1e18
        return String(format: "%.1f", seconds)
    }
}
