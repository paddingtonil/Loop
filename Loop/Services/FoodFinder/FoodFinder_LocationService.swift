//
//  FoodFinder_LocationService.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — One-shot GPS capture + reverse geocode for meal location tagging.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation
import CoreLocation
import MapKit
import Combine
import os.log

/// Captures venue-level location when FoodFinder opens, reverse-geocodes it to a
/// restaurant/business name, and provides prompt context for the AI analysis.
///
/// Privacy-first design:
/// - Feature off by default; only requests permission after user enables toggle
/// - One-shot `requestLocation()` — not continuous tracking
/// - `kCLLocationAccuracyHundredMeters` — venue-level, not GPS-precise
/// - Data local-only — coordinates never leave the device
final class FoodFinder_LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - Singleton

    static let shared = FoodFinder_LocationService()

    // MARK: - Published State

    @Published private(set) var latitude: Double?
    @Published private(set) var longitude: Double?
    @Published private(set) var locationName: String?
    @Published private(set) var cityName: String?
    @Published private(set) var countryName: String?
    @Published private(set) var isResolving: Bool = false

    /// Distance (meters) to the matched restaurant, when one was confirmed
    /// within `Self.maxVenueDistanceMeters`. `nil` if no nearby restaurant.
    @Published private(set) var matchedVenueDistanceMeters: CLLocationDistance?

    /// True only when GPS confirms a restaurant within 200 ft. Gates the
    /// menu-first lookup and restaurant-specific prompt context.
    var isAtKnownRestaurant: Bool { matchedVenueDistanceMeters != nil }

    /// All food venues within `maxVenueDistanceMeters`, closest first, deduped.
    /// Drives the "which restaurant?" picker — the user may be between two spots,
    /// so we offer every nearby match instead of silently assuming the closest.
    @Published private(set) var nearbyVenues: [String] = []

    // MARK: - Private

    /// Hard radius for restaurant geo-tagging. 200 feet ≈ 60.96 m. MKLocalSearch
    /// treats its region as a *bias*, not a filter, so it happily returns venues
    /// miles away — we must reject anything beyond this ourselves.
    static let maxVenueDistanceMeters: CLLocationDistance = 61

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let log = OSLog(category: "FoodFinder_Location")

    // MARK: - Init

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: - Public API

    /// Requests a one-shot location fix if the feature flag is enabled and
    /// the user has granted (or not yet denied) location permission.
    /// Called from `FoodFinder_EntryPoint.onAppear`.
    func requestLocationIfEnabled() {
        guard FoodFinder_FeatureFlags.locationTaggingEnabled else { return }

        // Skip if we already have a resolved location or are currently resolving
        guard locationName == nil && cityName == nil && !isResolving else { return }

        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocationRequest()
        case .denied, .restricted:
            os_log("Location permission denied/restricted — skipping", log: log, type: .info)
        @unknown default:
            break
        }
    }

    /// Clears captured location data. Call when FoodFinder is dismissed.
    func clearLocation() {
        latitude = nil
        longitude = nil
        locationName = nil
        cityName = nil
        countryName = nil
        matchedVenueDistanceMeters = nil
        nearbyVenues = []
        isResolving = false
    }

    /// Returns a prompt snippet with restaurant/location context for the AI,
    /// or an empty string if no location is available.
    func locationContextForPrompt() -> String {
        guard FoodFinder_FeatureFlags.locationTaggingEnabled else { return "" }

        // Build region string (e.g. "Athens, Greece") even if venue name is missing
        var regionParts: [String] = []
        if let city = cityName, !city.isEmpty { regionParts.append(city) }
        if let country = countryName, !country.isEmpty { regionParts.append(country) }
        let region = regionParts.isEmpty ? nil : regionParts.joined(separator: ", ")

        let venueName = (locationName?.isEmpty == false) ? locationName : nil

        // Need at least one piece of location info
        guard venueName != nil || region != nil else { return "" }

        var ctx = "LOCATION CONTEXT (read first — applies regardless of image_type):\n"

        if let venue = venueName, let reg = region {
            ctx += "The user's GPS places them at or near \"\(venue)\" in \(reg).\n"
        } else if let venue = venueName {
            ctx += "The user's GPS places them at or near \"\(venue)\".\n"
        } else if let reg = region {
            ctx += "The user's GPS places them in \(reg).\n"
        }

        ctx += """
        Use this location to improve your analysis. The following rules apply \
        whether image_type is "food_photo" or "menu_item":
        1. REGIONAL CUISINE: Identify the food using local/regional dish names and preparation styles \
        typical of this area. A pastry in Athens is more likely tiropita or bougatsa than a generic phyllo roll.
        2. RESTAURANT MATCH: If the GPS venue name matches a known restaurant, reference their menu \
        for more accurate nutrition data instead of generic USDA values.
        3. CROSS-REFERENCE: Also look for restaurant names, logos, or branding visible in the image \
        (on napkins, plates, menus, receipts, signage). If you find a name that matches or confirms \
        the GPS location, use that restaurant's known menu items for identification and nutrition.
        4. TITLE FORMAT (REQUIRED): Include the restaurant/venue name in the food title, e.g.: \
        "Carne Asada (grilled) – Casa de Bandini" so the user can see where it came from at a glance. \
        Apply this even for image_type="menu_item".
        5. LOCATION NOTE (REQUIRED): Begin your "diabetes_considerations" field with this exact \
        location line, then continue with your normal guidance: \
        "📍 \(buildLocationLabel()). "
        6. ASSESSMENT NOTES: Mention the GPS-based identification in assessment_notes, e.g.: \
        "GPS placed user at \(buildLocationLabel()) — matched the visible pizza to their pepperoni pie."

        END LOCATION CONTEXT

        """

        return ctx
    }

    /// Builds a compact label like "Ciel, Athens, Greece" or "Athens, Greece".
    private func buildLocationLabel() -> String {
        var parts: [String] = []
        if let name = locationName, !name.isEmpty { parts.append(name) }
        if let city = cityName, !city.isEmpty, city != locationName { parts.append(city) }
        if let country = countryName, !country.isEmpty { parts.append(country) }
        return parts.isEmpty ? "Unknown" : parts.joined(separator: ", ")
    }

    // MARK: - Private Helpers

    private func beginLocationRequest() {
        isResolving = true
        locationManager.requestLocation()
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    os_log("Reverse geocode failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                    self.isResolving = false
                    return
                }

                // Only use venue/POI names — skip bare street addresses
                if let placemark = placemarks?.first {
                    var name = placemark.name ?? placemark.areasOfInterest?.first

                    // CoreLocation sometimes returns a street address as `name`
                    // when there's no POI — discard it so we don't send
                    // meaningless addresses to the AI prompt.
                    if let n = name, let street = placemark.thoroughfare, n == street {
                        name = nil
                    }
                    // Also discard if name looks like a street number + name pattern
                    // (e.g. "1234 Oak Ave") with no business context
                    if let n = name, let street = placemark.thoroughfare,
                       n.hasPrefix(street) || n.hasSuffix(street) {
                        name = nil
                    }

                    self.locationName = name
                    self.cityName = placemark.locality
                    self.countryName = placemark.country
                    #if DEBUG
                    print("📍 FoodFinder Geocode: \(name ?? "unknown"), \(placemark.locality ?? "?"), \(placemark.country ?? "?") (\(self.latitude ?? 0), \(self.longitude ?? 0))")
                    #endif
                }

                // Refine with MapKit local search for nearby restaurants/food venues
                self.searchNearbyFoodVenues(location)
            }
        }
    }

    /// Uses MKLocalSearch to find the closest restaurant/food venue and accepts
    /// it ONLY if it sits within `maxVenueDistanceMeters` (200 ft). MKLocalSearch's
    /// region is a bias, not a hard filter, so it returns venues miles away — we
    /// reject those ourselves. If no restaurant is genuinely within 200 ft, we
    /// clear the venue name so the AI prompt doesn't claim a restaurant we aren't at.
    private func searchNearbyFoodVenues(_ location: CLLocation) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "restaurant"
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 200,
            longitudinalMeters: 200
        )
        request.resultTypes = .pointOfInterest

        MKLocalSearch(request: request).start { [weak self] response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                defer { self.isResolving = false }

                // Every food venue within the 200 ft radius, closest first.
                let withinRadius = (response?.mapItems ?? [])
                    .compactMap { item -> (name: String, distance: CLLocationDistance)? in
                        guard let name = item.name, !name.isEmpty,
                              let itemLoc = item.placemark.location else { return nil }
                        let distance = location.distance(from: itemLoc)
                        return distance <= Self.maxVenueDistanceMeters ? (name, distance) : nil
                    }
                    .sorted { $0.distance < $1.distance }

                // Dedupe names while preserving the closest-first order.
                var seen = Set<String>()
                self.nearbyVenues = withinRadius.map { $0.name }.filter { seen.insert($0).inserted }

                // The closest match gates the prompt context (unchanged behavior).
                guard let match = withinRadius.first else {
                    #if DEBUG
                    print("📍 FoodFinder MapKit: no restaurants within 200ft, not tagging")
                    #endif
                    self.locationName = nil
                    self.matchedVenueDistanceMeters = nil
                    return
                }

                #if DEBUG
                print("📍 FoodFinder MapKit: \(self.nearbyVenues.count) venue(s) within 200ft; closest \"\(match.name)\" \(Int(match.distance))m")
                #endif
                self.locationName = match.name
                self.matchedVenueDistanceMeters = match.distance
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        reverseGeocode(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        os_log("Location request failed: %{public}@", log: log, type: .error, error.localizedDescription)
        isResolving = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // If the user just granted permission (from the .notDetermined prompt),
        // proceed with the location request.
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            beginLocationRequest()
        }
    }
}
