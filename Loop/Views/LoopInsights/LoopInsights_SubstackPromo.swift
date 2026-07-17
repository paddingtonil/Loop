//
//  LoopInsights_SubstackPromo.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  Shared UI components for inviting users to subscribe to the PowerPack
//  Substack. Used by every feature's settings view (footer card) and as a
//  one-time onboarding sheet on first launch of the LoopInsights dashboard.
//
//  Implementation note: subscription happens in SFSafariViewController
//  pointed at Substack's normal subscribe page. We never collect emails
//  in-app, never embed admin session cookies, never proxy through any
//  server — Substack's own form does everything. Privacy-respecting,
//  Apple-approved pattern.
//
//  Subscription state: PowerPack has no way to query Substack's
//  subscriber list (no public API for that, and embedding the publication
//  admin session cookie would be a security disaster). So "is the user
//  subscribed" is tracked via UserDefaults, set in two ways:
//    • Implicit: after the user taps "Subscribe" and dismisses the Safari
//      sheet, we ask "Did you subscribe?" — Yes flips the flag.
//    • Explicit: a small "I've already subscribed" link in the footer,
//      for users who subscribed via desktop, a friend's link, etc.
//  When subscribed: onboarding sheet is suppressed and the footer flips
//  to a checkmark-styled "you're subscribed, tap to read" card pointed
//  at the publication's home page (archive) instead of the subscribe page.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import SwiftUI
import SafariServices

// MARK: - Configuration

enum LoopInsights_SubstackPromo {

    /// Substack publication subscribe URL. Used when the user hasn't yet
    /// subscribed — opens Substack's signup form.
    static let subscribeURL = URL(string: "https://taylor256.substack.com/subscribe")!

    /// Publication landing page. Used when the user IS subscribed — they
    /// get the article archive instead of the signup form.
    static let homeURL = URL(string: "https://taylor256.substack.com")!

    /// UserDefaults key — tracks whether the user has been shown the
    /// onboarding sheet at least once. Sheet auto-presents on first
    /// dashboard appearance, then never again (whether they subscribed or
    /// dismissed).
    static let onboardingShownKey = "PowerPack_HasSeenSubstackOnboarding"

    /// UserDefaults key — tracks whether the user has indicated they're a
    /// Substack subscriber. See the file header for how/when this gets set.
    static let subscribedKey = "PowerPack_HasSubscribedToSubstack"

    static var hasSeenOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: onboardingShownKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardingShownKey) }
    }

    static var isSubscribed: Bool {
        get { UserDefaults.standard.bool(forKey: subscribedKey) }
        set { UserDefaults.standard.set(newValue, forKey: subscribedKey) }
    }
}

// MARK: - Footer (always visible at the bottom of every settings view)

/// Compact card that lives at the bottom of each feature's settings view.
/// Two visual states:
///   • Not subscribed: "Tap to subscribe" with a newspaper icon
///   • Subscribed: checkmark icon + "You're subscribed — tap to read the latest"
///
/// Subscribed-state taps open the publication home page (article archive);
/// not-subscribed taps open the subscribe page. After dismissing Safari from
/// the not-subscribed state, we ask "Did you subscribe?" — confirming flips
/// the persistent flag. Subscribed users also see no further prompts.
///
/// Below the card, not-subscribed users see a small "I've already
/// subscribed" link for the case where they signed up elsewhere (desktop,
/// a friend's share link, etc.).
struct LoopInsights_SubstackPromoFooter: View {

    @AppStorage(LoopInsights_SubstackPromo.subscribedKey) private var isSubscribed: Bool = false

    @State private var showingSafari = false
    @State private var showingDidSubscribePrompt = false
    @State private var showingAlreadySubscribedConfirm = false

    private let accent = Color(red: 26/255, green: 138/255, blue: 158/255)

    var body: some View {
        Section {
            Button(action: { showingSafari = true }) {
                HStack(spacing: 12) {
                    Image(systemName: isSubscribed ? "checkmark.seal.fill" : "newspaper.fill")
                        .font(.title3)
                        .foregroundColor(isSubscribed ? .green : accent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isSubscribed
                             ? NSLocalizedString("PowerPack writeups", comment: "Substack footer title (subscribed)")
                             : NSLocalizedString("PowerPack writeups on Substack", comment: "Substack footer title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(isSubscribed
                             ? NSLocalizedString("You're subscribed — tap to read the latest.", comment: "Substack footer subtitle (subscribed)")
                             : NSLocalizedString("Free deep-dives on every feature. Tap to subscribe.", comment: "Substack footer subtitle"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if !isSubscribed {
                Button(action: { showingAlreadySubscribedConfirm = true }) {
                    Text(NSLocalizedString("I've already subscribed", comment: "Substack footer 'already subscribed' opt-out link"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingSafari, onDismiss: {
            // After Safari dismisses from the not-subscribed state, ask the
            // user if they completed the signup. If they're already marked,
            // skip the prompt — they were just reading the archive.
            if !isSubscribed {
                showingDidSubscribePrompt = true
            }
        }) {
            LoopInsights_SafariView(url: isSubscribed
                ? LoopInsights_SubstackPromo.homeURL
                : LoopInsights_SubstackPromo.subscribeURL)
                .ignoresSafeArea()
        }
        .alert(NSLocalizedString("Did you subscribe?", comment: "Substack post-Safari prompt title"),
               isPresented: $showingDidSubscribePrompt) {
            Button(NSLocalizedString("Yes, I subscribed", comment: "Substack post-Safari prompt confirm")) {
                isSubscribed = true
            }
            Button(NSLocalizedString("Not yet", comment: "Substack post-Safari prompt deny"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("Tap 'Yes' to hide the subscribe prompts. You can still come back here to read the writeups anytime.", comment: "Substack post-Safari prompt body"))
        }
        .alert(NSLocalizedString("Already subscribed?", comment: "Substack 'already subscribed' confirm title"),
               isPresented: $showingAlreadySubscribedConfirm) {
            Button(NSLocalizedString("Yes, I'm subscribed", comment: "Substack 'already subscribed' confirm")) {
                isSubscribed = true
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("This hides the subscribe prompts across PowerPack. You can always tap the card to read the latest writeups.", comment: "Substack 'already subscribed' confirm body"))
        }
    }
}

// MARK: - Onboarding sheet (first launch only)

/// Full-screen sheet shown ONCE the first time the user opens the
/// LoopInsights dashboard. Persistent dismissal via UserDefaults; subsequent
/// access is via the footer in any settings view. Also auto-suppresses if
/// `LoopInsights_SubstackPromo.isSubscribed` is already true (handled by
/// the dashboard's onAppear gate, not here).
struct LoopInsights_SubstackOnboardingSheet: View {

    let onDismiss: () -> Void

    @AppStorage(LoopInsights_SubstackPromo.subscribedKey) private var isSubscribed: Bool = false

    @State private var showingSafari = false
    @State private var showingDidSubscribePrompt = false

    private let accent = Color(red: 26/255, green: 138/255, blue: 158/255)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "newspaper.fill")
                        .font(.system(size: 64))
                        .foregroundColor(accent)
                        .padding(.top, 24)

                    Text(NSLocalizedString("Want to know what each feature does, and why?", comment: "Substack onboarding sheet title"))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 16) {
                        bulletRow(icon: "doc.text.fill",
                                  title: NSLocalizedString("Deep-dive writeups", comment: "Substack onboarding bullet 1 title"),
                                  body: NSLocalizedString("One per feature — FoodFinder, LoopInsights, AutoPresets, BolusPro, SiteAtlas, Meal Debrief. Plus the install-without-a-Mac guide.", comment: "Substack onboarding bullet 1 body"))

                        bulletRow(icon: "chart.bar.doc.horizontal.fill",
                                  title: NSLocalizedString("The receipts posts", comment: "Substack onboarding bullet 2 title"),
                                  body: NSLocalizedString("AI vs human carb counting accuracy (50 meals, kitchen-scale ground truth). AI vs clinical norms on therapy settings (8 windows, my own data, my own endo).", comment: "Substack onboarding bullet 2 body"))

                        bulletRow(icon: "dollarsign.circle.fill",
                                  title: NSLocalizedString("Cost and privacy, with numbers", comment: "Substack onboarding bullet 3 title"),
                                  body: NSLocalizedString("Exactly what runs the AI features per month and exactly what data leaves your device.", comment: "Substack onboarding bullet 3 body"))
                    }
                    .padding(.horizontal)

                    VStack(spacing: 8) {
                        Button(action: {
                            LoopInsights_SubstackPromo.hasSeenOnboarding = true
                            showingSafari = true
                        }) {
                            Text(NSLocalizedString("Subscribe (free)", comment: "Substack onboarding primary CTA"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(accent)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        }

                        Button(action: {
                            LoopInsights_SubstackPromo.hasSeenOnboarding = true
                            onDismiss()
                        }) {
                            Text(NSLocalizedString("Maybe later", comment: "Substack onboarding dismiss"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 10)
                        }

                        Button(action: {
                            isSubscribed = true
                            LoopInsights_SubstackPromo.hasSeenOnboarding = true
                            onDismiss()
                        }) {
                            Text(NSLocalizedString("I'm already subscribed", comment: "Substack onboarding 'already subscribed' link"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal)

                    Text(NSLocalizedString("You can always subscribe later from the bottom of any feature's Settings screen.", comment: "Substack onboarding footer note"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showingSafari, onDismiss: {
            // After Safari closes, ask if they actually subscribed. Once
            // confirmed, dismiss the onboarding sheet. If not, leave the
            // onboarding sheet up so they can pick another action.
            showingDidSubscribePrompt = true
        }) {
            LoopInsights_SafariView(url: LoopInsights_SubstackPromo.subscribeURL)
                .ignoresSafeArea()
        }
        .alert(NSLocalizedString("Did you subscribe?", comment: "Substack onboarding post-Safari prompt title"),
               isPresented: $showingDidSubscribePrompt) {
            Button(NSLocalizedString("Yes, I subscribed", comment: "Substack onboarding post-Safari prompt confirm")) {
                isSubscribed = true
                onDismiss()
            }
            Button(NSLocalizedString("Not yet", comment: "Substack onboarding post-Safari prompt deny"), role: .cancel) {
                // Leave the onboarding sheet visible so the user can try
                // again or pick "Maybe later".
            }
        } message: {
            Text(NSLocalizedString("Tap 'Yes' if you completed signup. You can always come back here later if you change your mind.", comment: "Substack onboarding post-Safari prompt body"))
        }
    }

    private func bulletRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(body)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - SFSafariViewController SwiftUI wrapper

/// Minimal SwiftUI wrapper around SFSafariViewController. Used by both the
/// footer button and the onboarding sheet's "Subscribe" CTA.
///
/// SFSafariViewController is Apple's blessed pattern for showing web content
/// without leaving the app. It uses Safari's cookie jar, supports Apple ID
/// autofill, and never shares state back with the host app — the user's
/// Substack email never touches PowerPack code.
struct LoopInsights_SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(red: 26/255, green: 138/255, blue: 158/255, alpha: 1.0)
        vc.dismissButtonStyle = .done
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
