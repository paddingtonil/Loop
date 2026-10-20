//
//  DirectConnect_AlarmSettingsView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Per-alarm switches, thresholds, repeat intervals, sounds and sound tests.
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
    @State private var testingKind: DirectConnect_AlarmKind?
    @State private var confirmPlayThroughOff: DirectConnect_AlarmKind?

    init(displayGlucosePreference: DisplayGlucosePreference) {
        self.displayGlucosePreference = displayGlucosePreference
    }

    private var isMmol: Bool { displayGlucosePreference.unit == .millimolesPerLiter }
    /// One step is 1 mg/dL, or 0.1 mmol/L (1.8 mg/dL) when the user displays mmol/L.
    private var glucoseStep: Double { isMmol ? 1.8 : 1 }

    var body: some View {
        Form {
            Section {
                Text(NSLocalizedString("Play Through Silent plays an alarm even with the phone on silent, in a Focus, or with Loop alerts muted. With it off, the alarm follows the phone's settings. It is on for Urgent Low and Falling Fast unless you turn it off; those two keep playing until you open Loop or press OK. Each alarm plays at its own volume, set on its Sound screen.", comment: "DirectConnect alarm settings intro"))
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
                    soundRows(.urgentLow)
                }
            }

            Section(header: Text(NSLocalizedString("Low", comment: "DirectConnect low section"))) {
                Toggle(NSLocalizedString("Enabled", comment: "DirectConnect alarm enabled"), isOn: binding(\.lowEnabled))
                if settings.lowEnabled {
                    thresholdStepper(NSLocalizedString("Below", comment: "DirectConnect below threshold"), value: \.lowThreshold, range: DirectConnect_AlarmSettings.lowRange)
                    minutesPicker(NSLocalizedString("Repeat every", comment: "DirectConnect repeat"), value: \.lowRepeatMinutes, options: [5, 10, 15, 20, 30, 45, 60])
                    soundRows(.low)
                }
            }

            Section(header: Text(NSLocalizedString("High", comment: "DirectConnect high section"))) {
                Toggle(NSLocalizedString("Enabled", comment: "DirectConnect alarm enabled"), isOn: binding(\.highEnabled))
                if settings.highEnabled {
                    thresholdStepper(NSLocalizedString("Above", comment: "DirectConnect above threshold"), value: \.highThreshold, range: DirectConnect_AlarmSettings.highRange)
                    minutesPicker(NSLocalizedString("Repeat every", comment: "DirectConnect repeat"), value: \.highRepeatMinutes, options: [15, 30, 60, 90, 120, 180, 240])
                    soundRows(.high)
                }
            }

            Section(header: Text(NSLocalizedString("Rate of Change", comment: "DirectConnect rate section")),
                    footer: Text(NSLocalizedString("Each fires once per episode and clears when the rate slows.", comment: "DirectConnect rate footer"))) {
                Toggle(NSLocalizedString("Falling Fast", comment: "DirectConnect falling fast"), isOn: binding(\.fallingFastEnabled))
                if settings.fallingFastEnabled {
                    rateStepper(value: \.fallingRate, sign: "−")
                    soundRows(.fallingFast)
                }
                Toggle(NSLocalizedString("Rising Fast", comment: "DirectConnect rising fast"), isOn: binding(\.risingFastEnabled))
                if settings.risingFastEnabled {
                    rateStepper(value: \.risingRate, sign: "+")
                    soundRows(.risingFast)
                }
            }

            Section(header: Text(NSLocalizedString("Sensor", comment: "DirectConnect sensor alarms section"))) {
                Toggle(NSLocalizedString("Signal Loss", comment: "DirectConnect signal loss"), isOn: binding(\.signalLossEnabled))
                if settings.signalLossEnabled {
                    minutesPicker(NSLocalizedString("After no reading for", comment: "DirectConnect signal loss after"), value: \.signalLossMinutes, options: [10, 15, 20, 30, 45, 60])
                    soundRows(.signalLoss)
                }
                Toggle(NSLocalizedString("Sensor Expiring (24 h and 2 h before)", comment: "DirectConnect expiring"), isOn: binding(\.sensorExpiringEnabled))
                if settings.sensorExpiringEnabled {
                    soundRows(.sensorExpiring)
                }
                Toggle(NSLocalizedString("Sensor Ended or Failed", comment: "DirectConnect ended"), isOn: binding(\.sensorEndedEnabled))
                if settings.sensorEndedEnabled {
                    soundRows(.sensorEnded)
                }
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
        .alert(NSLocalizedString("Follow the Phone's Settings?", comment: "DirectConnect play-through off title"), isPresented: Binding(
            get: { confirmPlayThroughOff != nil },
            set: { if !$0 { confirmPlayThroughOff = nil } })) {
            Button(NSLocalizedString("Turn Off", comment: "DirectConnect play-through off confirm"), role: .destructive) {
                if let kind = confirmPlayThroughOff { update { $0.playThrough.remove(kind) } }
                confirmPlayThroughOff = nil
            }
            Button(NSLocalizedString("Keep On", comment: "DirectConnect play-through keep"), role: .cancel) { confirmPlayThroughOff = nil }
        } message: {
            Text(NSLocalizedString("With the phone on silent, in a Focus, or with Loop alerts muted, this alarm will make no sound.", comment: "DirectConnect play-through off message"))
        }
        .onDisappear {
            if testingKind != nil {
                DirectConnect_AlarmPlayer.shared.stop()
                testingKind = nil
            }
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

    // MARK: - Sounds

    private static let testSeconds: TimeInterval = 6

    @ViewBuilder
    private func soundRows(_ kind: DirectConnect_AlarmKind) -> some View {
        let urgent = DirectConnect_AlarmSound.urgentKinds.contains(kind)
        NavigationLink(destination: DirectConnect_SoundListView(
            kind: kind,
            settings: settings,
            select: { sound in update { $0.sounds[kind] = sound } },
            setVolume: { volume in update { $0.volumes[kind] = volume } })) {
            HStack {
                Text(NSLocalizedString("Sound", comment: "DirectConnect alarm sound picker"))
                Spacer()
                Text(String(format: NSLocalizedString("%1$@, %2$d%%", comment: "DirectConnect alarm sound and volume (1: sound name, 2: volume percent)"),
                            settings.sound(for: kind).displayName, Int((settings.volume(for: kind) * 100).rounded())))
                    .foregroundColor(.secondary)
            }
        }
        if settings.sound(for: kind) != DirectConnect_AlarmSound.none {
            Toggle(NSLocalizedString("Play Through Silent", comment: "DirectConnect play alarm through silent, Focus and mute"), isOn: Binding(
                get: { settings.playThrough.contains(kind) },
                set: { on in
                    if on {
                        update { $0.playThrough.insert(kind) }
                    } else if urgent {
                        confirmPlayThroughOff = kind
                    } else {
                        update { $0.playThrough.remove(kind) }
                    }
                }))
        }
        Button(testingKind == kind
               ? NSLocalizedString("Stop Test", comment: "DirectConnect stop alarm sound test")
               : NSLocalizedString("Test Sound", comment: "DirectConnect test alarm sound")) {
            testSound(kind)
        }
        .disabled(settings.sound(for: kind) == DirectConnect_AlarmSound.none)
    }

    /// Plays the alarm exactly as it would sound now (same silent-switch and volume rules),
    /// for a few seconds.
    private func testSound(_ kind: DirectConnect_AlarmKind) {
        let player = DirectConnect_AlarmPlayer.shared
        if testingKind == kind {
            player.stop()
            testingKind = nil
            return
        }
        // A test ignores Loop's Mute Alerts so the user can always hear the choice.
        guard let playback = DirectConnect_AlarmPlayback.for(kind, settings: settings, loopAlertsMuted: false) else { return }
        player.play(playback, kind: kind, testSeconds: Self.testSeconds)
        testingKind = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.testSeconds) {
            if testingKind == kind { testingKind = nil }
        }
    }

    private func minutesPicker(_ label: String, value keyPath: WritableKeyPath<DirectConnect_AlarmSettings, Double>, options: [Double]) -> some View {
        Picker(label, selection: Binding(get: { settings[keyPath: keyPath] }, set: { v in update { $0[keyPath: keyPath] = v } })) {
            ForEach(options, id: \.self) { minutes in
                Text(String(format: NSLocalizedString("%.0f min", comment: "DirectConnect minutes option (1: minutes)"), minutes)).tag(minutes)
            }
        }
    }
}

/// Sound choices for one alarm. As in iOS Settings → Sounds, tapping a sound selects it and plays
/// it at once, and the list stays open so the next sound is one tap away.
private struct DirectConnect_SoundListView: View {
    let kind: DirectConnect_AlarmKind
    let settings: DirectConnect_AlarmSettings
    let select: (DirectConnect_AlarmSound) -> Void
    let setVolume: (Double) -> Void

    @State private var selected: DirectConnect_AlarmSound?
    @State private var volume = DirectConnect_AlarmSettings.defaultVolume

    private static let previewSeconds: TimeInterval = 6

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("Volume", comment: "DirectConnect alarm volume section")),
                    footer: Text(NSLocalizedString("Loop sets the phone's volume to this level while the alarm sounds, then puts it back.", comment: "DirectConnect alarm volume footer"))) {
                HStack {
                    Image(systemName: "speaker.fill").foregroundColor(.secondary)
                    Slider(value: $volume, in: DirectConnect_AlarmSettings.volumeRange, step: 0.05, onEditingChanged: { editing in
                        if !editing {
                            setVolume(volume)
                            preview(selected ?? settings.sound(for: kind))
                        }
                    })
                    Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary)
                    Text("\(Int((volume * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .onChange(of: volume) { DirectConnect_AlarmPlayer.shared.changeVolume(to: $0) }
            }
            Section(header: Text(NSLocalizedString("Loop", comment: "DirectConnect alarm sounds generated by Loop"))) {
                ForEach(DirectConnect_AlarmSound.generated, id: \.self, content: row)
            }
            Section(header: Text(NSLocalizedString("xDrip4iOS", comment: "DirectConnect alarm sounds from xDrip4iOS"))) {
                ForEach(DirectConnect_AlarmSound.xDrip, id: \.self, content: row)
            }
            if !DirectConnect_AlarmSound.urgentKinds.contains(kind) {
                Section {
                    row(DirectConnect_AlarmSound.none)
                }
            }
        }
        .navigationTitle(NSLocalizedString("Sound", comment: "DirectConnect alarm sound list title"))
        .onAppear {
            selected = settings.sound(for: kind)
            volume = settings.volume(for: kind)
        }
        .onDisappear { DirectConnect_AlarmPlayer.shared.stop() }
    }

    private func row(_ sound: DirectConnect_AlarmSound) -> some View {
        Button {
            choose(sound)
        } label: {
            HStack {
                Text(sound.displayName).foregroundColor(.primary)
                Spacer()
                if sound == (selected ?? settings.sound(for: kind)) {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
        }
    }

    private func choose(_ sound: DirectConnect_AlarmSound) {
        selected = sound
        select(sound)
        preview(sound)
    }

    private func preview(_ sound: DirectConnect_AlarmSound) {
        let player = DirectConnect_AlarmPlayer.shared
        var chosen = settings
        chosen.sounds[kind] = sound
        chosen.volumes[kind] = volume
        // Previews use the alarm's own silent-switch and volume rules, like Test Sound, and ignore
        // Loop's Mute Alerts so every choice can be heard.
        guard let playback = DirectConnect_AlarmPlayback.for(kind, settings: chosen, loopAlertsMuted: false) else {
            player.stop()
            return
        }
        player.play(playback, kind: kind, testSeconds: Self.previewSeconds)
    }
}
