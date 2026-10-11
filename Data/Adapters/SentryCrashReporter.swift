//
//  SentryCrashReporter.swift
//  EnglishHelper — Data (crash & error reporting)
//
//  The ONLY place in the codebase that touches the Sentry SDK (enforced by ForbiddenImportTests
//  for Domain/Presentation). Crash reporting is process-wide infrastructure, not a feature, so
//  there is no Domain port: the entry point starts it once, as early as possible, and the SDK
//  catches crashes, app hangs and watchdog terminations on its own.
//
//  PRIVACY: no PII (`sendDefaultPii` off), and no screenshots / view hierarchy / session replay —
//  the screen is the user's own text, photos and translations.
//

import Foundation
import Sentry

public enum SentryCrashReporter {

    /// One-time SDK setup — call from the app entry point (`@main` init) BEFORE anything else can
    /// crash. The SDK is linked into this module only, so the composition root starts it through
    /// this wrapper rather than importing Sentry itself.
    public static func start(dsn: String) {
        SentrySDK.start { options in
            options.dsn = dsn
            // production (App Store) · testflight · local (Xcode) — see `AppDistribution`.
            options.environment = AppDistribution.current.rawValue
            // Same shape the SDK would derive itself, spelled out so it matches App Store Connect:
            // release "tech.10xt.englishhelper@1.4.3+1", dist = build number.
            let bundleID = Bundle.main.bundleIdentifier ?? "tech.10xt.englishhelper"
            options.releaseName = "\(bundleID)@\(AppDistribution.appVersion)+\(AppDistribution.buildNumber)"
            options.dist = AppDistribution.buildNumber
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.tracesSampleRate = 0.2           // light performance sampling (app start, hangs context)
        }
    }
}
