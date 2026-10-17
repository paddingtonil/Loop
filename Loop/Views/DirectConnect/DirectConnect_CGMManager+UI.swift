//
//  DirectConnect_CGMManager+UI.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — CGMManagerUI conformance: setup, settings and status indicators.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Adapted from LoopKit G7SensorKitUI G7CGMManager+UI (MIT, © 2022 LoopKit Authors).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import LoopKit
import LoopKitUI
import UIKit

struct DirectConnect_StatusHighlight: DeviceStatusHighlight, Equatable {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}

struct DirectConnect_StatusBadge: DeviceStatusBadge {
    var image: UIImage?
    var state: DeviceStatusBadgeState
}

struct DirectConnect_LifecycleProgress: DeviceLifecycleProgress {
    var percentComplete: Double
    var progressState: DeviceLifecycleProgressState
}

extension DirectConnect_G7CGMManager: CGMManagerUI {
    static var onboardingImage: UIImage? { nil }

    static func setupViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool, prefersToSkipUserInteraction: Bool) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        // Choosing DirectConnect in the Add CGM list is the same as switching it on in Settings.
        DirectConnect_FeatureFlags.isEnabled = true
        return .userInteractionRequired(DirectConnect_UICoordinator(colorPalette: colorPalette, displayGlucosePreference: displayGlucosePreference))
    }

    func settingsViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> CGMManagerViewController {
        DirectConnect_UICoordinator(cgmManager: self, colorPalette: colorPalette, displayGlucosePreference: displayGlucosePreference)
    }

    var smallImage: UIImage? {
        DirectConnect_Branding.tintedIcon
    }

    var cgmStatusHighlight: DeviceStatusHighlight? {
        if state.pairingFailure != nil {
            return DirectConnect_StatusHighlight(localizedMessage: NSLocalizedString("Pairing\nProblem", comment: "DirectConnect highlight pairing problem"), imageName: "exclamationmark.circle.fill", state: .critical)
        }
        switch lifecycleState {
        case .notPaired, .searching:
            return DirectConnect_StatusHighlight(localizedMessage: NSLocalizedString("Searching for\nSensor", comment: "DirectConnect highlight searching"), imageName: "dot.radiowaves.left.and.right", state: .normalCGM)
        case .expired:
            return DirectConnect_StatusHighlight(localizedMessage: NSLocalizedString("Sensor\nExpired", comment: "DirectConnect highlight expired"), imageName: "clock", state: .normalCGM)
        case .failed:
            return DirectConnect_StatusHighlight(localizedMessage: NSLocalizedString("Sensor\nFailed", comment: "DirectConnect highlight failed"), imageName: "exclamationmark.circle.fill", state: .critical)
        default:
            break
        }
        if let last = state.latestReadingTimestamp, last.timeIntervalSinceNow < -.minutes(15) {
            return DirectConnect_StatusHighlight(localizedMessage: NSLocalizedString("Signal\nLoss", comment: "DirectConnect highlight signal loss"), imageName: "exclamationmark.circle.fill", state: .warning)
        }
        if state.latestReading?.algorithmState.hasTemporaryError == true {
            return DirectConnect_StatusHighlight(localizedMessage: NSLocalizedString("Sensor\nIssue", comment: "DirectConnect highlight sensor issue"), imageName: "exclamationmark.circle.fill", state: .warning)
        }
        if lifecycleState == .warmup {
            return DirectConnect_StatusHighlight(localizedMessage: NSLocalizedString("Sensor\nWarmup", comment: "DirectConnect highlight warmup"), imageName: "clock", state: .normalCGM)
        }
        return nil
    }

    var cgmStatusBadge: DeviceStatusBadge? {
        lifecycleState == .gracePeriod ? DirectConnect_StatusBadge(image: UIImage(systemName: "clock"), state: .critical) : nil
    }

    var cgmLifecycleProgress: DeviceLifecycleProgress? {
        switch lifecycleState {
        case .ok:
            guard let expiration = sensorExpiresAt else { return nil }
            let remaining = max(0, expiration.timeIntervalSinceNow)
            guard remaining < .hours(48) else { return nil }
            return DirectConnect_LifecycleProgress(percentComplete: 1 - remaining / lifetime, progressState: remaining < .hours(24) ? .warning : .normalCGM)
        case .gracePeriod:
            guard let end = sensorEndsAt else { return nil }
            let remaining = max(0, end.timeIntervalSinceNow)
            return DirectConnect_LifecycleProgress(percentComplete: 1 - remaining / DirectConnect_SensorLifetime.gracePeriod, progressState: .critical)
        case .expired:
            return DirectConnect_LifecycleProgress(percentComplete: 1, progressState: .critical)
        default:
            return nil
        }
    }
}

// MARK: - Last sensor contact under the main-screen CGM pill

/// Wording for the "Last ♥ today @ 1:33p" line. Pure, so it can be tested with a fixed clock.
enum DirectConnect_HeartbeatText {
    static func when(_ contact: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let contact = contact else {
            return NSLocalizedString("none yet", comment: "DirectConnect HUD: no sensor contact yet")
        }
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        // "1:33 PM" → "1:33p": the line under the pill has room for about 20 characters.
        let clock = time.string(from: contact)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: " AM", with: "a")
            .replacingOccurrences(of: " PM", with: "p")
        if calendar.isDate(contact, inSameDayAs: now) {
            return String(format: NSLocalizedString("today @ %@", comment: "DirectConnect HUD contact today (1: time)"), clock)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(contact, inSameDayAs: yesterday) {
            return String(format: NSLocalizedString("yesterday @ %@", comment: "DirectConnect HUD contact yesterday (1: time)"), clock)
        }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(day.string(from: contact)) @ \(clock)"
    }
}

extension DirectConnect_G7CGMManager {
    /// "Last sensor ♥ today @ 1:33p": when DirectConnect last heard from the sensor, so a user can
    /// see it is working even between readings or while the sensor withholds values.
    var hudFootnote: NSAttributedString {
        let grey = UIColor.secondaryLabel
        let result = NSMutableAttributedString(string: NSLocalizedString("Last sensor ", comment: "DirectConnect HUD footnote prefix"),
                                               attributes: [.foregroundColor: grey])
        if let heart = UIImage(systemName: "heart.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: heart)
            attachment.bounds = CGRect(x: 0, y: -1, width: 10, height: 9)
            result.append(NSAttributedString(attachment: attachment))
        }
        result.append(NSAttributedString(string: " " + DirectConnect_HeartbeatText.when(state.latestConnect), attributes: [.foregroundColor: grey]))
        return result
    }
}

