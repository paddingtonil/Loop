//
//  LoopInsights_CaregiverDigestService.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  LoopInsights — Caregiver / Family Digest generator and scheduler.
//  Generates shareable daily or weekly summaries for caregivers and family members.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import Combine
import UserNotifications

/// Manages caregiver digest generation, scheduling, and delivery.
final class LoopInsights_CaregiverDigestService: ObservableObject {

    // MARK: - Published State

    @Published var isGenerating = false
    @Published var lastGeneratedDigest: DigestContent?
    @Published var lastSentDate: Date?

    // MARK: - Types

    enum DigestFrequency: String, CaseIterable, Identifiable {
        case daily = "daily"
        case weekly = "weekly"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .daily: return NSLocalizedString("Daily", comment: "Caregiver digest frequency: daily")
            case .weekly: return NSLocalizedString("Weekly", comment: "Caregiver digest frequency: weekly")
            }
        }

        var period: LoopInsightsAnalysisPeriod {
            switch self {
            case .daily: return .threeDays
            case .weekly: return .sevenDays
            }
        }

        var periodLabel: String {
            switch self {
            case .daily: return NSLocalizedString("Last 24 Hours", comment: "Caregiver digest daily period")
            case .weekly: return NSLocalizedString("Last 7 Days", comment: "Caregiver digest weekly period")
            }
        }
    }

    struct DigestContent {
        let subject: String
        let plainText: String
        let htmlBody: String
        let generatedAt: Date
        let frequency: DigestFrequency
    }

    enum DeliveryMethod: String, CaseIterable, Identifiable {
        case email = "email"
        case iMessage = "imessage"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .email: return NSLocalizedString("Email", comment: "Caregiver digest delivery: email")
            case .iMessage: return NSLocalizedString("SMS", comment: "Caregiver digest delivery: SMS")
            }
        }

        var iconName: String {
            switch self {
            case .email: return "envelope.fill"
            case .iMessage: return "message.fill"
            }
        }
    }

    // MARK: - UserDefaults Keys

    private static let enabledKey = "LoopInsights_caregiverDigestEnabled"
    private static let frequencyKey = "LoopInsights_caregiverDigestFrequency"
    private static let recipientNameKey = "LoopInsights_caregiverRecipientName"
    private static let recipientContactKey = "LoopInsights_caregiverRecipientContact" // legacy single-field (migrated)
    private static let recipientEmailKey = "LoopInsights_caregiverRecipientEmail"
    private static let recipientPhoneKey = "LoopInsights_caregiverRecipientPhone"
    private static let deliveryMethodKey = "LoopInsights_caregiverDeliveryMethod"
    private static let lastSentKey = "LoopInsights_caregiverLastSent"
    private static let reminderHourKey = "LoopInsights_caregiverReminderHour"
    private static let reminderMinuteKey = "LoopInsights_caregiverReminderMinute"

    /// Stable identifier for the repeating reminder so re-scheduling replaces
    /// (rather than stacks) the pending notification. Read by `LoopAppManager` to
    /// recognize the tap, so it can't be `private`.
    static let reminderNotificationID = "LoopInsights_CaregiverDigestReminder"

    /// Set when the user taps the digest reminder so the status screen opens the
    /// Caregiver Digest (and auto-presents the pre-filled compose sheet) on appear.
    /// A flag rather than only a NotificationCenter post: on a cold launch the status
    /// screen isn't observing yet when the tap is handled, so the post would be lost —
    /// the flag survives until the screen appears. Cleared by the presenter (fire-once).
    static var pendingOpenFromReminder = false

    // MARK: - Settings

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var frequency: DigestFrequency {
        get {
            guard let raw = UserDefaults.standard.string(forKey: frequencyKey),
                  let freq = DigestFrequency(rawValue: raw) else { return .daily }
            return freq
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: frequencyKey) }
    }

    static var recipientName: String {
        get { UserDefaults.standard.string(forKey: recipientNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: recipientNameKey) }
    }

    /// Recipient email address. Persists independently of the phone number so
    /// switching delivery method preserves both values.
    static var recipientEmail: String {
        get {
            let stored = UserDefaults.standard.string(forKey: recipientEmailKey) ?? ""
            if stored.isEmpty {
                // One-time migration: if the legacy single field looks like an email, adopt it.
                let legacy = UserDefaults.standard.string(forKey: recipientContactKey) ?? ""
                if legacy.contains("@") { return legacy }
            }
            return stored
        }
        set { UserDefaults.standard.set(newValue, forKey: recipientEmailKey) }
    }

    /// Recipient phone number. Persists independently of the email.
    static var recipientPhone: String {
        get {
            let stored = UserDefaults.standard.string(forKey: recipientPhoneKey) ?? ""
            if stored.isEmpty {
                // Legacy single field that isn't an email is treated as a phone number.
                let legacy = UserDefaults.standard.string(forKey: recipientContactKey) ?? ""
                if !legacy.isEmpty && !legacy.contains("@") { return legacy }
            }
            return stored
        }
        set { UserDefaults.standard.set(newValue, forKey: recipientPhoneKey) }
    }

    /// The contact to send to for the current delivery method. Read-only
    /// convenience used by the send paths; the underlying values are edited via
    /// `recipientEmail` / `recipientPhone`.
    static var recipientContact: String {
        deliveryMethod == .email ? recipientEmail : recipientPhone
    }

    /// Clears all saved recipient details (email, phone, name, and legacy field).
    static func clearRecipients() {
        UserDefaults.standard.removeObject(forKey: recipientEmailKey)
        UserDefaults.standard.removeObject(forKey: recipientPhoneKey)
        UserDefaults.standard.removeObject(forKey: recipientNameKey)
        UserDefaults.standard.removeObject(forKey: recipientContactKey)
    }

    static var deliveryMethod: DeliveryMethod {
        get {
            guard let raw = UserDefaults.standard.string(forKey: deliveryMethodKey),
                  let method = DeliveryMethod(rawValue: raw) else { return .email }
            return method
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: deliveryMethodKey) }
    }

    static var lastSentDate: Date? {
        get { UserDefaults.standard.object(forKey: lastSentKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastSentKey) }
    }

    /// Hour of day (0–23) the reminder fires. Defaults to 9 AM when unset —
    /// `integer(forKey:)` returns 0 for a missing key, which we treat as "use default".
    static var reminderHour: Int {
        get {
            guard UserDefaults.standard.object(forKey: reminderHourKey) != nil else { return 9 }
            return UserDefaults.standard.integer(forKey: reminderHourKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: reminderHourKey) }
    }

    /// Minute of the hour (0–59) the reminder fires. Defaults to 0.
    static var reminderMinute: Int {
        get { UserDefaults.standard.integer(forKey: reminderMinuteKey) }
        set { UserDefaults.standard.set(newValue, forKey: reminderMinuteKey) }
    }

    /// The reminder time as a `Date` (today at hour:minute) for binding to a SwiftUI
    /// `DatePicker`. Only the hour/minute components are persisted.
    static var reminderTime: Date {
        get {
            Calendar.current.date(bySettingHour: reminderHour, minute: reminderMinute, second: 0, of: Date()) ?? Date()
        }
        set {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            reminderHour = comps.hour ?? 9
            reminderMinute = comps.minute ?? 0
        }
    }

    // MARK: - Digest Generation

    /// Generate a digest from current LoopInsights data.
    func generateDigest(
        using aggregator: LoopInsights_DataAggregator,
        frequency: DigestFrequency,
        unitContext: LoopInsights_GlucoseUnitContext = .fallbackMgdl
    ) async -> DigestContent? {
        await MainActor.run { isGenerating = true }

        do {
            let stats = try await aggregator.aggregateData(period: frequency.period)
            let content = Self.buildDigest(from: stats, frequency: frequency, unitContext: unitContext)

            await MainActor.run {
                self.lastGeneratedDigest = content
                self.isGenerating = false
            }
            return content
        } catch {
            LoopInsights_FeatureFlags.log.error("Caregiver digest generation failed: \(error)")
            await MainActor.run { self.isGenerating = false }
            return nil
        }
    }

    /// Whether the next digest is due, based on the configured frequency and the
    /// last successful send. True when enabled and never sent. Used to auto-present
    /// the pre-filled compose sheet when the user opens the digest screen.
    static var isDue: Bool {
        guard isEnabled else { return false }
        guard let last = lastSentDate else { return true }
        let interval: TimeInterval = frequency == .weekly ? 7 * 24 * 3600 : 24 * 3600
        return Date().timeIntervalSince(last) >= interval
    }

    /// Mark that a digest was sent.
    func markSent() {
        let now = Date()
        Self.lastSentDate = now
        lastSentDate = now
    }

    // MARK: - Reminder Scheduling

    /// (Re)schedule or cancel the repeating digest reminder to match the current
    /// enabled state, frequency, and reminder time.
    ///
    /// Why a repeating `UNCalendarNotificationTrigger` instead of the in-app
    /// `.LoopCompleted` throttle the AI monitor uses: the digest is sent by tapping
    /// a pre-filled Mail/Messages sheet, so the goal is only to *remind* the user on
    /// schedule. A calendar trigger fires even when the app isn't running, which the
    /// `.LoopCompleted` hook can't guarantee. iOS handles the repeat natively.
    ///
    /// Idempotent — always clears the prior request first so frequency/time edits
    /// replace rather than stack. Safe to call from `.onAppear` to self-heal.
    static func refreshReminderSchedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderNotificationID])

        guard isEnabled else {
            LoopInsights_FeatureFlags.log.info("Caregiver digest disabled — reminder cancelled")
            return
        }

        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else {
                LoopInsights_FeatureFlags.log.warning("Caregiver digest reminder: notifications not authorized")
                return
            }
            scheduleReminderNotification(on: center)
        }
    }

    private static func scheduleReminderNotification(on center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Caregiver Digest", comment: "Caregiver digest reminder notification title")

        let recipient = recipientName.isEmpty
            ? NSLocalizedString("your caregiver", comment: "Caregiver digest reminder default recipient")
            : recipientName
        let window = frequency == .weekly
            ? NSLocalizedString("this week's", comment: "Caregiver digest reminder period: weekly")
            : NSLocalizedString("today's", comment: "Caregiver digest reminder period: daily")
        content.body = String(
            format: NSLocalizedString("Time to send %1$@ %2$@ glucose summary — open Caregiver Digest and tap Send Now.", comment: "Caregiver digest reminder body"),
            recipient, window
        )
        content.sound = .default

        var components = DateComponents()
        components.hour = reminderHour
        components.minute = reminderMinute
        // Weekly fires on whatever weekday it was scheduled (today); daily omits weekday.
        if frequency == .weekly {
            components.weekday = Calendar.current.component(.weekday, from: Date())
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: reminderNotificationID, content: content, trigger: trigger)

        center.add(request) { error in
            if let error = error {
                LoopInsights_FeatureFlags.log.error("Failed to schedule caregiver digest reminder: \(error.localizedDescription)")
            } else {
                LoopInsights_FeatureFlags.log.info("Caregiver digest reminder scheduled (\(frequency.rawValue) at \(reminderHour):\(String(format: "%02d", reminderMinute)))")
            }
        }
    }

    // MARK: - Content Builder

    static func buildDigest(
        from stats: LoopInsightsAggregatedStats,
        frequency: DigestFrequency,
        unitContext: LoopInsights_GlucoseUnitContext = .fallbackMgdl
    ) -> DigestContent {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let shortDate = DateFormatter()
        shortDate.dateStyle = .medium

        let now = Date()
        let recipientName = Self.recipientName
        let greeting = recipientName.isEmpty
            ? NSLocalizedString("Hi there", comment: "Caregiver digest default greeting")
            : String(format: NSLocalizedString("Hi %@", comment: "Caregiver digest greeting with name"), recipientName)

        let g = stats.glucoseStats
        let i = stats.insulinStats
        let c = stats.carbStats

        // Determine status emoji/sentiment
        let statusEmoji: String
        let statusSummary: String
        if g.timeInRange >= 80 && g.timeBelowRange < 4 {
            statusEmoji = "🟢"
            statusSummary = NSLocalizedString("Things are looking great!", comment: "Caregiver digest: great status")
        } else if g.timeInRange >= 65 && g.timeBelowRange < 6 {
            statusEmoji = "🟡"
            statusSummary = NSLocalizedString("Doing okay overall, with some room for improvement.", comment: "Caregiver digest: okay status")
        } else {
            statusEmoji = "🔴"
            statusSummary = NSLocalizedString("There are some areas that could use attention.", comment: "Caregiver digest: attention status")
        }

        // Low events description (unit-aware)
        let lowStr = unitContext.formatUserValue(unitContext.lowValue, includeUnit: false)
        let highStr = unitContext.formatUserValue(unitContext.highValue, includeUnit: false)
        let lowDesc: String
        if g.timeBelowRange < 1 {
            lowDesc = NSLocalizedString("No significant lows", comment: "Caregiver digest: no lows")
        } else if g.timeBelowRange < 4 {
            lowDesc = String(format: NSLocalizedString("Minor low time (%.1f%% below %@)", comment: "Caregiver digest: minor lows"), g.timeBelowRange, lowStr)
        } else {
            lowDesc = String(format: NSLocalizedString("⚠️ Notable low time (%.1f%% below %@)", comment: "Caregiver digest: notable lows"), g.timeBelowRange, lowStr)
        }

        // High events description (unit-aware)
        let highDesc: String
        if g.timeAboveRange < 10 {
            highDesc = NSLocalizedString("Minimal time high", comment: "Caregiver digest: minimal highs")
        } else if g.timeAboveRange < 25 {
            highDesc = String(format: NSLocalizedString("Some high time (%.0f%% above %@)", comment: "Caregiver digest: some highs"), g.timeAboveRange, highStr)
        } else {
            highDesc = String(format: NSLocalizedString("⚠️ Significant high time (%.0f%% above %@)", comment: "Caregiver digest: significant highs"), g.timeAboveRange, highStr)
        }

        // Time-in-Range bar segment widths (low / in-range / high), summing to 100%.
        let lowW = max(0, Int(g.timeBelowRange.rounded()))
        let highW = max(0, Int(g.timeAboveRange.rounded()))
        let inW = max(0, 100 - lowW - highW)

        // Email-safe key/value row. Uses a table cell pair — Gmail strips the
        // flexbox/float layout the old `.stat-row` relied on, which jammed the
        // label and value together ("Average Glucose133 mg/dL").
        func metricRow(_ label: String, _ value: String) -> String {
            "<tr><td style=\"color:#555;padding:7px 2px;border-bottom:1px solid #f0f0f0;\">\(label)</td><td align=\"right\" style=\"color:#1a1a1a;font-weight:600;padding:7px 2px;border-bottom:1px solid #f0f0f0;\">\(value)</td></tr>"
        }
        let sectionTitle = "font-size:12px;font-weight:700;color:#14707e;text-transform:uppercase;letter-spacing:0.5px;border-bottom:2px solid #14707e;padding-bottom:5px;margin-bottom:4px;"

        // Emoji Time-in-Range bar for SMS/iMessage (10 blocks ≈ 10% each). Renders
        // natively in Messages where the HTML colored bar can't.
        let lowBlocks = Int((g.timeBelowRange / 10).rounded())
        let highBlocks = Int((g.timeAboveRange / 10).rounded())
        let inBlocks = max(0, 10 - lowBlocks - highBlocks)
        let emojiBar = String(repeating: "🟥", count: lowBlocks)
            + String(repeating: "🟩", count: inBlocks)
            + String(repeating: "🟨", count: highBlocks)

        let subject = "\(statusEmoji) LoopInsights Digest — \(shortDate.string(from: now))"

        // Plain text version
        let plainText = """
        \(greeting),

        \(statusEmoji) \(statusSummary)
        \(frequency.periodLabel) summary

        📊 GLUCOSE
        Time in Range: \(String(format: "%.0f", g.timeInRange))%
        \(emojiBar)
        🟩 in range · 🟨 high · 🟥 low
        • Avg glucose: \(unitContext.formatMgdl(g.averageGlucose))
        • Est. A1C: \(String(format: "%.1f", g.gmi))%
        • \(lowDesc)
        • \(highDesc)

        💉 INSULIN
        • Daily dose: \(String(format: "%.1f", i.totalDailyDose)) U
        • Basal / Bolus: \(String(format: "%.0f", i.basalPercentage))% / \(String(format: "%.0f", i.bolusPercentage))%

        🍽️ MEALS
        • Meals logged: \(c.mealCount)
        • Daily carbs: \(String(format: "%.0f", c.averageDailyCarbs))g

        —
        LoopInsights · \(dateFormatter.string(from: now))
        Automated summary — informational only.
        """

        // HTML version — table-based + inline styles for maximum email-client
        // compatibility (Gmail strips <style> layout rules and flexbox/floats).
        let htmlBody = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        </head>
        <body style="margin:0;padding:0;background:#f5f5f5;font-family:-apple-system,'Helvetica Neue',Arial,sans-serif;color:#1a1a1a;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f5;">
          <tr><td align="center" style="padding:16px;">
            <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="max-width:480px;width:100%;background:#ffffff;border-radius:10px;overflow:hidden;">

              <tr><td style="background:#14707e;color:#ffffff;padding:22px 20px;text-align:center;">
                <div style="font-size:20px;font-weight:700;">LoopInsights Digest</div>
                <div style="font-size:12px;opacity:0.85;margin-top:4px;">\(frequency.periodLabel) — \(shortDate.string(from: now))</div>
              </td></tr>

              <tr><td style="background:#f0fafb;border-bottom:1px solid #d4eef2;padding:16px 20px;text-align:center;font-size:15px;font-weight:600;">
                \(statusEmoji) \(statusSummary)
              </td></tr>

              <tr><td style="padding:22px 20px 6px;text-align:center;">
                <div style="font-size:12px;color:#888;text-transform:uppercase;letter-spacing:0.5px;">Time in Range (\(unitContext.tirRangeString))</div>
                <div style="font-size:42px;font-weight:800;color:#43a047;line-height:1.1;margin:2px 0;">\(String(format: "%.0f", g.timeInRange))%</div>
              </td></tr>

              <tr><td style="padding:6px 20px 0;">
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-radius:6px;overflow:hidden;border-collapse:collapse;">
                  <tr>
                    <td width="\(lowW)%" height="30" bgcolor="#e53935"></td>
                    <td width="\(inW)%" height="30" bgcolor="#43a047"></td>
                    <td width="\(highW)%" height="30" bgcolor="#fb8c00"></td>
                  </tr>
                </table>
              </td></tr>

              <tr><td style="padding:8px 20px 2px;">
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:12px;color:#555;">
                  <tr>
                    <td align="center" width="33%">🟥 Low<br><span style="font-size:15px;font-weight:700;color:#1a1a1a;">\(String(format: "%.0f", g.timeBelowRange))%</span></td>
                    <td align="center" width="34%">🟩 In Range<br><span style="font-size:15px;font-weight:700;color:#1a1a1a;">\(String(format: "%.0f", g.timeInRange))%</span></td>
                    <td align="center" width="33%">🟨 High<br><span style="font-size:15px;font-weight:700;color:#1a1a1a;">\(String(format: "%.0f", g.timeAboveRange))%</span></td>
                  </tr>
                </table>
              </td></tr>

              <tr><td style="padding:12px 20px 0;">
                <div style="font-size:13px;padding:5px 0;">\(lowDesc)</div>
                <div style="font-size:13px;padding:5px 0;">\(highDesc)</div>
              </td></tr>

              <tr><td style="padding:14px 20px 0;">
                <div style="\(sectionTitle)">📊 Glucose Detail</div>
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:13px;">
                  \(metricRow("Average Glucose", unitContext.formatMgdl(g.averageGlucose)))
                  \(metricRow("GMI (est. A1C)", String(format: "%.1f%%", g.gmi)))
                  \(metricRow("Variability (Std Dev)", unitContext.formatMgdl(g.standardDeviation)))
                </table>
              </td></tr>

              <tr><td style="padding:16px 20px 0;">
                <div style="\(sectionTitle)">💉 Insulin</div>
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:13px;">
                  \(metricRow("Avg Daily Dose", String(format: "%.1f U", i.totalDailyDose)))
                  \(metricRow("Basal / Bolus", String(format: "%.0f%% / %.0f%%", i.basalPercentage, i.bolusPercentage)))
                  \(metricRow("Correction Boluses", "\(i.correctionBolusCount)"))
                </table>
              </td></tr>

              <tr><td style="padding:16px 20px 18px;">
                <div style="\(sectionTitle)">🍽️ Meals</div>
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:13px;">
                  \(metricRow("Meals Logged", "\(c.mealCount)"))
                  \(metricRow("Avg Daily Carbs", String(format: "%.0f g", c.averageDailyCarbs)))
                  \(metricRow("Avg Per Meal", String(format: "%.0f g", c.averageCarbsPerMeal)))
                </table>
              </td></tr>

              <tr><td style="padding:16px 20px;border-top:1px solid #eee;text-align:center;font-size:10px;color:#999;line-height:1.5;">
                <b style="color:#14707e;">LoopInsights</b> — AI-Powered Therapy Settings Analysis<br>
                Generated \(dateFormatter.string(from: now))<br>
                This is an automated summary for informational purposes only.
              </td></tr>

            </table>
          </td></tr>
        </table>
        </body>
        </html>
        """

        return DigestContent(
            subject: subject,
            plainText: plainText,
            htmlBody: htmlBody,
            generatedAt: now,
            frequency: frequency
        )
    }

}

extension Notification.Name {
    /// Posted when the caregiver digest reminder notification is tapped, asking the
    /// status screen to open the Caregiver Digest and auto-present the send sheet.
    static let loopInsightsOpenCaregiverDigest = Notification.Name("com.loopkit.Loop.loopInsightsOpenCaregiverDigest")
}
