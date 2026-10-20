//
//  DirectConnect_AlarmSettings.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — User-configurable glucose alarm settings.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import UIKit

/// Every alarm DirectConnect can raise. Raw values double as LoopKit alert identifiers and
/// as keys in `DirectConnect_AlarmState`, so they must never be renamed.
enum DirectConnect_AlarmKind: String, CaseIterable, Codable {
    case urgentLow
    case low
    case high
    case risingFast
    case fallingFast
    case signalLoss
    case sensorExpiring
    case sensorEnded
}

/// Alarm thresholds, repeat intervals and switches. Glucose values are mg/dL; rates are
/// mg/dL per minute (positive for both rising and falling); durations are minutes.
struct DirectConnect_AlarmSettings: Equatable {
    var urgentLowEnabled: Bool
    var lowEnabled: Bool
    var highEnabled: Bool
    var risingFastEnabled: Bool
    var fallingFastEnabled: Bool
    var signalLossEnabled: Bool
    var sensorExpiringEnabled: Bool
    var sensorEndedEnabled: Bool

    var urgentLowThreshold: Double
    var lowThreshold: Double
    var highThreshold: Double
    var risingRate: Double
    var fallingRate: Double
    var signalLossMinutes: Double

    var urgentLowRepeatMinutes: Double
    var lowRepeatMinutes: Double
    var highRepeatMinutes: Double

    /// Sound per alarm; a missing entry means that alarm's default sound.
    var sounds: [DirectConnect_AlarmKind: DirectConnect_AlarmSound] = [:]
    /// Alarms that play at full volume through the silent switch, a Focus and Loop's Mute
    /// Alerts. The others follow the phone's settings.
    var playThrough: Set<DirectConnect_AlarmKind> = DirectConnect_AlarmSound.urgentKinds

    /// Loudness per alarm, 0.1–1. While an alarm sounds Loop sets the phone's media volume to
    /// this level and restores it afterwards, so the alarm does not depend on the volume the
    /// phone was left at. A missing entry means `defaultVolume`.
    var volumes: [DirectConnect_AlarmKind: Double] = [:]

    static let defaultVolume = 0.4
    static let volumeRange = 0.1...1.0

    func sound(for kind: DirectConnect_AlarmKind) -> DirectConnect_AlarmSound {
        sounds[kind] ?? DirectConnect_AlarmSound.defaultSound(for: kind)
    }

    func volume(for kind: DirectConnect_AlarmKind) -> Double {
        (volumes[kind] ?? Self.defaultVolume).dcClamped(to: Self.volumeRange)
    }

    static let urgentLowRange = 40.0...70.0
    static let lowRange = 55.0...100.0
    static let highRange = 120.0...400.0
    static let rateRange = 2.0...5.0
    static let signalLossRange = 10.0...60.0
    static let urgentLowRepeatRange = 5.0...30.0
    static let lowRepeatRange = 5.0...60.0
    static let highRepeatRange = 15.0...240.0

    // Minimum gaps keep the three glucose thresholds from overlapping, so a single reading
    // can never be "urgent low" and "high" at once.
    private static let urgentLowToLowGap = 5.0
    private static let lowToHighGap = 20.0

    static let defaults = DirectConnect_AlarmSettings(
        urgentLowEnabled: true,
        lowEnabled: true,
        highEnabled: true,
        risingFastEnabled: false,
        fallingFastEnabled: true,
        signalLossEnabled: true,
        sensorExpiringEnabled: true,
        sensorEndedEnabled: true,
        urgentLowThreshold: 55,
        lowThreshold: 70,
        highThreshold: 250,
        risingRate: 3,
        fallingRate: 3,
        signalLossMinutes: 20,
        urgentLowRepeatMinutes: 5,
        lowRepeatMinutes: 15,
        highRepeatMinutes: 60
    )

    /// Returns a copy with every value inside its allowed range and the thresholds ordered
    /// urgent low < low < high.
    func normalized() -> DirectConnect_AlarmSettings {
        var s = self
        s.urgentLowThreshold = s.urgentLowThreshold.dcClamped(to: Self.urgentLowRange)
        s.lowThreshold = s.lowThreshold.dcClamped(to: Self.lowRange)
        s.highThreshold = s.highThreshold.dcClamped(to: Self.highRange)
        s.risingRate = s.risingRate.dcClamped(to: Self.rateRange)
        s.fallingRate = s.fallingRate.dcClamped(to: Self.rateRange)
        s.signalLossMinutes = s.signalLossMinutes.dcClamped(to: Self.signalLossRange)
        s.urgentLowRepeatMinutes = s.urgentLowRepeatMinutes.dcClamped(to: Self.urgentLowRepeatRange)
        s.lowRepeatMinutes = s.lowRepeatMinutes.dcClamped(to: Self.lowRepeatRange)
        s.highRepeatMinutes = s.highRepeatMinutes.dcClamped(to: Self.highRepeatRange)

        s.volumes = s.volumes.mapValues { $0.dcClamped(to: Self.volumeRange) }
        for kind in DirectConnect_AlarmSound.urgentKinds where s.sounds[kind] == DirectConnect_AlarmSound.none {
            s.sounds[kind] = nil
        }

        if s.lowThreshold > s.highThreshold - Self.lowToHighGap {
            s.lowThreshold = max(Self.lowRange.lowerBound, s.highThreshold - Self.lowToHighGap)
        }
        if s.urgentLowThreshold > s.lowThreshold - Self.urgentLowToLowGap {
            s.urgentLowThreshold = max(Self.urgentLowRange.lowerBound, s.lowThreshold - Self.urgentLowToLowGap)
        }
        return s
    }

    // MARK: - Persistence

    private static let keyPrefix = "com.loopkit.Loop.directConnect.alarm."

    static func load(from defaults: UserDefaults) -> DirectConnect_AlarmSettings {
        let d = Self.defaults
        func bool(_ name: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: keyPrefix + name) as? Bool ?? fallback
        }
        func double(_ name: String, _ fallback: Double) -> Double {
            defaults.object(forKey: keyPrefix + name) as? Double ?? fallback
        }
        return DirectConnect_AlarmSettings(
            urgentLowEnabled: bool("urgentLowEnabled", d.urgentLowEnabled),
            lowEnabled: bool("lowEnabled", d.lowEnabled),
            highEnabled: bool("highEnabled", d.highEnabled),
            risingFastEnabled: bool("risingFastEnabled", d.risingFastEnabled),
            fallingFastEnabled: bool("fallingFastEnabled", d.fallingFastEnabled),
            signalLossEnabled: bool("signalLossEnabled", d.signalLossEnabled),
            sensorExpiringEnabled: bool("sensorExpiringEnabled", d.sensorExpiringEnabled),
            sensorEndedEnabled: bool("sensorEndedEnabled", d.sensorEndedEnabled),
            urgentLowThreshold: double("urgentLowThreshold", d.urgentLowThreshold),
            lowThreshold: double("lowThreshold", d.lowThreshold),
            highThreshold: double("highThreshold", d.highThreshold),
            risingRate: double("risingRate", d.risingRate),
            fallingRate: double("fallingRate", d.fallingRate),
            signalLossMinutes: double("signalLossMinutes", d.signalLossMinutes),
            urgentLowRepeatMinutes: double("urgentLowRepeatMinutes", d.urgentLowRepeatMinutes),
            lowRepeatMinutes: double("lowRepeatMinutes", d.lowRepeatMinutes),
            highRepeatMinutes: double("highRepeatMinutes", d.highRepeatMinutes),
            sounds: loadSounds(from: defaults),
            playThrough: defaults.stringArray(forKey: keyPrefix + "playThrough").map { Set($0.compactMap(DirectConnect_AlarmKind.init(rawValue:))) } ?? d.playThrough,
            volumes: loadVolumes(from: defaults)
        ).normalized()
    }

    private static func loadVolumes(from defaults: UserDefaults) -> [DirectConnect_AlarmKind: Double] {
        let raw = defaults.dictionary(forKey: keyPrefix + "volumes") as? [String: Double] ?? [:]
        var volumes = [DirectConnect_AlarmKind: Double]()
        for (kind, volume) in raw {
            if let kind = DirectConnect_AlarmKind(rawValue: kind) {
                volumes[kind] = volume
            }
        }
        return volumes
    }

    private static func loadSounds(from defaults: UserDefaults) -> [DirectConnect_AlarmKind: DirectConnect_AlarmSound] {
        let raw = defaults.dictionary(forKey: keyPrefix + "sounds") as? [String: String] ?? [:]
        var sounds = [DirectConnect_AlarmKind: DirectConnect_AlarmSound]()
        for (kind, sound) in raw {
            if let kind = DirectConnect_AlarmKind(rawValue: kind), let sound = DirectConnect_AlarmSound(rawValue: sound) {
                sounds[kind] = sound
            }
        }
        return sounds
    }

    func save(to defaults: UserDefaults) {
        let s = normalized()
        let values: [String: Any] = [
            "urgentLowEnabled": s.urgentLowEnabled,
            "lowEnabled": s.lowEnabled,
            "highEnabled": s.highEnabled,
            "risingFastEnabled": s.risingFastEnabled,
            "fallingFastEnabled": s.fallingFastEnabled,
            "signalLossEnabled": s.signalLossEnabled,
            "sensorExpiringEnabled": s.sensorExpiringEnabled,
            "sensorEndedEnabled": s.sensorEndedEnabled,
            "urgentLowThreshold": s.urgentLowThreshold,
            "lowThreshold": s.lowThreshold,
            "highThreshold": s.highThreshold,
            "risingRate": s.risingRate,
            "fallingRate": s.fallingRate,
            "signalLossMinutes": s.signalLossMinutes,
            "urgentLowRepeatMinutes": s.urgentLowRepeatMinutes,
            "lowRepeatMinutes": s.lowRepeatMinutes,
            "highRepeatMinutes": s.highRepeatMinutes,
            "sounds": Dictionary(uniqueKeysWithValues: s.sounds.map { ($0.key.rawValue, $0.value.rawValue) }),
            "playThrough": s.playThrough.map(\.rawValue).sorted(),
            "volumes": Dictionary(uniqueKeysWithValues: s.volumes.map { ($0.key.rawValue, $0.value) }),
        ]
        for (name, value) in values {
            defaults.set(value, forKey: Self.keyPrefix + name)
        }
    }
}

// MARK: - Alarm sounds

/// A sound Loop plays itself while an alarm is active: one of four tones generated in code, or
/// one of the xDrip4iOS sounds stored as data assets in `DefaultAssets.xcassets/DirectConnectSounds`
/// (data assets need no Xcode project entries, so the installer only copies files).
struct DirectConnect_AlarmSound: Hashable {
    let rawValue: String

    private init(_ rawValue: String) { self.rawValue = rawValue }

    init?(rawValue: String) {
        guard let sound = Self.allChoices.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = sound
    }

    static let siren = DirectConnect_AlarmSound("siren")
    static let alarmClock = DirectConnect_AlarmSound("alarmClock")
    static let pulse = DirectConnect_AlarmSound("pulse")
    static let chime = DirectConnect_AlarmSound("chime")
    static let none = DirectConnect_AlarmSound("none")

    static let generated: [DirectConnect_AlarmSound] = [.siren, .alarmClock, .pulse, .chime]
    static let xDrip: [DirectConnect_AlarmSound] = xDripSounds.map { DirectConnect_AlarmSound($0.asset) }
    static let allChoices: [DirectConnect_AlarmSound] = generated + xDrip + [.none]

    /// Asset name and display name, in xDrip4iOS's order (its `ConstantsSounds.swift`). Files
    /// from https://github.com/JohanDegraeve/xdripswift (GPL-3.0), commit c268542, converted to AAC.
    private static let xDripSounds: [(asset: String, name: String)] = [
        ("DirectConnectSound_betterwakeup", "Better Wake Up"),
        ("DirectConnectSound_bruteforce", "Brute Force"),
        ("DirectConnectSound_modern2", "Modern Alert 2"),
        ("DirectConnectSound_modernalarm", "Modern Alert"),
        ("DirectConnectSound_shorthigh1", "Short High 1"),
        ("DirectConnectSound_shorthigh2", "Short High 2"),
        ("DirectConnectSound_shorthigh3", "Short High 3"),
        ("DirectConnectSound_shorthigh4", "Short High 4"),
        ("DirectConnectSound_spaceship", "Space Ship"),
        ("DirectConnectSound_xdripalert", "xDrip Alert"),
        ("DirectConnectSound_Alarm_Buzzer", "Alarm Buzzer"),
        ("DirectConnectSound_Alarm_Clock", "Alarm Clock"),
        ("DirectConnectSound_Alert_Tone_Busy", "Alert Tone Busy"),
        ("DirectConnectSound_Alert_Tone_Ringtone_1", "Alert Tone Ringtone 1"),
        ("DirectConnectSound_Alert_Tone_Ringtone_2", "Alert Tone Ringtone 2"),
        ("DirectConnectSound_Alien_Siren", "Alien Siren"),
        ("DirectConnectSound_Ambulance", "Ambulance"),
        ("DirectConnectSound_Analog_Watch_Alarm", "Analog Watch Alarm"),
        ("DirectConnectSound_Big_Clock_Ticking", "Big Clock Ticking"),
        ("DirectConnectSound_Burglar_Alarm_Siren_1", "Burglar Alarm Siren 1"),
        ("DirectConnectSound_Burglar_Alarm_Siren_2", "Burglar Alarm Siren 2"),
        ("DirectConnectSound_Cartoon_Ascend_Climb_Sneaky", "Cartoon Ascend Climb Sneaky"),
        ("DirectConnectSound_Cartoon_Ascend_Then_Descend", "Cartoon Ascend Then Descend"),
        ("DirectConnectSound_Cartoon_Bounce_To_Ceiling", "Cartoon Bounce To Ceiling"),
        ("DirectConnectSound_Cartoon_Dreamy_Glissando_Harp", "Cartoon Dreamy Glissando Harp"),
        ("DirectConnectSound_Cartoon_Fail_Strings_Trumpet", "Cartoon Fail Strings Trumpet"),
        ("DirectConnectSound_Cartoon_Machine_Clumsy_Loop", "Cartoon Machine Clumsy Loop"),
        ("DirectConnectSound_Cartoon_Siren", "Cartoon Siren"),
        ("DirectConnectSound_Cartoon_Tip_Toe_Sneaky_Walk", "Cartoon Tip Toe Sneaky Walk"),
        ("DirectConnectSound_Cartoon_Uh_Oh", "Cartoon Uh Oh"),
        ("DirectConnectSound_Cartoon_Villain_Horns", "Cartoon Villain Horns"),
        ("DirectConnectSound_Cell_Phone_Ring_Tone", "Cell Phone Ring Tone"),
        ("DirectConnectSound_Chimes_Glassy", "Chimes Glassy"),
        ("DirectConnectSound_Computer_Magic", "Computer Magic"),
        ("DirectConnectSound_CSFX_2_Alarm", "CSFX2 Alarm"),
        ("DirectConnectSound_Cuckoo_Clock", "Cuckoo Clock"),
        ("DirectConnectSound_Dhol_Shuffleloop", "Dhol Shuffleloop"),
        ("DirectConnectSound_Discreet", "Discreet"),
        ("DirectConnectSound_Early_Sunrise", "Early Sunrise"),
        ("DirectConnectSound_Emergency_Alarm_Carbon_Monoxide", "Emergency Alarm Carbon Monoxide"),
        ("DirectConnectSound_Emergency_Alarm_Siren", "Emergency Alarm Siren"),
        ("DirectConnectSound_Emergency_Alarm", "Emergency Alarm"),
        ("DirectConnectSound_Ending_Reached", "Ending Reached"),
        ("DirectConnectSound_Fly", "Fly"),
        ("DirectConnectSound_Ghost_Hover", "Ghost Hover"),
        ("DirectConnectSound_Good_Morning", "Good Morning"),
        ("DirectConnectSound_Hell_Yeah_Somewhat_Calmer", "Hell Yeah Somewhat Calmer"),
        ("DirectConnectSound_In_A_Hurry", "In A Hurry"),
        ("DirectConnectSound_Indeed", "Indeed"),
        ("DirectConnectSound_Insistently", "Insistently"),
        ("DirectConnectSound_Jingle_All_The_Way", "Jingle All The Way"),
        ("DirectConnectSound_Laser_Shoot", "Laser Shoot"),
        ("DirectConnectSound_Machine_Charge", "Machine Charge"),
        ("DirectConnectSound_Magical_Twinkle", "Magical Twinkle"),
        ("DirectConnectSound_Marching_Heavy_Footed_Fat_Elephants", "Marching Heavy Footed Fat Elephants"),
        ("DirectConnectSound_Marimba_Descend", "Marimba Descend"),
        ("DirectConnectSound_Marimba_Flutter_or_Shake", "Marimba Flutter or Shake"),
        ("DirectConnectSound_Martian_Gun", "Martian Gun"),
        ("DirectConnectSound_Martian_Scanner", "Martian Scanner"),
        ("DirectConnectSound_Metallic", "Metallic"),
        ("DirectConnectSound_Nightguard", "Nightguard"),
        ("DirectConnectSound_Not_Kiddin", "Not Kiddin"),
        ("DirectConnectSound_Open_Your_Eyes_And_See", "Open Your Eyes And See"),
        ("DirectConnectSound_Orchestral_Horns", "Orchestral Horns"),
        ("DirectConnectSound_Oringz", "Oringz"),
        ("DirectConnectSound_Pager_Beeps", "Pager Beeps"),
        ("DirectConnectSound_Remembers_Me_Of_Asia", "Remembers Me Of Asia"),
        ("DirectConnectSound_Rise_And_Shine", "Rise And Shine"),
        ("DirectConnectSound_Rush", "Rush"),
        ("DirectConnectSound_Sci_Fi_Air_Raid_Alarm", "SciFi Air Raid Alarm"),
        ("DirectConnectSound_Sci_Fi_Alarm_Loop_1", "SciFi Alarm Loop 1"),
        ("DirectConnectSound_Sci_Fi_Alarm_Loop_2", "SciFi Alarm Loop 2"),
        ("DirectConnectSound_Sci_Fi_Alarm_Loop_3", "SciFi Alarm Loop 3"),
        ("DirectConnectSound_Sci_Fi_Alarm_Loop_4", "SciFi Alarm Loop 4"),
        ("DirectConnectSound_Sci_Fi_Alarm", "SciFi Alarm"),
        ("DirectConnectSound_Sci_Fi_Computer_Console_Alarm", "SciFi Computer Console Alarm"),
        ("DirectConnectSound_Sci_Fi_Console_Alarm", "SciFi Console Alarm"),
        ("DirectConnectSound_Sci_Fi_Eerie_Alarm", "SciFi Eerie Alarm"),
        ("DirectConnectSound_Sci_Fi_Engine_Shut_Down", "SciFi Engine Shut Down"),
        ("DirectConnectSound_Sci_Fi_Incoming_Message_Alert", "SciFi Incoming Message Alert"),
        ("DirectConnectSound_Sci_Fi_Spaceship_Message", "SciFi Spaceship Message"),
        ("DirectConnectSound_Sci_Fi_Spaceship_Warm_Up", "SciFi Spaceship Warm Up"),
        ("DirectConnectSound_Sci_Fi_Warning", "SciFi Warning"),
        ("DirectConnectSound_Signature_Corporate", "Signature Corporate"),
        ("DirectConnectSound_Siri_Alert_Calibration_Needed", "Siri Alert Calibration Needed"),
        ("DirectConnectSound_Siri_Alert_Device_Muted", "Siri Alert Device Muted"),
        ("DirectConnectSound_Siri_Alert_Glucose_Dropping_Fast", "Siri Alert Glucose Dropping Fast"),
        ("DirectConnectSound_Siri_Alert_Glucose_Rising_Fast", "Siri Alert Glucose Rising Fast"),
        ("DirectConnectSound_Siri_Alert_High_Glucose", "Siri Alert High Glucose"),
        ("DirectConnectSound_Siri_Alert_Low_Glucose", "Siri Alert Low Glucose"),
        ("DirectConnectSound_Siri_Alert_Missed_Readings", "Siri Alert Missed Readings"),
        ("DirectConnectSound_Siri_Alert_Transmitter_Battery_Low", "Siri Alert Transmitter Battery Low"),
        ("DirectConnectSound_Siri_Alert_Urgent_High_Glucose", "Siri Alert Urgent High Glucose"),
        ("DirectConnectSound_Siri_Alert_Urgent_Low_Glucose", "Siri Alert Urgent Low Glucose"),
        ("DirectConnectSound_Siri_Calibration_Needed", "Siri Calibration Needed"),
        ("DirectConnectSound_Siri_Device_Muted", "Siri Device Muted"),
        ("DirectConnectSound_Siri_Glucose_Dropping_Fast", "Siri Glucose Dropping Fast"),
        ("DirectConnectSound_Siri_Glucose_Rising_Fast", "Siri Glucose Rising Fast"),
        ("DirectConnectSound_Siri_High_Glucose", "Siri High Glucose"),
        ("DirectConnectSound_Siri_Low_Glucose", "Siri Low Glucose"),
        ("DirectConnectSound_Siri_Missed_Readings", "Siri Missed Readings"),
        ("DirectConnectSound_Siri_Transmitter_Battery_Low", "Siri Transmitter Battery Low"),
        ("DirectConnectSound_Siri_Urgent_High_Glucose", "Siri Urgent High Glucose"),
        ("DirectConnectSound_Siri_Urgent_Low_Glucose", "Siri Urgent Low Glucose"),
        ("DirectConnectSound_Soft_Marimba_Pad_Positive", "Soft Marimba Pad Positive"),
        ("DirectConnectSound_Soft_Warm_Airy_Optimistic", "Soft Warm Airy Optimistic"),
        ("DirectConnectSound_Soft_Warm_Airy_Reassuring", "Soft Warm Airy Reassuring"),
        ("DirectConnectSound_Store_Door_Chime", "Store Door Chime"),
        ("DirectConnectSound_Sunny", "Sunny"),
        ("DirectConnectSound_Thunder_Sound_FX", "Thunder Sound FX"),
        ("DirectConnectSound_Time_Has_Come", "Time Has Come"),
        ("DirectConnectSound_Tornado_Siren", "Tornado Siren"),
        ("DirectConnectSound_Two_Turtle_Doves", "Two Turtle Doves"),
        ("DirectConnectSound_Unpaved", "Unpaved"),
        ("DirectConnectSound_Wake_Up_Will_You", "Wake Up Will You"),
        ("DirectConnectSound_Win_Gain", "Win Gain"),
        ("DirectConnectSound_Wrong_Answer", "Wrong Answer"),
    ]

    var isXDrip: Bool { rawValue.hasPrefix("DirectConnectSound_") }

    /// Alarms that repeat until acknowledged, cannot be set to no sound, and play through the
    /// phone's settings by default. On 2026-10-18 six Urgent Low alarms fired overnight and none
    /// were heard.
    static let urgentKinds: Set<DirectConnect_AlarmKind> = [.urgentLow, .fallingFast]

    static let sampleRate = 44_100.0

    static func defaultSound(for kind: DirectConnect_AlarmKind) -> DirectConnect_AlarmSound {
        switch kind {
        case .urgentLow: return .siren
        case .low: return .alarmClock
        case .fallingFast, .signalLoss: return .pulse
        case .high, .risingFast, .sensorExpiring, .sensorEnded: return .chime
        }
    }

    var displayName: String {
        switch self {
        case .siren: return NSLocalizedString("Siren", comment: "DirectConnect alarm sound")
        case .alarmClock: return NSLocalizedString("Alarm Clock", comment: "DirectConnect alarm sound")
        case .pulse: return NSLocalizedString("Pulse", comment: "DirectConnect alarm sound")
        case .chime: return NSLocalizedString("Chime", comment: "DirectConnect alarm sound")
        case .none: return NSLocalizedString("None (vibrate only)", comment: "DirectConnect alarm sound")
        default: return Self.xDripSounds.first { $0.asset == rawValue }?.name ?? rawValue
        }
    }

    /// The sound as playable file data (WAV for generated tones, AAC CAF for xDrip sounds).
    func audioData() -> Data? {
        if isXDrip {
            return NSDataAsset(name: rawValue)?.data
        }
        let wav = wavData()
        return wav.count > 44 ? wav : nil
    }

    /// One cycle of the sound as 16-bit mono samples; the player loops it.
    func samples() -> [Int16] {
        var out = [Int16]()
        func tone(_ seconds: Double, _ frequency: (Double) -> Double, amplitude: (Double) -> Double = { _ in 0.9 }) {
            let count = Int(seconds * Self.sampleRate)
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / Self.sampleRate
                phase += 2 * .pi * frequency(t) / Self.sampleRate
                // 5 ms fade at each end so tones start and stop without a click.
                let edge = min(t, seconds - t) / 0.005
                out.append(Int16(sin(phase) * amplitude(t) * min(1, edge) * Double(Int16.max)))
            }
        }
        func silence(_ seconds: Double) {
            out.append(contentsOf: repeatElement(0, count: Int(seconds * Self.sampleRate)))
        }

        switch self {
        case .siren:
            tone(2.0) { t in t < 1 ? 700 + 800 * t : 1500 - 800 * (t - 1) }
        case .alarmClock:
            for _ in 0..<4 { tone(0.12) { _ in 1200 }; silence(0.08) }
            silence(0.6)
        case .pulse:
            for i in 0..<8 { tone(0.15) { _ in i % 2 == 0 ? 880 : 1320 } }
        case .chime:
            tone(0.6, { _ in 1046.5 }, amplitude: { t in 0.9 * exp(-3 * t) })
            tone(0.9, { _ in 784 }, amplitude: { t in 0.9 * exp(-3 * t) })
        default:
            break
        }
        return out
    }

    /// The samples as a 16-bit mono PCM WAV file, which AVAudioPlayer can play from memory.
    func wavData() -> Data {
        let samples = samples()
        let dataBytes = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(Self.sampleRate)); append(UInt32(Self.sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataBytes)
        samples.forEach { append($0) }
        return data
    }
}

/// How Loop plays an alarm's sound. Loop plays it itself, because Apple only lets approved
/// apps send notifications that sound on silent, and Loop is not approved.
struct DirectConnect_AlarmPlayback: Equatable {
    let sound: DirectConnect_AlarmSound
    let playsThroughSilent: Bool
    let repeatsUntilAcknowledged: Bool
    /// 0.1–1; Loop sets the phone's media volume to this while the sound plays.
    let volume: Double

    /// nil means Loop plays no sound for this alarm (the notification still appears).
    static func `for`(_ kind: DirectConnect_AlarmKind, settings: DirectConnect_AlarmSettings, loopAlertsMuted: Bool) -> DirectConnect_AlarmPlayback? {
        let s = settings.normalized()
        let sound = s.sound(for: kind)
        let through = s.playThrough.contains(kind)
        guard sound != DirectConnect_AlarmSound.none, through || !loopAlertsMuted else { return nil }
        return DirectConnect_AlarmPlayback(sound: sound,
                                           playsThroughSilent: through,
                                           repeatsUntilAcknowledged: DirectConnect_AlarmSound.urgentKinds.contains(kind),
                                           volume: s.volume(for: kind))
    }
}

extension Double {
    func dcClamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
