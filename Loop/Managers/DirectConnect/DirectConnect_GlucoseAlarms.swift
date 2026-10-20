//
//  DirectConnect_GlucoseAlarms.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Glucose, rate, signal and sensor-lifetime alarm evaluation, and the
//  player that sounds alarms through the silent switch.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import AVFoundation
import Foundation
import HealthKit
import LoopKit
import MediaPlayer
import UIKit

struct DirectConnect_AlarmReading {
    let date: Date
    let mgdl: Double
    /// mg/dL per minute; nil when the sensor reports no trend.
    let trendRate: Double?
}

/// When each active alarm last fired. An entry exists only while the alarm is active, so
/// "has an entry" doubles as "is active". Persisted with the CGM manager state so repeat
/// timing survives app restarts.
struct DirectConnect_AlarmState: Codable, Equatable {
    var lastFired: [String: Date] = [:]

    // Separate markers so the 24 h and 2 h expiry warnings each fire once.
    fileprivate static let expiring24Key = "sensorExpiring24"
    fileprivate static let expiring2Key = "sensorExpiring2"
}

enum DirectConnect_AlarmAction: Equatable {
    case issue(DirectConnect_AlarmKind, value: Double?)
    case retract(DirectConnect_AlarmKind)
}

/// What the CGM manager does with Loop's alert system and the alarm player, in order.
enum DirectConnect_AlarmStep: Equatable {
    case retractAlert(DirectConnect_AlarmKind)
    case issueAlert(DirectConnect_AlarmKind, value: Double?)
    case playSound(DirectConnect_AlarmKind)
    case stopSound(DirectConnect_AlarmKind)
}

/// Pure functions: (inputs, settings, state) → actions. The CGM manager turns actions into
/// LoopKit alerts, which keeps every rule unit-testable.
enum DirectConnect_GlucoseAlarms {

    // MARK: - Glucose and rate

    static func evaluate(reading: DirectConnect_AlarmReading, settings: DirectConnect_AlarmSettings, state: inout DirectConnect_AlarmState) -> [DirectConnect_AlarmAction] {
        let s = settings.normalized()
        var actions = [DirectConnect_AlarmAction]()

        let isUrgentLow = s.urgentLowEnabled && reading.mgdl <= s.urgentLowThreshold
        // Urgent low takes precedence: the plain low alarm is withdrawn while urgent low is active.
        let isLow = s.lowEnabled && !isUrgentLow && reading.mgdl < s.lowThreshold
        let isHigh = s.highEnabled && reading.mgdl > s.highThreshold
        let isFalling = s.fallingFastEnabled && (reading.trendRate.map { $0 <= -s.fallingRate } ?? false)
        let isRising = s.risingFastEnabled && (reading.trendRate.map { $0 >= s.risingRate } ?? false)

        repeating(.urgentLow, active: isUrgentLow, every: s.urgentLowRepeatMinutes, reading: reading, state: &state, into: &actions)
        repeating(.low, active: isLow, every: s.lowRepeatMinutes, reading: reading, state: &state, into: &actions)
        repeating(.high, active: isHigh, every: s.highRepeatMinutes, reading: reading, state: &state, into: &actions)
        oncePerEpisode(.fallingFast, active: isFalling, at: reading.date, value: reading.mgdl, state: &state, into: &actions)
        oncePerEpisode(.risingFast, active: isRising, at: reading.date, value: reading.mgdl, state: &state, into: &actions)
        return actions
    }

    /// Every issue first retracts the alarm's earlier alert. Loop's AlertStore marks only the
    /// latest alert with an identifier as retracted, so without this a repeated alarm leaves its
    /// earlier alerts open and Loop shows them again at every launch.
    static func steps(for actions: [DirectConnect_AlarmAction]) -> [DirectConnect_AlarmStep] {
        actions.flatMap { action -> [DirectConnect_AlarmStep] in
            switch action {
            case let .issue(kind, value): return [.retractAlert(kind), .issueAlert(kind, value: value), .playSound(kind)]
            case let .retract(kind): return [.retractAlert(kind), .stopSound(kind)]
            }
        }
    }

    // MARK: - Signal loss

    static func evaluateSignal(lastReading: Date?, now: Date, settings: DirectConnect_AlarmSettings, state: inout DirectConnect_AlarmState) -> [DirectConnect_AlarmAction] {
        let s = settings.normalized()
        var actions = [DirectConnect_AlarmAction]()
        let isLost = s.signalLossEnabled
            && (lastReading.map { now.timeIntervalSince($0) >= s.signalLossMinutes * 60 } ?? false)
        oncePerEpisode(.signalLoss, active: isLost, at: now, value: nil, state: &state, into: &actions)
        return actions
    }

    // MARK: - Sensor lifetime

    static func evaluateLifetime(expiresAt: Date?, endedOrFailed: Bool, now: Date, settings: DirectConnect_AlarmSettings, state: inout DirectConnect_AlarmState) -> [DirectConnect_AlarmAction] {
        var actions = [DirectConnect_AlarmAction]()

        if let expiresAt = expiresAt, settings.sensorExpiringEnabled {
            let remaining = expiresAt.timeIntervalSince(now)
            let k24 = DirectConnect_AlarmState.expiring24Key
            let k2 = DirectConnect_AlarmState.expiring2Key
            if remaining > 24 * 3600 {
                // A new sensor: clear the markers so its own warnings can fire later.
                if state.lastFired[k24] != nil || state.lastFired[k2] != nil {
                    state.lastFired[k24] = nil
                    state.lastFired[k2] = nil
                    actions.append(.retract(.sensorExpiring))
                }
            } else if remaining > 0 {
                if remaining <= 2 * 3600, state.lastFired[k2] == nil {
                    state.lastFired[k2] = now
                    state.lastFired[k24] = state.lastFired[k24] ?? now
                    actions.append(.issue(.sensorExpiring, value: nil))
                } else if state.lastFired[k24] == nil {
                    state.lastFired[k24] = now
                    actions.append(.issue(.sensorExpiring, value: nil))
                }
            }
        }

        let isEnded = settings.sensorEndedEnabled && endedOrFailed
        oncePerEpisode(.sensorEnded, active: isEnded, at: now, value: nil, state: &state, into: &actions)
        return actions
    }

    // MARK: - Rules

    private static func repeating(_ kind: DirectConnect_AlarmKind, active: Bool, every minutes: Double, reading: DirectConnect_AlarmReading, state: inout DirectConnect_AlarmState, into actions: inout [DirectConnect_AlarmAction]) {
        let key = kind.rawValue
        if active {
            if let last = state.lastFired[key], reading.date.timeIntervalSince(last) < minutes * 60 {
                return
            }
            state.lastFired[key] = reading.date
            actions.append(.issue(kind, value: reading.mgdl))
        } else if state.lastFired.removeValue(forKey: key) != nil {
            actions.append(.retract(kind))
        }
    }

    private static func oncePerEpisode(_ kind: DirectConnect_AlarmKind, active: Bool, at date: Date, value: Double?, state: inout DirectConnect_AlarmState, into actions: inout [DirectConnect_AlarmAction]) {
        let key = kind.rawValue
        if active {
            guard state.lastFired[key] == nil else { return }
            state.lastFired[key] = date
            actions.append(.issue(kind, value: value))
        } else if state.lastFired.removeValue(forKey: key) != nil {
            actions.append(.retract(kind))
        }
    }

    // MARK: - LoopKit alerts

    static func interruptionLevel(for kind: DirectConnect_AlarmKind) -> Alert.InterruptionLevel {
        switch kind {
        case .urgentLow: return .critical
        case .low, .high, .fallingFast, .signalLoss, .sensorEnded: return .timeSensitive
        case .risingFast, .sensorExpiring: return .active
        }
    }

    static func alert(for kind: DirectConnect_AlarmKind, value: Double?, managerIdentifier: String, unit: HKUnit) -> Alert {
        let valueText = value.map { format(mgdl: $0, unit: unit) } ?? ""
        let title: String
        let body: String
        switch kind {
        case .urgentLow:
            title = NSLocalizedString("Urgent Low Glucose", comment: "DirectConnect urgent low alarm title")
            body = String(format: NSLocalizedString("Glucose is %@.", comment: "DirectConnect glucose alarm body (1: value)"), valueText)
        case .low:
            title = NSLocalizedString("Low Glucose", comment: "DirectConnect low alarm title")
            body = String(format: NSLocalizedString("Glucose is %@.", comment: "DirectConnect glucose alarm body (1: value)"), valueText)
        case .high:
            title = NSLocalizedString("High Glucose", comment: "DirectConnect high alarm title")
            body = String(format: NSLocalizedString("Glucose is %@.", comment: "DirectConnect glucose alarm body (1: value)"), valueText)
        case .risingFast:
            title = NSLocalizedString("Glucose Rising Fast", comment: "DirectConnect rising alarm title")
            body = String(format: NSLocalizedString("Glucose is %@ and rising fast.", comment: "DirectConnect rising alarm body (1: value)"), valueText)
        case .fallingFast:
            title = NSLocalizedString("Glucose Falling Fast", comment: "DirectConnect falling alarm title")
            body = String(format: NSLocalizedString("Glucose is %@ and falling fast.", comment: "DirectConnect falling alarm body (1: value)"), valueText)
        case .signalLoss:
            title = NSLocalizedString("CGM Signal Loss", comment: "DirectConnect signal loss alarm title")
            body = NSLocalizedString("Loop has not received a glucose reading from the sensor.", comment: "DirectConnect signal loss alarm body")
        case .sensorExpiring:
            title = NSLocalizedString("Sensor Expiring Soon", comment: "DirectConnect expiring alarm title")
            body = NSLocalizedString("Your sensor session is ending soon. After inserting a new sensor, open Loop → Settings → CGM → Pair New Sensor.", comment: "DirectConnect expiring alarm body")
        case .sensorEnded:
            title = NSLocalizedString("Sensor Session Ended", comment: "DirectConnect ended alarm title")
            body = NSLocalizedString("The sensor stopped providing glucose readings. Insert a new sensor, then open Loop → Settings → CGM → Pair New Sensor and enter its code.", comment: "DirectConnect ended alarm body")
        }
        let content = Alert.Content(title: title, body: body, acknowledgeActionButtonLabel: NSLocalizedString("OK", comment: "DirectConnect alarm acknowledge button"))
        return Alert(identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: kind.rawValue),
                     foregroundContent: content,
                     backgroundContent: content,
                     trigger: .immediate,
                     interruptionLevel: interruptionLevel(for: kind))
    }

    static func format(mgdl: Double, unit: HKUnit) -> String {
        if unit == .millimolesPerLiter {
            return String(format: "%.1f mmol/L", mgdl / 18.0182)
        }
        return String(format: "%.0f mg/dL", mgdl)
    }
}

// MARK: - Alarm sound player

/// Plays alarm sounds with Loop's own audio session. Loop is not approved by Apple for critical
/// notifications, so a notification alone only vibrates when the phone is on silent; playing
/// audio in the `.playback` category is not muted by the silent switch or a Focus. Loop's
/// `audio` background mode lets the sound start during a background sensor wake and keeps
/// Loop running while it plays.
final class DirectConnect_AlarmPlayer: NSObject {
    static let shared = DirectConnect_AlarmPlayer()

    private var player: AVAudioPlayer?
    private(set) var playingKind: DirectConnect_AlarmKind?
    private var playingRepeats = false
    private var volumeBeforeAlarm: Float?
    private var volumeView: MPVolumeView?
    private var testStopWork: DispatchWorkItem?

    private override init() {
        super.init()
        // Opening Loop means the user is awake and looking at the alarm.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    /// Starts the sound. Returns a line for the diagnostics log. A repeating alarm already
    /// playing is not replaced by one that plays once.
    @discardableResult
    func play(_ playback: DirectConnect_AlarmPlayback, kind: DirectConnect_AlarmKind, testSeconds: TimeInterval? = nil) -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        if player?.isPlaying == true, playingRepeats, !playback.repeatsUntilAcknowledged, testSeconds == nil {
            return "Alarm sound for \(kind.rawValue) skipped; \(playingKind?.rawValue ?? "another alarm") is sounding"
        }
        stop()
        let session = AVAudioSession.sharedInstance()
        do {
            // `.playback` ignores the silent switch; `.ambient` obeys it. Both mix with other
            // audio, which lets the session start while Loop is in the background.
            if playback.playsThroughSilent {
                try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            } else {
                try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            guard let data = playback.sound.audioData() else {
                stop()
                return "Alarm sound \(playback.sound.rawValue) for \(kind.rawValue) not found"
            }
            let player = try AVAudioPlayer(data: data, fileTypeHint: playback.sound.isXDrip ? AVFileType.caf.rawValue : AVFileType.wav.rawValue)
            // xDrip sounds run up to 30 seconds, so a non-urgent alarm plays them once; the short
            // generated tones play three times.
            player.numberOfLoops = playback.repeatsUntilAcknowledged || testSeconds != nil ? -1 : (playback.sound.isXDrip ? 0 : 2)
            player.volume = 1
            player.delegate = self
            self.player = player
            playingKind = kind
            playingRepeats = playback.repeatsUntilAcknowledged
            setAlarmVolume(Float(playback.volume))
            guard player.play() else {
                stop()
                return "Alarm sound for \(kind.rawValue) failed to start"
            }
            if let testSeconds = testSeconds {
                let work = DispatchWorkItem { [weak self] in self?.stop() }
                testStopWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + testSeconds, execute: work)
            }
            return "Alarm sound \(playback.sound.rawValue) playing for \(kind.rawValue) (through silent: \(playback.playsThroughSilent), volume \(Int(playback.volume * 100))%, phone volume was \(Int(session.outputVolume * 100))%)"
        } catch {
            stop()
            return "Alarm sound for \(kind.rawValue) failed: \(error.localizedDescription)"
        }
    }

    /// Stops the sound. With a kind, stops only if that alarm is the one sounding.
    func stop(kind: DirectConnect_AlarmKind? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let kind = kind, kind != playingKind { return }
        testStopWork?.cancel()
        testStopWork = nil
        player?.stop()
        player = nil
        playingKind = nil
        playingRepeats = false
        restoreSystemVolume()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var isPlaying: Bool { player?.isPlaying == true }

    // MARK: Volume

    // iOS has no public call to set the media volume. Moving the slider inside an MPVolumeView is
    // the method other CGM apps use. It must be checked on a device, with the phone locked and in
    // the background.
    private func setAlarmVolume(_ volume: Float) {
        let current = AVAudioSession.sharedInstance().outputVolume
        guard abs(current - volume) > 0.01 else { return }
        if volumeBeforeAlarm == nil {
            volumeBeforeAlarm = current
        }
        setSystemVolume(volume)
    }

    /// Changes the level of the sound playing now, for the volume slider while choosing a sound.
    func changeVolume(to volume: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isPlaying else { return }
        setAlarmVolume(Float(volume))
    }

    private func restoreSystemVolume() {
        guard let previous = volumeBeforeAlarm else { return }
        volumeBeforeAlarm = nil
        setSystemVolume(previous)
    }

    private func setSystemVolume(_ value: Float) {
        let view = volumeView ?? MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        volumeView = view
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // The slider ignores a value set in the same run loop pass that created it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            slider.setValue(value, animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }
}

extension DirectConnect_AlarmPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === self.player { stop() }
    }
}
