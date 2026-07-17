//
//  PowerPack_APIUsage.swift
//  Loop
//
//  PowerPack — BYOK API spend awareness + user-configurable controls.
//  Shared by every AI feature (FoodFinder, LoopInsights) since they share one
//  API key. Tracks estimated monthly spend, exposes a per-use confirmation gate
//  and a monthly budget cap, and renders the settings UI for both.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI

/// Central, shared store for PowerPack AI token-usage awareness and spend control.
@MainActor
final class PowerPack_APIUsage: ObservableObject {

    static let shared = PowerPack_APIUsage()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let confirmEachRequest = "PowerPack_apiConfirmEachRequest"
        static let monthlyBudget = "PowerPack_apiMonthlyBudgetUSD"   // 0 = no cap
        static let warnAtPercent = "PowerPack_apiWarnAtPercent"
        static let blockOverBudget = "PowerPack_apiBlockOverBudget"
        static let spendMonthKey = "PowerPack_apiSpendMonth"         // "2026-06"
        static let spendAmount = "PowerPack_apiSpendAmountUSD"
    }

    // MARK: - User-configurable controls (persisted)

    @Published var confirmEachRequest: Bool {
        didSet { defaults.set(confirmEachRequest, forKey: Keys.confirmEachRequest) }
    }
    /// Monthly ceiling in USD. 0 means "no budget cap".
    @Published var monthlyBudgetUSD: Double {
        didSet { defaults.set(monthlyBudgetUSD, forKey: Keys.monthlyBudget) }
    }
    /// Warn once estimated spend crosses this fraction of the budget (e.g. 80).
    @Published var warnAtPercent: Double {
        didSet { defaults.set(warnAtPercent, forKey: Keys.warnAtPercent) }
    }
    /// When true, block paid calls once the budget is exceeded (otherwise warn-only).
    @Published var blockWhenOverBudget: Bool {
        didSet { defaults.set(blockWhenOverBudget, forKey: Keys.blockOverBudget) }
    }

    // MARK: - Tracked spend

    @Published private(set) var currentMonthSpendUSD: Double = 0

    /// Session-only "don't ask again" — cleared on each app launch (not persisted).
    private(set) var sessionApprovalGranted = false

    // MARK: - Alert drivers (observed by the gate modifier)

    struct PendingApproval: Identifiable {
        let id = UUID()
        let actionLabel: String
        let estCostUSD: Double
        let continuation: CheckedContinuation<GateDecision, Never>
    }
    enum GateDecision { case proceed, proceedAllSession, cancel }

    @Published var pendingApproval: PendingApproval?
    @Published var budgetBlockedMessage: String?

    private var budgetCapEnabled: Bool { monthlyBudgetUSD > 0 }

    var isOverBudget: Bool { budgetCapEnabled && currentMonthSpendUSD >= monthlyBudgetUSD }
    var isNearBudget: Bool {
        budgetCapEnabled && currentMonthSpendUSD >= monthlyBudgetUSD * (warnAtPercent / 100.0)
    }
    var budgetUsedFraction: Double {
        guard budgetCapEnabled else { return 0 }
        return min(1.0, currentMonthSpendUSD / monthlyBudgetUSD)
    }

    private init() {
        confirmEachRequest = defaults.bool(forKey: Keys.confirmEachRequest)
        monthlyBudgetUSD = defaults.double(forKey: Keys.monthlyBudget)
        let warn = defaults.double(forKey: Keys.warnAtPercent)
        warnAtPercent = warn > 0 ? warn : 80
        blockWhenOverBudget = defaults.bool(forKey: Keys.blockOverBudget)
        currentMonthSpendUSD = Self.loadSpendForCurrentMonth(defaults: defaults)
    }

    // MARK: - Spend tracking

    /// Record actual usage from an API response. Call from the service adapters
    /// after each successful (or partial) response that reported token counts.
    func record(model: String, inputTokens: Int, outputTokens: Int) {
        let cost = Self.estimateCostUSD(model: model, inputTokens: inputTokens, outputTokens: outputTokens)
        addSpend(cost)
    }

    /// Fallback when the provider didn't return token counts — estimate from text length.
    func recordEstimated(model: String, promptChars: Int, responseChars: Int) {
        record(model: model, inputTokens: promptChars / 4, outputTokens: responseChars / 4)
    }

    func resetThisMonthSpend() {
        addSpend(-currentMonthSpendUSD)
    }

    private func addSpend(_ delta: Double) {
        rolloverMonthIfNeeded()
        currentMonthSpendUSD = max(0, currentMonthSpendUSD + delta)
        defaults.set(currentMonthSpendUSD, forKey: Keys.spendAmount)
        defaults.set(Self.currentMonthString(), forKey: Keys.spendMonthKey)
    }

    private func rolloverMonthIfNeeded() {
        let stored = defaults.string(forKey: Keys.spendMonthKey)
        if stored != Self.currentMonthString() {
            currentMonthSpendUSD = 0
            defaults.set(0.0, forKey: Keys.spendAmount)
            defaults.set(Self.currentMonthString(), forKey: Keys.spendMonthKey)
        }
    }

    private static func loadSpendForCurrentMonth(defaults: UserDefaults) -> Double {
        guard defaults.string(forKey: Keys.spendMonthKey) == currentMonthString() else { return 0 }
        return defaults.double(forKey: Keys.spendAmount)
    }

    private static func currentMonthString() -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }

    // MARK: - The gate

    /// Pass every USER-INITIATED paid AI action through this before calling the API.
    /// Returns true to proceed. Honors the budget hard-block and the per-use confirm.
    func gate(actionLabel: String, estCostUSD: Double = 0.02) async -> Bool {
        rolloverMonthIfNeeded()

        // 1) Hard budget block
        if isOverBudget && blockWhenOverBudget {
            budgetBlockedMessage = String(
                format: "You've reached your monthly AI budget of $%.2f (estimated $%.2f used). Raise the budget in AI & Token Usage settings, or turn off the hard block.",
                monthlyBudgetUSD, currentMonthSpendUSD)
            return false
        }

        // 2) Per-use confirmation
        if confirmEachRequest && !sessionApprovalGranted {
            let decision = await withCheckedContinuation { (cont: CheckedContinuation<GateDecision, Never>) in
                pendingApproval = PendingApproval(actionLabel: actionLabel, estCostUSD: estCostUSD, continuation: cont)
            }
            switch decision {
            case .cancel: return false
            case .proceedAllSession:
                sessionApprovalGranted = true
                return true
            case .proceed:
                return true
            }
        }

        return true
    }

    fileprivate func resolvePending(_ decision: GateDecision) {
        let pending = pendingApproval
        pendingApproval = nil
        pending?.continuation.resume(returning: decision)
    }

    // MARK: - Pricing (rough, $ per 1M tokens: input, output)

    static func estimateCostUSD(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let m = model.lowercased()
        let rate: (inUSD: Double, outUSD: Double)
        if m.contains("opus") {            rate = (5, 25) }
        else if m.contains("sonnet") {     rate = (3, 15) }
        else if m.contains("haiku") {      rate = (1, 5) }
        else if m.contains("gpt-4o-mini") {rate = (0.15, 0.6) }
        else if m.contains("gpt-4o") || m.contains("gpt-4.1") { rate = (2.5, 10) }
        else if m.contains("gemini") && m.contains("flash") {  rate = (0.3, 1.0) }
        else if m.contains("gemini") {     rate = (1.25, 5) }
        else {                             rate = (3, 15) } // safe default
        return Double(inputTokens) / 1_000_000 * rate.inUSD
             + Double(outputTokens) / 1_000_000 * rate.outUSD
    }
}

// MARK: - Gate alert modifier

/// Attach to any PowerPack surface that triggers user-initiated AI calls.
/// Presents the per-use confirmation and the budget-block alert.
struct PowerPackAPIUsageGate: ViewModifier {
    @ObservedObject private var usage = PowerPack_APIUsage.shared

    /// Whether this surface should present the gate alerts. A parent that is
    /// currently hosting a child sheet (e.g. the camera) must pass `false` so
    /// the alert presents from the sheet — not the parent. Presenting an alert
    /// on a view that has an active sheet tears the sheet down, which dropped
    /// the user back on an empty Add Carb Entry page and cancelled the analysis.
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .alert("Use AI tokens?", isPresented: Binding(
                get: { isActive && usage.pendingApproval != nil },
                set: { if !$0 { usage.resolvePending(.cancel) } }
            ), presenting: usage.pendingApproval) { pending in
                Button("Continue") { usage.resolvePending(.proceed) }
                Button("Continue — don't ask again\nthis session") { usage.resolvePending(.proceedAllSession) }
                Button("Cancel", role: .cancel) { usage.resolvePending(.cancel) }
            } message: { pending in
                Text(String(format: "%@ will call your AI provider and use your API tokens (about $%.3f). This is billed to your own key.",
                            pending.actionLabel, pending.estCostUSD))
            }
            .alert("Monthly AI budget reached", isPresented: Binding(
                get: { isActive && usage.budgetBlockedMessage != nil },
                set: { if !$0 { usage.budgetBlockedMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(usage.budgetBlockedMessage ?? "")
            }
    }
}

extension View {
    /// Present the PowerPack per-use confirmation + budget-block alerts on this screen.
    /// Pass `isActive: false` while this view is hosting a child sheet that has its
    /// own gate, so the alert presents from the sheet instead of dismissing it.
    func powerPackAPIUsageGate(isActive: Bool = true) -> some View {
        modifier(PowerPackAPIUsageGate(isActive: isActive))
    }
}

// MARK: - Settings controls (plain rows)

/// Token-usage + spend controls as plain leading-aligned rows, designed to drop
/// INTO an existing settings group (e.g. LoopInsights' "Advanced API Settings"
/// DisclosureGroup or a FoodFinder Form section) rather than introduce a new screen.
struct PowerPack_APIUsageControls: View {
    @ObservedObject private var usage = PowerPack_APIUsage.shared
    @State private var budgetEnabled: Bool = PowerPack_APIUsage.shared.monthlyBudgetUSD > 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI TOKEN USAGE")
                .font(.caption).foregroundColor(.secondary)

            Text("These controls apply to all PowerPack AI features (FoodFinder + LoopInsights) — they share one API key and one bill. Changing them here changes them everywhere.")
                .font(.caption2).foregroundColor(.secondary)

            HStack {
                Text("This month (estimated)")
                Spacer()
                Text(String(format: "$%.2f", usage.currentMonthSpendUSD))
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .rounded))
            }
            if budgetEnabled {
                ProgressView(value: usage.budgetUsedFraction)
                    .tint(usage.isOverBudget ? .red : (usage.isNearBudget ? .orange : .green))
            }

            Toggle("Set a monthly budget", isOn: $budgetEnabled)
                .onChange(of: budgetEnabled) { on in
                    usage.monthlyBudgetUSD = on ? max(5, usage.monthlyBudgetUSD) : 0
                }
            if budgetEnabled {
                Stepper(value: $usage.monthlyBudgetUSD, in: 1...100, step: 1) {
                    HStack { Text("Budget"); Spacer()
                        Text(String(format: "$%.0f / mo", usage.monthlyBudgetUSD)).foregroundColor(.secondary) }
                }
                Stepper(value: $usage.warnAtPercent, in: 50...95, step: 5) {
                    HStack { Text("Warn at"); Spacer()
                        Text(String(format: "%.0f%%", usage.warnAtPercent)).foregroundColor(.secondary) }
                }
                Toggle("Block AI when over budget", isOn: $usage.blockWhenOverBudget)
            }

            Divider()

            Toggle("Confirm before each AI request", isOn: $usage.confirmEachRequest)
            Text("Shows a quick confirmation before each AI action (photo scan, Ask Loopy, manual analysis), with a \u{201C}don't ask again this session\u{201D} option.")
                .font(.caption2).foregroundColor(.secondary)

            Divider()

            Text("Ways to use fewer tokens")
                .font(.caption).foregroundColor(.secondary)
            tip("Use Barcode for packaged foods — no AI call.")
            tip("Set Background Monitor to Weekly, or off.")
            tip("Shorter lookback periods send less data per request.")

            Button(role: .destructive) {
                usage.resetThisMonthSpend()
            } label: {
                Text("Reset this month's estimate").font(.caption)
            }
        }
    }

    private func tip(_ text: String) -> some View {
        Label(text, systemImage: "leaf")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}
