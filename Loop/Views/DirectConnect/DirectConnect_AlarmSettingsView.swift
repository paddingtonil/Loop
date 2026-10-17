//
//  DirectConnect_AlarmSettingsView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Per-alarm switches, thresholds and repeat intervals.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

struct DirectConnect_AlarmSettingsView: View {
    @ObservedObject var displayGlucosePreference: DisplayGlucosePreference

    @State private var settings = DirectConnect_AlarmSettings.load(from: .standard)
    @State private var confirmUrgentLowOff = false

    init(displayGlucosePreference: DisplayGlucosePreference) {
        self.displayGlucosePreference = displayGlucosePreference
    }

    private var isMmol: Bool { displayGlucosePreference.unit == .millimolesPerLiter }
    /// One step is 1 mg/dL, or 0.1 mmol/L (1.8 mg/dL) when the user displays mmol/L.
    private var glucoseStep: Double { isMmol ? 1.8 : 1 }

    var body: some View {
        Form {
            Section {
                Text(NSLocalizedString("Alarms use Loop's notifications. Urgent Low uses the most urgent level Loop can request. Test that you can hear it with your phone on silent.", comment: "DirectConnect alarm settings intro"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(header: Text(NSLocalizedString("Urgent Low", comment: "DirectConnect urgent low section"))) {
                Toggle(NSLocalizedString("Enabled", comment: "DirectConnect alarm enabled"), isOn: Binding(
                    get: { settings.urgentLowEnabled },
                    set: { newValue in
                        if newValue { update { $0.urgentLowEnabled = true } } else { confirmUrgentLowOff = true }
                    }))
                if settings.urgentLowEnabled {
                    thresholdStepper(NSLocalizedString("Below", comment: "DirectConnect below threshold"), value: \.urgentLowThreshold, range: DirectConnect_AlarmSettings.urgentLowRange)
                    minutesPicker(NSLocalizedString("Repeat every", comment: "DirectConnect repeat"), value: \.urgentLowRepeatMinutes, options: [5, 10, 15, 20, 30])
                }
            }

            Section(header: Text(NSLocalizedString("Low", comment: "DirectConnect low section"))) {
                Toggle(NSLocalizedString("Enabled", comment: "DirectConnect alarm enabled"), isOn: binding(\.lowEnabled))
                if settings.lowEnabled {
                    thresholdStepper(NSLocalizedString("Below", comment: "DirectConnect below threshold"), value: \.lowThreshold, range: DirectConnect_AlarmSettings.lowRange)
                    minutesPicker(NSLocalizedString("Repeat every", comment: "DirectConnect repeat"), value: \.lowRepeatMinutes, options: [5, 10, 15, 20, 30, 45, 60])
                }
            }

            Section(header: Text(NSLocalizedString("High", comment: "DirectConnect high section"))) {
                Toggle(NSLocalizedString("Enabled", comment: "DirectConnect alarm enabled"), isOn: binding(\.highEnabled))
                if settings.highEnabled {
                    thresholdStepper(NSLocalizedString("Above", comment: "DirectConnect above threshold"), value: \.highThreshold, range: DirectConnect_AlarmSettings.highRange)
                    minutesPicker(NSLocalizedString("Repeat every", comment: "DirectConnect repeat"), value: \.highRepeatMinutes, options: [15, 30, 60, 90, 120, 180, 240])
                }
            }

            Section(header: Text(NSLocalizedString("Rate of Change", comment: "DirectConnect rate section")),
                    footer: Text(NSLocalizedString("Each fires once per episode and clears when the rate slows.", comment: "DirectConnect rate footer"))) {
                Toggle(NSLocalizedString("Falling Fast", comment: "DirectConnect falling fast"), isOn: binding(\.fallingFastEnabled))
                if settings.fallingFastEnabled {
                    rateStepper(value: \.fallingRate, sign: "−")
                }
                Toggle(NSLocalizedString("Rising Fast", comment: "DirectConnect rising fast"), isOn: binding(\.risingFastEnabled))
                if settings.risingFastEnabled {
                    rateStepper(value: \.risingRate, sign: "+")
                }
            }

            Section(header: Text(NSLocalizedString("Sensor", comment: "DirectConnect sensor alarms section"))) {
                Toggle(NSLocalizedString("Signal Loss", comment: "DirectConnect signal loss"), isOn: binding(\.signalLossEnabled))
                if settings.signalLossEnabled {
                    minutesPicker(NSLocalizedString("After no reading for", comment: "DirectConnect signal loss after"), value: \.signalLossMinutes, options: [10, 15, 20, 30, 45, 60])
                }
                Toggle(NSLocalizedString("Sensor Expiring (24 h and 2 h before)", comment: "DirectConnect expiring"), isOn: binding(\.sensorExpiringEnabled))
                Toggle(NSLocalizedString("Sensor Ended or Failed", comment: "DirectConnect ended"), isOn: binding(\.sensorEndedEnabled))
            }

            Section {
                Button(NSLocalizedString("Restore Defaults", comment: "DirectConnect restore alarm defaults")) {
                    update { $0 = .defaults }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Glucose Alarms", comment: "DirectConnect alarms title"))
        .alert(NSLocalizedString("Turn Off Urgent Low?", comment: "DirectConnect urgent low off title"), isPresented: $confirmUrgentLowOff) {
            Button(NSLocalizedString("Turn Off", comment: "DirectConnect urgent low off confirm"), role: .destructive) {
                update { $0.urgentLowEnabled = false }
            }
            Button(NSLocalizedString("Keep On", comment: "DirectConnect urgent low keep"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("Loop will not warn you about urgent low glucose.", comment: "DirectConnect urgent low off message"))
        }
        .onAppear {
            DirectConnect_G7CGMManager.setDisplayUnit(displayGlucosePreference.unit)
        }
    }

    // MARK: - Editing

    private func update(_ change: (inout DirectConnect_AlarmSettings) -> Void) {
        var copy = settings
        change(&copy)
        copy = copy.normalized()
        copy.save(to: .standard)
        settings = copy
    }

    private func binding(_ keyPath: WritableKeyPath<DirectConnect_AlarmSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func format(_ mgdl: Double) -> String {
        let quantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl)
        return displayGlucosePreference.formatter.string(from: quantity) ?? String(format: "%.0f", mgdl)
    }

    private func thresholdStepper(_ label: String, value keyPath: WritableKeyPath<DirectConnect_AlarmSettings, Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: Binding(get: { settings[keyPath: keyPath] }, set: { v in update { $0[keyPath: keyPath] = v } }),
                in: range, step: glucoseStep) {
            HStack {
                Text(label)
                Spacer()
                Text(format(settings[keyPath: keyPath])).foregroundColor(.secondary)
            }
        }
    }

    private func rateStepper(value keyPath: WritableKeyPath<DirectConnect_AlarmSettings, Double>, sign: String) -> some View {
        Stepper(value: Binding(get: { settings[keyPath: keyPath] }, set: { v in update { $0[keyPath: keyPath] = v } }),
                in: DirectConnect_AlarmSettings.rateRange, step: 0.5) {
            HStack {
                Text(NSLocalizedString("Rate", comment: "DirectConnect rate label"))
                Spacer()
                Text(rateText(settings[keyPath: keyPath], sign: sign)).foregroundColor(.secondary)
            }
        }
    }

    private func rateText(_ mgdlPerMinute: Double, sign: String) -> String {
        if isMmol {
            return String(format: "%@%.2f mmol/L/min", sign, mgdlPerMinute / 18.0182)
        }
        return String(format: "%@%.1f mg/dL/min", sign, mgdlPerMinute)
    }

    private func minutesPicker(_ label: String, value keyPath: WritableKeyPath<DirectConnect_AlarmSettings, Double>, options: [Double]) -> some View {
        Picker(label, selection: Binding(get: { settings[keyPath: keyPath] }, set: { v in update { $0[keyPath: keyPath] = v } })) {
            ForEach(options, id: \.self) { minutes in
                Text(String(format: NSLocalizedString("%.0f min", comment: "DirectConnect minutes option (1: minutes)"), minutes)).tag(minutes)
            }
        }
    }
}
