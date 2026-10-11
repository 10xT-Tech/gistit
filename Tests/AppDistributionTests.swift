//
//  AppDistributionTests.swift
//  EnglishHelper — Tests
//
//  Pins the build-channel decision table that splits Sentry environments and Amplitude events into
//  production (App Store) / testflight / local (Xcode). A wrong answer here would leak TestFlight or
//  Xcode traffic into the public numbers.
//

import Testing
@testable import Adapters

@Suite struct AppDistributionTests {

    @Test func provisioningProfileMeansXcodeInstallWhateverTheReceipt() {
        #expect(AppDistribution.resolve(hasProvisioningProfile: true, receiptFileName: nil) == .local)
        #expect(AppDistribution.resolve(hasProvisioningProfile: true, receiptFileName: "sandboxReceipt") == .local)
        #expect(AppDistribution.resolve(hasProvisioningProfile: true, receiptFileName: "receipt") == .local)
    }

    @Test func sandboxReceiptWithoutProfileIsTestFlight() {
        #expect(AppDistribution.resolve(hasProvisioningProfile: false, receiptFileName: "sandboxReceipt") == .testflight)
    }

    @Test func storeReceiptOrNoneWithoutProfileIsProduction() {
        #expect(AppDistribution.resolve(hasProvisioningProfile: false, receiptFileName: "receipt") == .production)
        // A fresh App Store install may not have its receipt yet.
        #expect(AppDistribution.resolve(hasProvisioningProfile: false, receiptFileName: nil) == .production)
    }

    @Test func testRunsAreLocal() {
        // The test host is a DEBUG Simulator build.
        #expect(AppDistribution.current == .local)
        #expect(AppDistribution.allCases.map(\.rawValue) == ["production", "testflight", "local"])
    }
}
