//
//  DirectConnect_AlarmSettingsTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class DirectConnect_AlarmSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DirectConnect_AlarmSettingsTests")
        defaults.removePersistentDomain(forName: "DirectConnect_AlarmSettingsTests")
    }

    func testDefaultsMatchSpec() {
        let s = DirectConnect_AlarmSettings.defaults
        XCTAssertEqual(s.urgentLowThreshold, 55); XCTAssertTrue(s.urgentLowEnabled); XCTAssertEqual(s.urgentLowRepeatMinutes, 5)
        XCTAssertEqual(s.lowThreshold, 70); XCTAssertTrue(s.lowEnabled); XCTAssertEqual(s.lowRepeatMinutes, 15)
        XCTAssertEqual(s.highThreshold, 250); XCTAssertTrue(s.highEnabled); XCTAssertEqual(s.highRepeatMinutes, 60)
        XCTAssertEqual(s.risingRate, 3); XCTAssertFalse(s.risingFastEnabled)
        XCTAssertEqual(s.fallingRate, 3); XCTAssertTrue(s.fallingFastEnabled)
        XCTAssertEqual(s.signalLossMinutes, 20); XCTAssertTrue(s.signalLossEnabled)
        XCTAssertTrue(s.sensorExpiringEnabled); XCTAssertTrue(s.sensorEndedEnabled)
    }

    func testLoadReturnsDefaultsWhenNothingSaved() {
        XCTAssertEqual(DirectConnect_AlarmSettings.load(from: defaults), .defaults)
    }

    func testSaveLoadRoundTrip() {
        var s = DirectConnect_AlarmSettings.defaults
        s.lowThreshold = 80; s.highEnabled = false; s.risingRate = 2.5
        s.save(to: defaults)
        XCTAssertEqual(DirectConnect_AlarmSettings.load(from: defaults), s)
    }

    func testValuesAreClampedToRanges() {
        var s = DirectConnect_AlarmSettings.defaults
        s.urgentLowThreshold = 10; s.highThreshold = 900; s.risingRate = 9; s.signalLossMinutes = 1
        let n = s.normalized()
        XCTAssertEqual(n.urgentLowThreshold, 40); XCTAssertEqual(n.highThreshold, 400)
        XCTAssertEqual(n.risingRate, 5); XCTAssertEqual(n.signalLossMinutes, 10)
    }

    func testThresholdOrderingIsEnforced() {
        var s = DirectConnect_AlarmSettings.defaults
        s.urgentLowThreshold = 65; s.lowThreshold = 60
        let n = s.normalized()
        XCTAssertLessThan(n.urgentLowThreshold, n.lowThreshold)
        XCTAssertLessThan(n.lowThreshold, n.highThreshold)
    }

    // MARK: - Alarm sounds

    func testSoundChoicesRoundTrip() {
        var s = DirectConnect_AlarmSettings.defaults
        s.sounds[.low] = .pulse
        s.sounds[.high] = DirectConnect_AlarmSound.none
        s.playThrough = [.low, .signalLoss]
        s.save(to: defaults)
        let loaded = DirectConnect_AlarmSettings.load(from: defaults)
        XCTAssertEqual(loaded.sound(for: .low), .pulse)
        XCTAssertEqual(loaded.sound(for: .high), DirectConnect_AlarmSound.none)
        XCTAssertEqual(loaded.playThrough, [.low, .signalLoss])
    }

    func testUrgentLowAndFallingFastPlayThroughByDefault() {
        // On 2026-10-18 six Urgent Low alarms fired overnight and none were heard.
        XCTAssertEqual(DirectConnect_AlarmSound.urgentKinds, [.urgentLow, .fallingFast])
        XCTAssertEqual(DirectConnect_AlarmSettings.defaults.playThrough, [.urgentLow, .fallingFast])
        XCTAssertEqual(DirectConnect_AlarmSettings.load(from: defaults).playThrough, [.urgentLow, .fallingFast])
    }

    func testUrgentAlarmsCannotBeMadeSilent() {
        var s = DirectConnect_AlarmSettings.defaults
        s.sounds[.urgentLow] = DirectConnect_AlarmSound.none
        s.sounds[.fallingFast] = DirectConnect_AlarmSound.none
        XCTAssertNotEqual(s.normalized().sound(for: .urgentLow), DirectConnect_AlarmSound.none)
        XCTAssertNotEqual(s.normalized().sound(for: .fallingFast), DirectConnect_AlarmSound.none)
    }

    func testPlayThroughIgnoresSilentFocusAndMuteForAnyAlarm() {
        var s = DirectConnect_AlarmSettings.defaults
        s.playThrough = Set(DirectConnect_AlarmKind.allCases)
        for kind in DirectConnect_AlarmKind.allCases {
            let p = DirectConnect_AlarmPlayback.for(kind, settings: s, loopAlertsMuted: true)
            XCTAssertEqual(p?.playsThroughSilent, true, kind.rawValue)
            XCTAssertEqual(p?.volume, DirectConnect_AlarmSettings.defaultVolume, kind.rawValue)
        }
    }

    func testWithoutPlayThroughAnAlarmFollowsThePhone() {
        var s = DirectConnect_AlarmSettings.defaults
        s.playThrough = []
        let urgent = DirectConnect_AlarmPlayback.for(.urgentLow, settings: s, loopAlertsMuted: false)
        XCTAssertEqual(urgent?.playsThroughSilent, false)
        XCTAssertEqual(urgent?.repeatsUntilAcknowledged, true, "urgent alarms still repeat until acknowledged")
        XCTAssertNil(DirectConnect_AlarmPlayback.for(.urgentLow, settings: s, loopAlertsMuted: true), "Loop's Mute Alerts applies when play-through is off")

        let low = DirectConnect_AlarmPlayback.for(.low, settings: s, loopAlertsMuted: false)
        XCTAssertEqual(low?.playsThroughSilent, false)
        XCTAssertEqual(low?.repeatsUntilAcknowledged, false)

        s.sounds[.low] = DirectConnect_AlarmSound.none
        XCTAssertNil(DirectConnect_AlarmPlayback.for(.low, settings: s, loopAlertsMuted: false))
    }

    func testDefaultVolumeIsMediumLow() {
        for kind in DirectConnect_AlarmKind.allCases {
            XCTAssertEqual(DirectConnect_AlarmSettings.defaults.volume(for: kind), 0.4, kind.rawValue)
        }
    }

    func testVolumeRoundTripsAndStaysAudible() {
        var s = DirectConnect_AlarmSettings.defaults
        s.volumes[.urgentLow] = 0.75
        s.volumes[.low] = 0
        s.volumes[.high] = 3
        s.save(to: defaults)
        let loaded = DirectConnect_AlarmSettings.load(from: defaults)
        XCTAssertEqual(loaded.volume(for: .urgentLow), 0.75)
        XCTAssertEqual(loaded.volume(for: .low), DirectConnect_AlarmSettings.volumeRange.lowerBound, "an alarm cannot be set to zero volume")
        XCTAssertEqual(loaded.volume(for: .high), 1)
    }

    func testPlaybackUsesTheAlarmsOwnVolume() {
        var s = DirectConnect_AlarmSettings.defaults
        s.volumes[.urgentLow] = 0.9
        s.volumes[.low] = 0.25
        XCTAssertEqual(DirectConnect_AlarmPlayback.for(.urgentLow, settings: s, loopAlertsMuted: false)?.volume, 0.9)
        XCTAssertEqual(DirectConnect_AlarmPlayback.for(.low, settings: s, loopAlertsMuted: false)?.volume, 0.25)
    }

    func testEverySoundRendersAnAudibleWAV() {
        for sound in DirectConnect_AlarmSound.generated {
            let samples = sound.samples()
            let seconds = Double(samples.count) / DirectConnect_AlarmSound.sampleRate
            XCTAssertGreaterThan(seconds, 0.5, sound.rawValue)
            XCTAssertLessThan(seconds, 5, sound.rawValue)
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, Int(Int16.max) / 2, "\(sound.rawValue) is too quiet")

            let wav = sound.wavData()
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
            XCTAssertEqual(wav.count, 44 + samples.count * 2)
        }
        XCTAssertTrue(DirectConnect_AlarmSound.none.samples().isEmpty)
    }

    func testEveryXDripSoundIsInTheApp() {
        XCTAssertEqual(DirectConnect_AlarmSound.xDrip.count, 117)
        for sound in DirectConnect_AlarmSound.xDrip {
            XCTAssertNotNil(sound.audioData(), "\(sound.displayName) is missing from DefaultAssets.xcassets")
        }
        XCTAssertNil(DirectConnect_AlarmSound.none.audioData())
        XCTAssertNotNil(DirectConnect_AlarmSound.siren.audioData())
    }

    func testSoundIdentifiersRoundTrip() {
        for sound in DirectConnect_AlarmSound.allChoices {
            XCTAssertEqual(DirectConnect_AlarmSound(rawValue: sound.rawValue), sound)
        }
        XCTAssertNil(DirectConnect_AlarmSound(rawValue: "notASound"))
    }
}
