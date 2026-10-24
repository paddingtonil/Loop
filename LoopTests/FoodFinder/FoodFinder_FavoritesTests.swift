//
//  FoodFinder_FavoritesTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class FoodFinder_FavoritesTests: XCTestCase {

    func testScannedProductNameIsSuggestedForTheFavorite() {
        XCTAssertEqual(FoodFinder_FavoriteEditHelper.suggestedName(from: "Greek Yogurt"), "Greek Yogurt")
    }

    func testLongProductNamesAreCutToTheFavoriteNameLimit() {
        let name = "Organic Unsweetened Vanilla Almond Milk Beverage"
        let suggested = FoodFinder_FavoriteEditHelper.suggestedName(from: name)
        XCTAssertEqual(suggested?.count, FoodFinder_FavoritesViewModel.maxNameLength)
        XCTAssertTrue(name.hasPrefix(suggested ?? "-"))
    }

    func testBlankProductNameSuggestsNothing() {
        XCTAssertNil(FoodFinder_FavoriteEditHelper.suggestedName(from: "   "))
        XCTAssertNil(FoodFinder_FavoriteEditHelper.suggestedName(from: nil))
    }

    func testProductIsFavoritedWhenANameMatches() {
        XCTAssertTrue(FoodFinder_FavoriteEditHelper.isFavorited(candidateNames: ["Greek Yogurt"], favoriteNames: ["Bagel", "Greek Yogurt"]))
        XCTAssertFalse(FoodFinder_FavoriteEditHelper.isFavorited(candidateNames: ["Greek Yogurt"], favoriteNames: ["Bagel"]))
    }

    /// Favorites are saved with names cut to 30 characters, so the full
    /// product name never equals the saved name for long names.
    func testLongProductNameMatchesItsShortenedFavorite() {
        let name = "Organic Unsweetened Vanilla Almond Milk Beverage"
        let saved = FoodFinder_FavoritesViewModel.truncatedName(name)
        XCTAssertTrue(FoodFinder_FavoriteEditHelper.isFavorited(candidateNames: [name], favoriteNames: [saved]))
    }

    func testMatchIgnoresSurroundingWhitespace() {
        XCTAssertTrue(FoodFinder_FavoriteEditHelper.isFavorited(candidateNames: ["Bagel "], favoriteNames: ["Bagel"]))
    }

    func testEmptyNamesNeverMatch() {
        XCTAssertFalse(FoodFinder_FavoriteEditHelper.isFavorited(candidateNames: ["", "  "], favoriteNames: [""]))
    }
}
