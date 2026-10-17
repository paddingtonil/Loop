//
//  DirectConnect_SettingsView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Feature toggle and entry point to alarm settings.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI
import LoopKitUI

struct DirectConnect_SettingsView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    @State private var featureEnabled = DirectConnect_FeatureFlags.isEnabled
    @State private var isActiveCGM = DirectConnect_FeatureFlags.isActiveCGM

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { featureEnabled },
                    set: {
                        DirectConnect_FeatureFlags.isEnabled = $0
                        featureEnabled = $0
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DirectConnect")
                        DirectConnect_ExclusiveBadge()
                    }
                }
                .disabled(isActiveCGM && featureEnabled)

                if isActiveCGM && featureEnabled {
                    Text(NSLocalizedString("Remove the DirectConnect CGM in Settings → CGM before turning this off.", comment: "DirectConnect cannot disable while active"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text(NSLocalizedString("Loop pairs directly with Dexcom G7, ONE+ and Stelo sensors using the code on the applicator. The Dexcom app is not needed. \"Dexcom G7/ONE+ using DirectConnect\" is always in Loop's Add CGM list; choosing it there turns this switch on.", comment: "DirectConnect feature description"))
            }

            if featureEnabled {
                Section {
                    NavigationLink(destination: DirectConnect_AlarmSettingsView(displayGlucosePreference: displayGlucosePreference)) {
                        Label(NSLocalizedString("Glucose Alarms", comment: "DirectConnect alarms link"), systemImage: "bell.badge.fill")
                    }
                } footer: {
                    Text(NSLocalizedString("Without the Dexcom app, these are your glucose alarms. Urgent Low is on by default.", comment: "DirectConnect alarms footer"))
                }

                Section(header: Text(NSLocalizedString("Without the Dexcom app", comment: "DirectConnect tradeoffs header"))) {
                    Text(NSLocalizedString("• No Dexcom Clarity or Dexcom Share upload. Loop's Nightscout upload still works.", comment: "DirectConnect tradeoff clarity"))
                    Text(NSLocalizedString("• Dexcom app alerts are replaced by DirectConnect alarms.", comment: "DirectConnect tradeoff alerts"))
                    Text(NSLocalizedString("• Only one app can own the sensor. Remove the sensor from the Dexcom app first.", comment: "DirectConnect tradeoff ownership"))
                }
                .font(.footnote)
            }

            Section(header: Text(NSLocalizedString("Credits", comment: "DirectConnect credits header"))) {
                Text(NSLocalizedString("DirectConnect's sensor pairing and communication are based on xDrip4iOS, created by Johan Degraeve and developed with the xDrip4iOS contributors. Thank you. xDrip4iOS is open source under the GNU GPL ver 3.", comment: "DirectConnect xDrip4iOS credit"))
                    .font(.footnote)
                Link(NSLocalizedString("xDrip4iOS on GitHub", comment: "DirectConnect xDrip4iOS link"), destination: URL(string: "https://github.com/JohanDegraeve/xdripswift")!)
                    .font(.footnote)
            }

            PowerPack_VersionFooter()
        }
        .navigationTitle("DirectConnect")
        .onAppear {
            featureEnabled = DirectConnect_FeatureFlags.isEnabled
            isActiveCGM = DirectConnect_FeatureFlags.isActiveCGM
            DirectConnect_G7CGMManager.setDisplayUnit(displayGlucosePreference.unit)
        }
    }
}
