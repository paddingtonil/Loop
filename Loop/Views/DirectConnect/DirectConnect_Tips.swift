//
//  DirectConnect_Tips.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — In-app guidance: what to do now, sensor-change steps, pre-pairing checklist.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI
import UIKit

/// Detects other apps that would compete with DirectConnect for the sensor.
enum DirectConnect_OtherApps {
    // Requires "dexcomg7" in Info.plist LSApplicationQueriesSchemes.
    private static let dexcomG7URL = URL(string: "dexcomg7://")!

    /// True when the Dexcom G7 app is installed. It reconnects to its sensor in the background and
    /// takes the sensor away from Loop whenever it pairs.
    static var dexcomG7AppInstalled: Bool {
        UIApplication.shared.canOpenURL(dexcomG7URL)
    }
}

struct DirectConnect_Tip: Equatable {
    let systemImage: String
    let title: String
    let body: String
}

/// A DirectConnect-green card that tells the user what to do at this moment.
struct DirectConnect_TipView: View {
    let tip: DirectConnect_Tip

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tip.systemImage)
                .font(.title3)
                .foregroundColor(DirectConnect_Branding.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title).font(.subheadline.weight(.semibold))
                Text(tip.body).font(.footnote).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Numbered steps, used for the sensor-change guide and the pairing checklist.
struct DirectConnect_StepsView: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(DirectConnect_Branding.color))
                    Text(step).font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

enum DirectConnect_Tips {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static func time(_ date: Date?) -> String {
        date.map { timeFormatter.string(from: $0) } ?? NSLocalizedString("soon", comment: "DirectConnect tip unknown time")
    }

    // MARK: - What to do now

    /// The single most useful instruction for the sensor's current state, or nil when no action is needed.
    static func current(lifecycle: DirectConnect_LifecycleState,
                        pairingFailure: String?,
                        expiresAt: Date?,
                        endsAt: Date?,
                        warmupEndsAt: Date?,
                        now: Date = Date()) -> DirectConnect_Tip? {
        if pairingFailure != nil {
            // The pairing-problem section on the same screen already explains the failure.
            return nil
        }
        switch lifecycle {
        case .notPaired:
            return DirectConnect_Tip(
                systemImage: "number.square",
                title: NSLocalizedString("Pair your sensor", comment: "DirectConnect tip not paired title"),
                body: NSLocalizedString("Tap Pair New Sensor below and enter the 4-digit code from the sensor's applicator.", comment: "DirectConnect tip not paired body"))
        case .searching:
            return DirectConnect_Tip(
                systemImage: "dot.radiowaves.left.and.right",
                title: NSLocalizedString("Looking for your sensor", comment: "DirectConnect tip searching title"),
                body: NSLocalizedString("Keep your phone within a few feet of the sensor. The sensor wakes about every 5 minutes, and pairing finishes on the next wake. If the Dexcom app is connected to this sensor, close it so it does not take the connection.", comment: "DirectConnect tip searching body"))
        case .warmup:
            return DirectConnect_Tip(
                systemImage: "hourglass",
                title: NSLocalizedString("Sensor warming up", comment: "DirectConnect tip warmup title"),
                body: String(format: NSLocalizedString("Paired. Glucose readings start after warmup, at about %@. Loop does not receive glucose until then.", comment: "DirectConnect tip warmup body (1: time)"), time(warmupEndsAt)))
        case .ok:
            if let expiresAt = expiresAt, expiresAt.timeIntervalSince(now) < 24 * 3600 {
                return DirectConnect_Tip(
                    systemImage: "calendar.badge.clock",
                    title: NSLocalizedString("Sensor ends soon", comment: "DirectConnect tip expiring title"),
                    body: String(format: NSLocalizedString("This sensor ends %@, followed by a 12-hour grace period. Have a new sensor ready. After you insert it, delete this CGM (Settings → CGM → Delete CGM), add Dexcom G7/ONE+ using DirectConnect, and enter the new sensor's code.", comment: "DirectConnect tip expiring body (1: time)"), time(expiresAt)))
            }
            return nil
        case .gracePeriod:
            return DirectConnect_Tip(
                systemImage: "exclamationmark.arrow.circlepath",
                title: NSLocalizedString("Replace your sensor now", comment: "DirectConnect tip grace title"),
                body: String(format: NSLocalizedString("The sensor session is over. Readings continue only until %@. Insert a new sensor, then delete this CGM (Settings → CGM → Delete CGM), add Dexcom G7/ONE+ using DirectConnect, and enter the new sensor's code.", comment: "DirectConnect tip grace body (1: time)"), time(endsAt)))
        case .expired:
            return DirectConnect_Tip(
                systemImage: "arrow.triangle.2.circlepath",
                title: NSLocalizedString("Sensor ended — pair a new one", comment: "DirectConnect tip expired title"),
                body: NSLocalizedString("Loop is no longer receiving glucose from this sensor. Insert a new sensor, then delete this CGM (Settings → CGM → Delete CGM), add Dexcom G7/ONE+ using DirectConnect, and enter the new sensor's code.", comment: "DirectConnect tip expired body"))
        case .failed:
            return DirectConnect_Tip(
                systemImage: "xmark.octagon",
                title: NSLocalizedString("Sensor failed — replace it", comment: "DirectConnect tip failed title"),
                body: NSLocalizedString("The sensor reported a failure and will not send glucose again. Remove it, insert a new sensor, then delete this CGM (Settings → CGM → Delete CGM), add Dexcom G7/ONE+ using DirectConnect, and enter the new sensor's code. Dexcom replaces failed sensors; contact Dexcom support.", comment: "DirectConnect tip failed body"))
        }
    }

    static let dexcomAppWarning = DirectConnect_Tip(
        systemImage: "exclamationmark.triangle.fill",
        title: NSLocalizedString("Delete the Dexcom app", comment: "DirectConnect dexcom app warning title"),
        body: NSLocalizedString("The Dexcom G7 app is installed on this iPhone. It connects to the sensor in the background, even when you don't open it, and takes the sensor away from Loop. DirectConnect replaces it: delete the Dexcom app (or remove the sensor in it) so Loop keeps the sensor.", comment: "DirectConnect dexcom app warning body"))

    static let repeatedTakeoverWarning = DirectConnect_Tip(
        systemImage: "arrow.triangle.swap",
        title: NSLocalizedString("Another app keeps taking the sensor", comment: "DirectConnect takeover warning title"),
        body: NSLocalizedString("Loop has had to take the sensor back more than once in the last 6 hours, and readings are lost each time. Delete the Dexcom app or any other app paired with this sensor.", comment: "DirectConnect takeover warning body"))

    // MARK: - Sensor change guide

    static let sensorChangeSteps: [String] = [
        NSLocalizedString("Insert the new sensor with its applicator, as Dexcom's instructions describe. You can do this during the old sensor's 12-hour grace period.", comment: "DirectConnect change step insert"),
        NSLocalizedString("Before you throw the applicator away, note the 4-digit pairing code printed on it. Each sensor has its own code. A photo works.", comment: "DirectConnect change step code"),
        NSLocalizedString("Delete the old CGM: in Loop, Settings → CGM → Delete CGM. Loop stops using the old sensor.", comment: "DirectConnect change step delete"),
        NSLocalizedString("Add the new CGM: Settings → Add CGM → Dexcom G7/ONE+ using DirectConnect.", comment: "DirectConnect change step add"),
        NSLocalizedString("Pair: choose the sensor type and enter the new sensor's 4-digit pairing code.", comment: "DirectConnect change step pair"),
        NSLocalizedString("Keep your phone near the new sensor. Pairing finishes within about 5 minutes.", comment: "DirectConnect change step wait"),
        NSLocalizedString("Wait for warmup. The sensor screen shows when readings will start. Loop has no glucose during warmup, so check with a fingerstick if you need to.", comment: "DirectConnect change step warmup"),
        NSLocalizedString("Remove the old sensor once the new one shows readings.", comment: "DirectConnect change step remove"),
    ]

    // MARK: - Before pairing

    static let firstPairingChecklist: [String] = [
        NSLocalizedString("Insert the sensor first. Loop pairs with a sensor that is already on your body.", comment: "DirectConnect checklist insert"),
        NSLocalizedString("Find the 4-digit pairing code printed on the sensor's applicator.", comment: "DirectConnect checklist code"),
        NSLocalizedString("If the Dexcom app was using this sensor, remove the sensor in the Dexcom app or delete the app. Only one app can own a sensor.", comment: "DirectConnect checklist dexcom"),
        NSLocalizedString("Keep your phone within a few feet of the sensor until pairing finishes (up to 5 minutes).", comment: "DirectConnect checklist distance"),
    ]

    static let newSensorChecklist: [String] = [
        NSLocalizedString("Insert the new sensor before pairing it.", comment: "DirectConnect new checklist insert"),
        NSLocalizedString("Enter the code from the NEW sensor's applicator. The old sensor's code does not work.", comment: "DirectConnect new checklist code"),
        NSLocalizedString("To change sensors, delete the old CGM (Settings → CGM → Delete CGM), then add Dexcom G7/ONE+ using DirectConnect and enter the new code.", comment: "DirectConnect new checklist switch"),
    ]
}
