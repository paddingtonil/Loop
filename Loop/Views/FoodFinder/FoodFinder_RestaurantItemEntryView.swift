//
//  FoodFinder_RestaurantItemEntryView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Shown when GPS confirms the user within 200 ft of a restaurant.
//  Asks which restaurant (detected nearby, or typed) and what they ordered, then
//  looks up authoritative menu nutrition via Spoonacular — skipping AI tokens.
//  If no menu/item match is found, the user falls back to AI photo analysis.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import SwiftUI

/// Restaurant + item entry step for the menu-first path. Self-contained: collects
/// the restaurant and dish, searches Spoonacular, confirms the match, and reports
/// the chosen item's nutrition (as an `AIFoodAnalysisResult`) — or a request to
/// fall back to AI when nothing matches.
struct FoodFinder_RestaurantItemEntryView: View {

    /// Food venues GPS placed within 200 ft, closest first. May be empty.
    let nearbyRestaurants: [String]
    /// Called with the chosen menu item's nutrition, ready to populate carb entry.
    let onPicked: (AIFoodAnalysisResult) -> Void
    /// Called when the user wants AI photo analysis instead (no menu match).
    let onUseAI: () -> Void
    /// Called when the user wants to browse the restaurant's full menu list.
    let onBrowseFullMenu: (String) -> Void

    private let purple = Color(red: 107/255, green: 47/255, blue: 160/255)

    /// Drives which sub-view is shown. `.noMatch` keeps the form up so the user
    /// can correct a typo and retry without losing context.
    private enum Phase { case entry, searching, results, noMatch }

    @State private var restaurant: String
    @State private var item: String = ""
    @State private var phase: Phase = .entry
    @State private var matches: [FoodFinder_SpoonacularService.MenuItem] = []
    @State private var errorText: String?
    /// id of the match currently fetching nutrition (row spinner).
    @State private var fetchingItemID: Int?

    init(
        nearbyRestaurants: [String],
        onPicked: @escaping (AIFoodAnalysisResult) -> Void,
        onUseAI: @escaping () -> Void,
        onBrowseFullMenu: @escaping (String) -> Void
    ) {
        self.nearbyRestaurants = nearbyRestaurants
        self.onPicked = onPicked
        self.onUseAI = onUseAI
        self.onBrowseFullMenu = onBrowseFullMenu
        _restaurant = State(initialValue: nearbyRestaurants.first ?? "")
    }

    private var canSearch: Bool {
        !restaurant.trimmingCharacters(in: .whitespaces).isEmpty &&
        !item.trimmingCharacters(in: .whitespaces).isEmpty &&
        fetchingItemID == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            switch phase {
            case .entry, .noMatch:
                entryForm
            case .searching:
                searchingState
            case .results:
                resultsList
            }

            Spacer(minLength: 0)

            bottomButtons
                .padding(.horizontal)
                .padding(.bottom, 20)
                .padding(.top, 8)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill").foregroundColor(purple)
                Text("Looks like you're dining out")
                    .font(.headline)
            }
            Text("Tell us the spot and your dish to use its menu nutrition — no AI tokens used.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.horizontal)
    }

    private var entryForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Restaurant — quick-pick chips for nearby venues, plus free text.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Restaurant").font(.subheadline).fontWeight(.semibold)
                    if nearbyRestaurants.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(nearbyRestaurants, id: \.self) { name in
                                    chip(name)
                                }
                            }
                        }
                    }
                    TextField("Restaurant name", text: $restaurant)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                // Food item.
                VStack(alignment: .leading, spacing: 8) {
                    Text("What did you order?").font(.subheadline).fontWeight(.semibold)
                    TextField("e.g. Chicken Burrito Bowl", text: $item)
                        .textFieldStyle(.roundedBorder)
                }

                if case .noMatch = phase {
                    noMatchNotice
                }

                Button(action: search) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Find menu nutrition").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSearch ? purple : Color(.systemGray3))
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(!canSearch)
            }
            .padding(.horizontal)
            .padding(.top, 20)
        }
    }

    private func chip(_ name: String) -> some View {
        Button { restaurant = name } label: {
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(restaurant == name ? purple.opacity(0.15) : Color(.systemGray6))
                .foregroundColor(restaurant == name ? purple : .primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(restaurant == name ? purple : Color.clear, lineWidth: 1)
                )
                .cornerRadius(14)
        }
    }

    private var noMatchNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(errorText ?? "No match found. Check the spelling, or analyze your photo with AI below.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }

    private var searchingState: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text("Searching \(restaurant)'s menu…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            Text("Tap the match for \"\(item)\" to use its menu nutrition.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
                .padding(.horizontal)

            List(matches) { match in
                Button { pick(match) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.title)
                                .font(.body)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                            if let chain = match.restaurantChain, !chain.isEmpty {
                                Text(chain).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if fetchingItemID == match.id {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(fetchingItemID != nil)
            }
            .listStyle(.plain)

            Button {
                phase = .entry
                errorText = nil
            } label: {
                Text("← Edit restaurant or item").font(.subheadline)
            }
            .padding(.top, 4)
        }
    }

    private var bottomButtons: some View {
        VStack(spacing: 10) {
            // Browse the full menu when the user doesn't remember the exact name.
            if !restaurant.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    onBrowseFullMenu(restaurant.trimmingCharacters(in: .whitespaces))
                } label: {
                    Text("Browse \(restaurant)'s full menu")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(purple, lineWidth: 1))
                        .foregroundColor(purple)
                }
                .disabled(fetchingItemID != nil)
            }

            Button(action: onUseAI) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Analyze my photo with AI instead").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(purple)
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .disabled(fetchingItemID != nil)
            .opacity(fetchingItemID != nil ? 0.5 : 1.0)
        }
    }

    // MARK: - Actions

    private func search() {
        let venue = restaurant.trimmingCharacters(in: .whitespaces)
        let dish = item.trimmingCharacters(in: .whitespaces)
        guard !venue.isEmpty, !dish.isEmpty else { return }

        phase = .searching
        errorText = nil
        Task {
            do {
                let results = try await FoodFinder_SpoonacularService.shared
                    .searchMenuItems(restaurant: venue, item: dish)
                await MainActor.run {
                    if results.isEmpty {
                        self.errorText = "Couldn't find \"\(dish)\" at \(venue) in the menu database."
                        self.phase = .noMatch
                    } else {
                        self.matches = results
                        self.phase = .results
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.phase = .noMatch
                }
            }
        }
    }

    private func pick(_ match: FoodFinder_SpoonacularService.MenuItem) {
        guard fetchingItemID == nil else { return }
        fetchingItemID = match.id
        Task {
            do {
                let result = try await FoodFinder_SpoonacularService.shared
                    .fetchNutrition(itemId: match.id, fallbackName: match.title)
                await MainActor.run { onPicked(result) }
            } catch {
                await MainActor.run {
                    self.fetchingItemID = nil
                    self.errorText = error.localizedDescription
                    self.phase = .noMatch
                }
            }
        }
    }
}
