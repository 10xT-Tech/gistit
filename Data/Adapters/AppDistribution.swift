//
//  AppDistribution.swift
//  EnglishHelper — Data (build channel)
//
//  How THIS copy of the app reached the device — the `environment` that crash reports (Sentry) and
//  product analytics (Amplitude) are split by, so TestFlight and Xcode runs never mix into the
//  public numbers. Resolved synchronously at launch (both SDKs need it before their first event):
//
//  - local      — installed straight from Xcode: any DEBUG build, the Simulator, or a Release build
//                 that still carries `embedded.mobileprovision` (development / ad-hoc signing —
//                 App Store Connect strips the profile from TestFlight and App Store binaries).
//  - testflight — App Store-signed, but StoreKit's receipt is the sandbox one.
//  - production — App Store install (the public version).
//

import Foundation

public enum AppDistribution: String, Sendable, CaseIterable {
    case production
    case testflight
    case local

    /// The channel of the running process. Cheap (two file-system checks), computed once.
    public static let current: AppDistribution = {
        #if DEBUG || targetEnvironment(simulator)
        return .local
        #else
        return resolve(
            hasProvisioningProfile: Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil,
            receiptFileName: (Bundle.main as any ReceiptLocating).appStoreReceiptURL?.lastPathComponent
        )
        #endif
    }()

    /// Pure decision table (unit-tested) for a Release build on a device.
    static func resolve(hasProvisioningProfile: Bool, receiptFileName: String?) -> AppDistribution {
        if hasProvisioningProfile { return .local }
        if receiptFileName == "sandboxReceipt" { return .testflight }
        return .production
    }

    /// `CFBundleShortVersionString`, e.g. "1.4.3".
    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// `CFBundleVersion` — the build number, unique per App Store Connect upload.
    public static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}

/// `Bundle.appStoreReceiptURL` is deprecated (iOS 18) in favor of the async `AppTransaction`, but it's
/// the only SYNCHRONOUS signal, and the receipt name is still "sandboxReceipt" under TestFlight. Reading
/// it through this protocol requirement keeps that deliberate use from raising a deprecation warning.
private protocol ReceiptLocating {
    var appStoreReceiptURL: URL? { get }
}

extension Bundle: ReceiptLocating {}
