//
//  BolusPro_SaveFailureAlertTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class BolusPro_SaveFailureAlertTests: XCTestCase {

    private final class RecordingIssuer: AlertIssuer {
        var issued: [LoopKit.Alert] = []
        func issueAlert(_ alert: LoopKit.Alert) { issued.append(alert) }
        func retractAlert(identifier: LoopKit.Alert.Identifier) {}
    }

    private let start = ISO8601DateFormatter().date(from: "2026-10-22T19:30:00Z")!

    private var secondaryEntry: NewCarbEntry {
        NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: 18), startDate: start, foodType: "🥩", absorptionTime: 4 * 3600)
    }

    func testAlertNamesTheGramsThatAreNotCovered() {
        let alert = BolusPro_SaveFailureAlert.alert(for: secondaryEntry)

        XCTAssertEqual(alert.identifier, BolusPro_SaveFailureAlert.identifier)
        XCTAssertTrue(alert.backgroundContent.body.contains("18 g"), alert.backgroundContent.body)
        XCTAssertEqual(alert.foregroundContent, alert.backgroundContent)
        XCTAssertEqual(alert.trigger, .immediate)
    }

    func testIssueSendsTheAlertToLoopsAlertSystem() {
        let issuer = RecordingIssuer()

        BolusPro_SaveFailureAlert.issue(for: secondaryEntry, issuer: issuer)

        XCTAssertEqual(issuer.issued.map(\.identifier), [BolusPro_SaveFailureAlert.identifier])
    }

    func testIssueWithoutAnIssuerDoesNotCrash() {
        BolusPro_SaveFailureAlert.issue(for: secondaryEntry, issuer: nil)
    }
}
