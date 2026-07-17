//
//  FoodFinder_RestaurantMenuView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Tap-to-pick restaurant menu list. Shown when GPS confirms the
//  user within 200 ft of a (chain) restaurant and a Spoonacular key is set.
//  Picking an item uses authoritative menu nutrition and skips AI image
//  analysis. If nothing matches, the user falls back to AI on their photo.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import SwiftUI

/// Inline menu picker for a confirmed nearby restaurant. Self-contained: loads
/// its own items, handles loading/empty/error, and reports the chosen item's
/// nutrition (as an `AIFoodAnalysisResult`) or a request to fall back to AI.
struct FoodFinder_RestaurantMenuView: View {

    let restaurantName: String
    /// Called with the chosen menu item's nutrition, ready to populate carb entry.
    let onPicked: (AIFoodAnalysisResult) -> Void
    /// Called when the user wants the AI photo analysis instead (no menu match).
    let onUseAI: () -> Void

    private let purple = Color(red: 107/255, green: 47/255, blue: 160/255)

    @State private var items: [FoodFinder_SpoonacularService.MenuItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// id of the item currently fetching nutrition (row spinner).
    @State private var fetchingItemID: Int?

    var body: some View {
        VStack(spacing: 0) {
            header

            if isLoading {
                loadingState
            } else if let loadError {
                messageState(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't load the menu",
                    detail: loadError
                )
            } else if items.isEmpty {
                messageState(
                    icon: "fork.knife",
                    title: "No menu found for \(restaurantName)",
                    detail: "This spot may not be in the menu database (it's chain-focused). Analyze your photo with AI instead."
                )
            } else {
                menuList
            }

            Spacer(minLength: 0)

            aiFallbackButton
                .padding(.horizontal)
                .padding(.bottom, 20)
                .padding(.top, 8)
        }
        .task { await loadMenu() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill").foregroundColor(purple)
                Text(restaurantName)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text("Tap your item to use its menu nutrition — no AI tokens used.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.horizontal)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text("Loading \(restaurantName) menu…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func messageState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 48)
    }

    private var menuList: some View {
        List(items) { item in
            Button {
                pick(item)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.body)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                        if let chain = item.restaurantChain, !chain.isEmpty {
                            Text(chain)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if fetchingItemID == item.id {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(fetchingItemID != nil)
        }
        .listStyle(.plain)
    }

    private var aiFallbackButton: some View {
        Button(action: onUseAI) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Not here — analyze my photo with AI")
                    .fontWeight(.semibold)
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

    // MARK: - Actions

    private func loadMenu() async {
        isLoading = true
        loadError = nil
        do {
            let results = try await FoodFinder_SpoonacularService.shared
                .searchMenuItems(restaurant: restaurantName)
            await MainActor.run {
                self.items = results
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func pick(_ item: FoodFinder_SpoonacularService.MenuItem) {
        guard fetchingItemID == nil else { return }
        fetchingItemID = item.id
        Task {
            do {
                let result = try await FoodFinder_SpoonacularService.shared
                    .fetchNutrition(itemId: item.id, fallbackName: item.title)
                await MainActor.run { onPicked(result) }
            } catch {
                await MainActor.run {
                    self.fetchingItemID = nil
                    self.loadError = error.localizedDescription
                }
            }
        }
    }
}
