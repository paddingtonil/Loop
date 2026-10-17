//
//  DirectConnect_SetupView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Choose sensor type and enter the applicator pairing code.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI
import LoopKitUI

struct DirectConnect_SetupView: View {
    let title: String
    let continueLabel: String
    let checklist: [String]
    let onContinue: (DirectConnect_SensorType, String) -> Void
    /// The sensor remembered from the last "Delete CGM", offered for a one-tap reconnect.
    let lastSensor: DirectConnect_LastSensor?
    let onReconnect: ((DirectConnect_LastSensor) -> Void)?
    let onCancel: () -> Void

    @State private var sensorType: DirectConnect_SensorType = .g7
    @State private var code = ""
    @State private var dexcomAppInstalled = false

    init(title: String = NSLocalizedString("DirectConnect", comment: "DirectConnect setup title"),
         continueLabel: String = NSLocalizedString("Pair Sensor", comment: "DirectConnect setup continue button"),
         checklist: [String] = DirectConnect_Tips.firstPairingChecklist,
         lastSensor: DirectConnect_LastSensor? = nil,
         onReconnect: ((DirectConnect_LastSensor) -> Void)? = nil,
         onContinue: @escaping (DirectConnect_SensorType, String) -> Void,
         onCancel: @escaping () -> Void)
    {
        self.lastSensor = lastSensor
        self.onReconnect = onReconnect
        self.title = title
        self.continueLabel = continueLabel
        self.checklist = checklist
        self.onContinue = onContinue
        self.onCancel = onCancel
    }

    static func isValidCode(_ code: String) -> Bool {
        (code.count == 4 || code.count == 6) && code.allSatisfy(\.isNumber)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    DirectConnect_ExclusiveBadge()
                    Text(NSLocalizedString("Loop connects to your sensor directly. The Dexcom app is not needed and should be deleted or have its sensor removed, so the two apps do not compete for the sensor.", comment: "DirectConnect setup explanation"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let last = lastSensor, let onReconnect = onReconnect {
                Section(header: Text(NSLocalizedString("Your last sensor", comment: "DirectConnect reconnect section header")),
                        footer: Text(NSLocalizedString("Use this if that sensor is still on your body and running. Loop reconnects with the saved pairing at the sensor's next wake, within about 5 minutes. For a new sensor, use Pair Sensor below.", comment: "DirectConnect reconnect footer"))) {
                    Button {
                        onReconnect(last)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: NSLocalizedString("Reconnect to %@", comment: "DirectConnect reconnect button (1: sensor name)"), last.sensorID))
                                .font(.headline)
                            Text(String(format: NSLocalizedString("%@ · code %@", comment: "DirectConnect reconnect detail (1: sensor type, 2: code)"), last.sensorType.displayName, last.pairingCode))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if dexcomAppInstalled {
                Section { DirectConnect_TipView(tip: DirectConnect_Tips.dexcomAppWarning) }
            }

            Section(header: Text(NSLocalizedString("Before you pair", comment: "DirectConnect setup checklist section"))) {
                DirectConnect_StepsView(steps: checklist)
            }

            Section(header: Text(NSLocalizedString("Sensor", comment: "DirectConnect setup sensor section"))) {
                Picker(NSLocalizedString("Sensor Type", comment: "DirectConnect sensor type picker"), selection: $sensorType) {
                    ForEach(DirectConnect_SensorType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            }

            Section(header: Text(NSLocalizedString("Pairing Code", comment: "DirectConnect pairing code section")),
                    footer: Text(NSLocalizedString("The 4-digit code printed on the sensor applicator. Each sensor has its own code.", comment: "DirectConnect pairing code footer"))) {
                TextField("0000", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(.title2, design: .monospaced))
                    .onChange(of: code) { newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(6))
                        if digits != newValue { code = digits }
                    }
            }

            Section {
                Button(continueLabel) {
                    onContinue(sensorType, code)
                }
                .disabled(!Self.isValidCode(code))
                Button(NSLocalizedString("Cancel", comment: "DirectConnect setup cancel"), role: .cancel, action: onCancel)
            }
        }
        .navigationTitle(title)
        .onAppear { dexcomAppInstalled = DirectConnect_OtherApps.dexcomG7AppInstalled }
    }
}

/// "PowerPack Exclusive" label shown on DirectConnect screens.
struct DirectConnect_ExclusiveBadge: View {
    var body: some View {
        // HStack, not Label: inside a Toggle row the list style split Label's icon and title onto separate lines.
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            Text(NSLocalizedString("PowerPack Exclusive", comment: "DirectConnect exclusive badge"))
        }
            .font(.caption.weight(.semibold))
            .fixedSize()
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(DirectConnect_Branding.powerPackPurple))
    }
}
