//
//  BolusPro_SaveFailureAlert.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  BolusPro — Tells the user when the delayed fat/protein carb entry
//  could not be saved after the primary entry and bolus went through.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import HealthKit
import LoopKit

/// Issued through Loop's AlertManager rather than the bolus screen's own alert,
/// because the bolus screen closes as soon as the bolus is sent and would take
/// a screen-level alert with it.
enum BolusPro_SaveFailureAlert {

    /// Set by `LoopAppManager` once its `AlertManager` exists.
    static weak var alertIssuer: AlertIssuer?

    static let identifier = Alert.Identifier(managerIdentifier: "Loop", alertIdentifier: "bolusProSecondaryEntrySaveFailed")

    /// Builds the alert for a delayed entry that failed to save.
    /// - Parameter entry: The BolusPro secondary carb entry that was not saved.
    /// - Returns: An immediate alert naming the uncovered grams and their start time.
    static func alert(for entry: NewCarbEntry) -> Alert {
        let grams = Int(entry.quantity.doubleValue(for: .gram()).rounded())
        let startTime = DateFormatter.localizedString(from: entry.startDate, dateStyle: .none, timeStyle: .short)
        let content = Alert.Content(
            title: "Delayed Carbs Not Saved",
            body: "Your carbs and bolus were saved. BolusPro's delayed fat and protein entry (\(grams) g, starting \(startTime)) was not saved, so Loop is not covering it. Add it in Carb Entry if you want it covered.",
            acknowledgeActionButtonLabel: "OK"
        )
        return Alert(identifier: identifier, foregroundContent: content, backgroundContent: content, trigger: .immediate)
    }

    /// Issues `alert(for:)` through `issuer`.
    /// - Parameters:
    ///   - entry: The BolusPro secondary carb entry that was not saved.
    ///   - issuer: Defaults to the AlertManager registered at launch.
    static func issue(for entry: NewCarbEntry, issuer: AlertIssuer? = alertIssuer) {
        issuer?.issueAlert(alert(for: entry))
    }
}
