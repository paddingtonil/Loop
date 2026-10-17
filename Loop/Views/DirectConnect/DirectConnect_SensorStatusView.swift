//
//  DirectConnect_SensorStatusView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Sensor status, configuration and management screen.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Adapted from LoopKit G7SensorKitUI G7SettingsView (MIT, © 2022 LoopKit Authors).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI
import LoopKit
import LoopKitUI

struct DirectConnect_SensorStatusView: View {
    @ObservedObject var viewModel: DirectConnect_SensorStatusViewModel
    let didFinish: () -> Void
    let deleteCGM: () -> Void

    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.glucoseTintColor) private var glucoseTintColor

    @State private var showingDeleteConfirmation = false
    @State private var showingRepair = false
    @State private var showingNewSensor = false
    @State private var repairCode = ""
    @State private var showingChangeGuide = false
    @State private var dexcomAppInstalled = false

    init(viewModel: DirectConnect_SensorStatusViewModel, didFinish: @escaping () -> Void, deleteCGM: @escaping () -> Void) {
        self.viewModel = viewModel
        self.didFinish = didFinish
        self.deleteCGM = deleteCGM
    }

    var body: some View {
        List {
            headerSection
            if let failure = viewModel.state.pairingFailure {
                pairingProblemSection(failure)
            } else if let notice = viewModel.state.pairingNotice {
                Section {
                    Label(notice, systemImage: "info.circle")
                        .foregroundColor(.secondary)
                }
            }
            if dexcomAppInstalled {
                Section { DirectConnect_TipView(tip: DirectConnect_Tips.dexcomAppWarning) }
            } else if viewModel.cgmManager.repeatedTakeover {
                Section { DirectConnect_TipView(tip: DirectConnect_Tips.repeatedTakeoverWarning) }
            }
            if let tip = currentTip {
                Section {
                    DirectConnect_TipView(tip: tip)
                }
            }
            sensorSection
            lastReadingSection
            bluetoothSection
            configurationSection
            toolsSection
            sensorChangeGuideSection
            managementSection
        }
        .insetGroupedListStyle()
        .onAppear {
            dexcomAppInstalled = DirectConnect_OtherApps.dexcomG7AppInstalled
            let lifecycle = viewModel.lifecycleState
            showingChangeGuide = lifecycle == .gracePeriod || lifecycle == .expired || lifecycle == .failed
        }
        .navigationBarTitle(NSLocalizedString("DirectConnect", comment: "DirectConnect status title"))
        .navigationBarItems(trailing: Button(NSLocalizedString("Done", comment: "DirectConnect done button"), action: didFinish))
        .sheet(isPresented: $showingNewSensor) {
            NavigationView {
                DirectConnect_SetupView(
                    title: NSLocalizedString("New Sensor", comment: "DirectConnect new sensor title"),
                    continueLabel: NSLocalizedString("Pair New Sensor", comment: "DirectConnect pair new sensor button"),
                    checklist: DirectConnect_Tips.newSensorChecklist,
                    onContinue: { type, code in
                        viewModel.addNewSensor(type: type, code: code)
                        showingNewSensor = false
                    },
                    onCancel: { showingNewSensor = false })
            }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: DirectConnect_Branding.iconName)
                        .font(.system(size: 34))
                        .foregroundColor(DirectConnect_Branding.color)
                    VStack(alignment: .leading) {
                        Text("\(viewModel.state.sensorType.displayName) DirectConnect").font(.headline)
                        DirectConnect_ExclusiveBadge()
                    }
                }
                Text(viewModel.statusText)
                    .foregroundColor(statusColor)
                SwiftUI.ProgressView(value: viewModel.progress)
                    .accentColor(statusColor)
                if let daysLeft = viewModel.daysLeftText {
                    HStack {
                        Spacer()
                        Text(daysLeft)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func pairingProblemSection(_ failure: String) -> some View {
        Section {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(guidanceColors.critical)
            // While searching for a new sensor the failure comes from a skipped nearby sensor, and
            // re-entering the code would only retry it; Pair New Sensor below changes the code.
            if viewModel.state.sensorID != nil {
                repairButton
            }
        }
    }

    private var repairButton: some View {
        Group {
            Button(NSLocalizedString("Re-enter Pairing Code", comment: "DirectConnect re-enter code button")) {
                repairCode = ""
                showingRepair = true
            }
            .alert(NSLocalizedString("Pairing Code", comment: "DirectConnect repair alert title"), isPresented: $showingRepair) {
                TextField("0000", text: $repairCode).keyboardType(.numberPad)
                Button(NSLocalizedString("Pair", comment: "DirectConnect repair confirm")) {
                    if DirectConnect_SetupView.isValidCode(repairCode) {
                        viewModel.repair(code: repairCode)
                    }
                }
                Button(NSLocalizedString("Cancel", comment: "DirectConnect cancel"), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("Enter the 4-digit code from the sensor applicator.", comment: "DirectConnect repair alert message"))
            }
        }
    }

    private var sensorSection: some View {
        Section(header: Text(NSLocalizedString("Sensor", comment: "DirectConnect sensor section"))) {
            LabeledValueView(label: NSLocalizedString("Name", comment: "DirectConnect sensor name"), value: viewModel.state.sensorID ?? "–")
            LabeledValueView(label: NSLocalizedString("Pairing Code", comment: "DirectConnect sensor pairing code"), value: viewModel.state.pairingCode ?? "–")
            if let start = viewModel.state.activatedAt {
                LabeledDateView(label: NSLocalizedString("Sensor Start", comment: "DirectConnect sensor start"), date: start, dateFormatter: viewModel.dateFormatter)
                LabeledDateView(label: NSLocalizedString("Expiration", comment: "DirectConnect expiration"), date: viewModel.cgmManager.sensorExpiresAt, dateFormatter: viewModel.dateFormatter)
                LabeledDateView(label: NSLocalizedString("Grace Period End", comment: "DirectConnect grace end"), date: viewModel.cgmManager.sensorEndsAt, dateFormatter: viewModel.dateFormatter)
            }
            LabeledValueView(label: NSLocalizedString("Session Length", comment: "DirectConnect session length"), value: viewModel.sessionLengthText)
            if let battery = viewModel.batteryText {
                LabeledValueView(label: NSLocalizedString("Battery", comment: "DirectConnect battery"), value: battery)
            }
            if let firmware = viewModel.state.versionInfo?.firmwareVersion {
                LabeledValueView(label: NSLocalizedString("Firmware", comment: "DirectConnect firmware"), value: firmware)
            }
        }
    }

    private var lastReadingSection: some View {
        Section(header: Text(NSLocalizedString("Last Reading", comment: "DirectConnect last reading section"))) {
            LabeledValueView(label: NSLocalizedString("Glucose", comment: "DirectConnect glucose"), value: viewModel.glucoseText)
            LabeledDateView(label: NSLocalizedString("Time", comment: "DirectConnect reading time"), date: viewModel.state.latestReadingTimestamp, dateFormatter: viewModel.dateFormatter)
            LabeledValueView(label: NSLocalizedString("Trend", comment: "DirectConnect trend"), value: viewModel.trendText)
        }
    }

    private var bluetoothSection: some View {
        Section(header: Text(NSLocalizedString("Bluetooth", comment: "DirectConnect bluetooth section"))) {
            HStack {
                Text(viewModel.connected
                     ? NSLocalizedString("Connected", comment: "DirectConnect connected")
                     : viewModel.scanning
                        ? NSLocalizedString("Scanning", comment: "DirectConnect scanning")
                        : NSLocalizedString("Waiting for sensor (wakes every 5 minutes)", comment: "DirectConnect waiting"))
                Spacer()
                if viewModel.scanning && !viewModel.connected {
                    SwiftUI.ProgressView()
                }
            }
            LabeledDateView(label: NSLocalizedString("Last Connect", comment: "DirectConnect last connect"), date: viewModel.state.latestConnect, dateFormatter: viewModel.dateFormatter)
            if let rssi = viewModel.rssi {
                LabeledValueView(label: NSLocalizedString("Signal Strength", comment: "DirectConnect RSSI"), value: "\(rssi) dBm")
            }
        }
    }

    private var configurationSection: some View {
        Section(header: Text(NSLocalizedString("Configuration", comment: "DirectConnect configuration section")),
                footer: Text(NSLocalizedString("On: Loop sends this sensor's glucose readings to the services set up under Settings → Services, such as Nightscout or Tidepool. Off: readings stay on this iPhone; Loop still uses them for dosing, alarms and Apple Health. Turn this off if another app already uploads the same readings, so they are not uploaded twice. DirectConnect never uploads to Dexcom Clarity or Dexcom Share.", comment: "DirectConnect upload readings footer"))) {
            Toggle(NSLocalizedString("Upload Readings", comment: "DirectConnect upload readings toggle"), isOn: Binding(
                get: { viewModel.state.uploadReadings },
                set: { viewModel.setUploadReadings($0) }))
        }
    }

    private var toolsSection: some View {
        Section {
            NavigationLink(destination: DirectConnect_CalibrationView(cgmManager: viewModel.cgmManager, displayGlucosePreference: viewModel.displayGlucosePreference)) {
                Label(NSLocalizedString("Calibrate", comment: "DirectConnect calibrate link"), systemImage: "drop.fill")
            }
            NavigationLink(destination: DirectConnect_AlarmSettingsView(displayGlucosePreference: viewModel.displayGlucosePreference)) {
                Label(NSLocalizedString("Alarms", comment: "DirectConnect alarms link"), systemImage: "bell.badge.fill")
            }
            NavigationLink(destination: DirectConnect_DiagnosticsView(viewModel: viewModel)) {
                Label(NSLocalizedString("Diagnostics", comment: "DirectConnect diagnostics link"), systemImage: "stethoscope")
            }
        }
    }

    private var managementSection: some View {
        Section {
            Button(NSLocalizedString("Pair New Sensor", comment: "DirectConnect new sensor button")) {
                showingNewSensor = true
            }
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Text(NSLocalizedString("Delete CGM", comment: "DirectConnect delete CGM"))
            }
            .confirmationDialog(NSLocalizedString("Delete this CGM? Loop will stop receiving glucose from the sensor.", comment: "DirectConnect delete confirmation"),
                                isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button(NSLocalizedString("Delete CGM", comment: "DirectConnect delete CGM"), role: .destructive, action: deleteCGM)
            }
        }
    }

    private var currentTip: DirectConnect_Tip? {
        DirectConnect_Tips.current(lifecycle: viewModel.lifecycleState,
                                   pairingFailure: viewModel.state.pairingFailure,
                                   expiresAt: viewModel.cgmManager.sensorExpiresAt,
                                   endsAt: viewModel.cgmManager.sensorEndsAt,
                                   warmupEndsAt: viewModel.cgmManager.sensorFinishesWarmupAt)
    }

    private var sensorChangeGuideSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showingChangeGuide) {
                DirectConnect_StepsView(steps: DirectConnect_Tips.sensorChangeSteps)
            } label: {
                Label(NSLocalizedString("How to change your sensor", comment: "DirectConnect change guide title"), systemImage: "questionmark.circle")
                    .foregroundColor(DirectConnect_Branding.color)
            }
        }
    }

    private var statusColor: Color {
        switch viewModel.lifecycleState {
        case .ok: return glucoseTintColor
        case .warmup, .searching, .notPaired: return .secondary
        case .gracePeriod: return guidanceColors.warning
        case .failed, .expired: return guidanceColors.critical
        }
    }
}
