//
//  DirectConnect_CalibrationView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Enter a fingerstick value to calibrate the sensor.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

struct DirectConnect_CalibrationView: View {
    let cgmManager: DirectConnect_G7CGMManager
    @ObservedObject var displayGlucosePreference: DisplayGlucosePreference

    @State private var entry = ""
    @State private var status: DirectConnect_CalibrationStatus
    @State private var message: String?
    @State private var lastCompleted: DirectConnect_PendingCalibration?
    @State private var queue: DirectConnect_CalibrationQueue

    init(cgmManager: DirectConnect_G7CGMManager, displayGlucosePreference: DisplayGlucosePreference) {
        self.cgmManager = cgmManager
        self.displayGlucosePreference = displayGlucosePreference
        _status = State(initialValue: cgmManager.state.calibration.status)
        _lastCompleted = State(initialValue: cgmManager.state.calibration.lastCompleted)
        _queue = State(initialValue: cgmManager.state.calibration)
    }

    /// What is happening to the current value, in words, so the fixed footer above (which
    /// describes how calibration works) is not read as this value's status.
    private var statusDetail: String? {
        let format = { (value: Double) in
            displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value))
        }
        switch status {
        case .queued:
            guard let pending = queue.pending else { return nil }
            return String(format: NSLocalizedString("%@ is waiting for the sensor's next connection (within about 5 minutes).", comment: "DirectConnect calibration queued detail (1: value)"), format(pending.glucose))
        case .processing:
            guard let value = queue.awaitingBounds else { return nil }
            let accepted = queue.awaitingSince.map { Self.timeFormatter.string(from: $0) } ?? "–"
            return String(format: NSLocalizedString("The sensor accepted %@ at %@ and is applying it. It confirms at a later connection, usually within 10 minutes.", comment: "DirectConnect calibration processing detail (1: value, 2: time)"), format(value.glucose), accepted)
        default:
            return nil
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var isMmol: Bool { displayGlucosePreference.unit == .millimolesPerLiter }

    /// The entry converted to mg/dL, or nil if it is not a number in the 40–400 mg/dL range.
    private var mgdlValue: Double? {
        guard let value = Double(entry.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let mgdl = HKQuantity(unit: displayGlucosePreference.unit, doubleValue: value).doubleValue(for: .milligramsPerDeciliter)
        return (40...400).contains(mgdl) ? mgdl : nil
    }

    var body: some View {
        Form {
            Section(footer: Text(NSLocalizedString("Use a fresh fingerstick taken with clean, dry hands. The value is sent to the sensor at its next connection, within 5 min.", comment: "DirectConnect calibration footer"))) {
                HStack {
                    TextField(isMmol ? "5.5" : "100", text: $entry)
                        .keyboardType(.decimalPad)
                    Text(isMmol ? "mmol/L" : "mg/dL").foregroundColor(.secondary)
                }
                Button(NSLocalizedString("Send Calibration", comment: "DirectConnect send calibration")) {
                    guard let mgdl = mgdlValue else { return }
                    let refusal = cgmManager.state.calibration.refusalReason(glucose: mgdl, date: Date())
                    if refusal == nil, cgmManager.calibrate(glucose: mgdl) {
                        message = nil
                        entry = ""
                    } else if refusal == .outOfRange {
                        message = NSLocalizedString("The value must be between 40 and 400 mg/dL.", comment: "DirectConnect calibration out of range")
                    } else {
                        message = NSLocalizedString("A calibration is waiting to be sent. It is sent at the next sensor connection, within about 5 minutes.", comment: "DirectConnect calibration waiting")
                    }
                    refresh()
                }
                .disabled(mgdlValue == nil)
            }

            Section(header: Text(NSLocalizedString("Status", comment: "DirectConnect calibration status section"))) {
                Text(status.text)
                if let detail = statusDetail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if let message = message {
                    Text(message).foregroundColor(.red)
                }
            }

            Section(header: Text(NSLocalizedString("Last Successful Calibration", comment: "DirectConnect last calibration section")),
                    footer: Text(NSLocalizedString("The newest value this sensor reported as applied. It resets when you pair a new sensor.", comment: "DirectConnect last calibration footer"))) {
                if let last = lastCompleted {
                    LabeledValueView(label: NSLocalizedString("Value", comment: "DirectConnect last calibration value"),
                                     value: displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: last.glucose)))
                    LabeledValueView(label: NSLocalizedString("Fingerstick Time", comment: "DirectConnect last calibration time"),
                                     value: Self.dateFormatter.string(from: last.date))
                } else {
                    Text(NSLocalizedString("None for this sensor", comment: "DirectConnect no completed calibration"))
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("Calibrate", comment: "DirectConnect calibrate title"))
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        status = cgmManager.state.calibration.status
        lastCompleted = cgmManager.state.calibration.lastCompleted
        queue = cgmManager.state.calibration
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}
