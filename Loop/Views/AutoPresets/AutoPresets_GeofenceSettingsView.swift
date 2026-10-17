//
//  AutoPresets_GeofenceSettingsView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  AutoPresets — Settings UI for geofence-based preset activation.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import CoreLocation
import LoopKit
import MapKit
import SwiftUI

// MARK: - Main Geofence Settings View

struct AutoPresets_GeofenceSettingsView: View {
    @ObservedObject private var geofenceManager = AutoPresets_GeofenceManager.shared
    @ObservedObject private var coordinator = AutoPresets_Coordinator.shared
    @State private var showingAddLocation = false

    var body: some View {
        List {
            enableSection
            if geofenceManager.isEnabled {
                authorizationSection
                locationsSection
                infoSection
            }
        }
        .navigationTitle("Location Triggers")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddLocation) {
            NavigationView {
                AutoPresets_GeofenceEditView(
                    location: nil,
                    availablePresets: coordinator.availablePresets()
                )
            }
        }
    }

    // MARK: - Enable Section

    private var enableSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { geofenceManager.isEnabled },
                set: { geofenceManager.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location Triggers")
                        .font(.headline)
                    Text("Automatically activate presets when you arrive at or leave saved locations.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Authorization Section

    @ViewBuilder
    private var authorizationSection: some View {
        if !geofenceManager.hasAlwaysAuthorization {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "location.slash.fill")
                            .foregroundColor(.orange)
                        Text("Location Permission Required")
                            .font(.headline)
                    }

                    if geofenceManager.authorizationStatus == .notDetermined {
                        Text("AutoPresets needs \"Always\" location access to monitor geofences in the background.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Allow Location Access") {
                            geofenceManager.requestAuthorization()
                        }
                        .font(.body.weight(.medium))
                    } else if geofenceManager.authorizationStatus == .authorizedWhenInUse {
                        Text("Background monitoring requires \"Always\" access. Go to Settings → Loop → Location → Always.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.body.weight(.medium))
                    } else {
                        Text("Location access was denied. Go to Settings → Loop → Location to enable it.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.body.weight(.medium))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Locations Section

    private var locationsSection: some View {
        Section {
            if geofenceManager.locations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No locations saved")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Add a location to get started.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(geofenceManager.locations) { location in
                    NavigationLink {
                        AutoPresets_GeofenceEditView(
                            location: location,
                            availablePresets: coordinator.availablePresets()
                        )
                    } label: {
                        locationRow(location)
                    }
                }
                .onDelete { offsets in
                    geofenceManager.removeLocations(at: offsets)
                }
            }

            Button {
                showingAddLocation = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(Color(red: 76/255, green: 175/255, blue: 80/255))
                    Text("Add Location")
                        .foregroundColor(Color(red: 76/255, green: 175/255, blue: 80/255))
                }
            }
            .disabled(!geofenceManager.hasAlwaysAuthorization)
        } header: {
            Text("Saved Locations")
        } footer: {
            Text("iOS supports up to 20 monitored regions per app. You have \(geofenceManager.locations.filter(\.isEnabled).count) active.")
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("How it works", systemImage: "info.circle")
                    .font(.subheadline.weight(.medium))
                Text("When your iPhone detects you've entered or left a saved location, the assigned preset activates automatically. This uses iOS region monitoring which is battery-efficient — no continuous GPS tracking.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Label("Safety", systemImage: "shield.checkmark")
                    .font(.subheadline.weight(.medium))
                Text("A geofence will never override a preset you've manually activated. All activations appear in the AutoPresets activity log.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Location Row

    private func locationRow(_ location: AutoPresetsGeofenceLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundColor(location.isEnabled ? Color(red: 76/255, green: 175/255, blue: 80/255) : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .font(.body.weight(.medium))

                HStack(spacing: 4) {
                    Image(systemName: location.triggerType.iconName)
                        .font(.caption2)
                    Text(location.triggerType.displayName)
                        .font(.caption)

                    if let preset = coordinator.availablePresets().first(where: { $0.id.uuidString == location.presetId }) {
                        Text("→ \(preset.symbol) \(preset.name)")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            if !location.isEnabled {
                Text("Off")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Edit / Add Location View

struct AutoPresets_GeofenceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var geofenceManager = AutoPresets_GeofenceManager.shared

    // Editing state
    @State private var name: String
    @State private var latitude: Double
    @State private var longitude: Double
    @State private var radius: Double
    @State private var triggerType: AutoPresetsGeofenceTrigger
    @State private var selectedPresetId: String
    @State private var deactivateOnExit: Bool
    @State private var isEnabled: Bool
    @State private var hasSetLocation: Bool

    // Map state
    @State private var region: MKCoordinateRegion
    @State private var showingDeleteConfirm = false
    @State private var showingPlaceSearch = false

    private let existingLocation: AutoPresetsGeofenceLocation?
    private let availablePresets: [TemporaryScheduleOverridePreset]
    private var isEditing: Bool { existingLocation != nil }

    init(location: AutoPresetsGeofenceLocation?, availablePresets: [TemporaryScheduleOverridePreset]) {
        self.existingLocation = location
        self.availablePresets = availablePresets

        let loc = location
        _name = State(initialValue: loc?.name ?? "")
        _latitude = State(initialValue: loc?.latitude ?? 0)
        _longitude = State(initialValue: loc?.longitude ?? 0)
        _radius = State(initialValue: loc?.radius ?? 100)
        _triggerType = State(initialValue: loc?.triggerType ?? .onEntry)
        _selectedPresetId = State(initialValue: loc?.presetId ?? "")
        _deactivateOnExit = State(initialValue: loc?.deactivateOnExit ?? true)
        _isEnabled = State(initialValue: loc?.isEnabled ?? true)
        _hasSetLocation = State(initialValue: loc != nil)

        let center = loc.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        _region = State(initialValue: MKCoordinateRegion(
            center: center,
            latitudinalMeters: 500,
            longitudinalMeters: 500
        ))
    }

    var body: some View {
        Form {
            nameSection
            locationSection
            radiusSection
            triggerSection
            presetSection
            if isEditing {
                enableSection
                deleteSection
            }
        }
        .navigationTitle(isEditing ? "Edit Location" : "Add Location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if !isEditing {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Add") {
                    saveLocation()
                }
                .disabled(!canSave)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .autoPresetsGeofenceLocationUpdated)) { notification in
            if let location = notification.userInfo?["location"] as? CLLocation {
                latitude = location.coordinate.latitude
                longitude = location.coordinate.longitude
                region = MKCoordinateRegion(
                    center: location.coordinate,
                    latitudinalMeters: 500,
                    longitudinalMeters: 500
                )
                hasSetLocation = true
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section("Name") {
            HStack {
                TextField("e.g. Gym, Office, Park", text: $name)
                    .textFieldStyle(.automatic)
                AutoPresets_ClearTextButton(text: $name)
            }
        }
    }

    private var locationSection: some View {
        Section {
            // Map
            Map(coordinateRegion: $region, annotationItems: hasSetLocation ? [MapPin(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))] : []) { pin in
                MapMarker(coordinate: pin.coordinate, tint: Color(red: 76/255, green: 175/255, blue: 80/255))
            }
            .frame(height: 200)
            .cornerRadius(8)
            .overlay(alignment: .center) {
                // Crosshair marks the point "Pin Map Center" saves.
                Image(systemName: "plus")
                    .font(.title3.weight(.light))
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            }

            // Search for an address or place
            Button {
                showingPlaceSearch = true
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Search Address or Place")
                }
            }
            .sheet(isPresented: $showingPlaceSearch) {
                // The map starts on a placeholder city until a location is set; don't rank results near it.
                AutoPresets_PlaceSearchView(searchRegion: hasSetLocation ? region : nil) { place in
                    setLocation(place.coordinate)
                    if name.trimmingCharacters(in: .whitespaces).isEmpty {
                        name = place.name
                    }
                }
            }

            // Pin wherever the user has moved the map
            Button {
                setLocation(region.center)
            } label: {
                HStack {
                    Image(systemName: "scope")
                    Text("Pin Map Center")
                }
            }

            // Use Current Location button
            Button {
                geofenceManager.requestCurrentLocation()
            } label: {
                HStack {
                    Image(systemName: "location.fill")
                    Text("Use My Current Location")
                }
            }

            if hasSetLocation {
                HStack {
                    Text("Coordinates")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.4f, %.4f", latitude, longitude))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }

                // Check the pin in the Maps app; Maps cannot send a place back to Loop.
                Button {
                    let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                    let item = MKMapItem(placemark: placemark)
                    item.name = name.isEmpty ? nil : name
                    item.openInMaps(launchOptions: nil)
                } label: {
                    HStack {
                        Image(systemName: "map")
                        Text("Show in Maps")
                    }
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text("Search for an address or place, move the map and tap \"Pin Map Center\", or tap \"Use My Current Location\" while you are there.")
        }
    }

    private var radiusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Trigger Radius")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(radius))m")
                        .foregroundColor(.secondary)
                }
                Slider(value: $radius, in: 50...500, step: 25)
                Text("How close you need to be for the geofence to trigger. Smaller = more precise but may not trigger if you're on the edge.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var triggerSection: some View {
        Section("When to Trigger") {
            Picker("Trigger", selection: $triggerType) {
                ForEach(AutoPresetsGeofenceTrigger.allCases) { trigger in
                    Label(trigger.displayName, systemImage: trigger.iconName)
                        .tag(trigger)
                }
            }
            .pickerStyle(.segmented)

            if triggerType == .onEntry {
                Toggle("Deactivate preset when I leave", isOn: $deactivateOnExit)
            }
        }
    }

    private var presetSection: some View {
        Section("Preset to Activate") {
            if availablePresets.isEmpty {
                Text("No presets available. Create presets in Loop settings first.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(availablePresets, id: \.id) { preset in
                    Button {
                        selectedPresetId = preset.id.uuidString
                    } label: {
                        HStack {
                            Text("\(preset.symbol) \(preset.name)")
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedPresetId == preset.id.uuidString {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color(red: 76/255, green: 175/255, blue: 80/255))
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var enableSection: some View {
        Section {
            Toggle("Location Enabled", isOn: $isEnabled)
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete Location")
                    Spacer()
                }
            }
            .alert("Delete Location?", isPresented: $showingDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let existing = existingLocation {
                        geofenceManager.removeLocation(existing)
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will stop monitoring \"\(name)\" and remove it from your saved locations.")
            }
        }
    }

    private func setLocation(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 500, longitudinalMeters: 500)
        hasSetLocation = true
    }

    // MARK: - Save

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        hasSetLocation &&
        !selectedPresetId.isEmpty
    }

    private func saveLocation() {
        let location = AutoPresetsGeofenceLocation(
            id: existingLocation?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            triggerType: triggerType,
            presetId: selectedPresetId,
            deactivateOnExit: deactivateOnExit,
            isEnabled: isEnabled
        )

        if isEditing {
            geofenceManager.updateLocation(location)
        } else {
            geofenceManager.addLocation(location)
        }
        dismiss()
    }
}

// MARK: - Place Search

/// A place chosen in the search sheet.
struct AutoPresets_SearchedPlace {
    let name: String
    let coordinate: CLLocationCoordinate2D
}

/// Suggests addresses and places as the user types, using Apple's map search.
final class AutoPresets_PlaceCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet {
            if query.isEmpty {
                results = []
            } else {
                completer.queryFragment = query
            }
        }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var errorText: String?

    private let completer = MKLocalSearchCompleter()

    init(region: MKCoordinateRegion?) {
        super.init()
        completer.delegate = self
        // Ranks matches near the map first without excluding places elsewhere.
        if let region = region {
            completer.region = region
        }
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        errorText = nil
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        errorText = error.localizedDescription
    }
}

struct AutoPresets_PlaceSearchView: View {
    let onSelect: (AutoPresets_SearchedPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer: AutoPresets_PlaceCompleter
    @State private var resolving = false
    @State private var resolveError: String?

    init(searchRegion: MKCoordinateRegion?, onSelect: @escaping (AutoPresets_SearchedPlace) -> Void) {
        self.onSelect = onSelect
        _completer = StateObject(wrappedValue: AutoPresets_PlaceCompleter(region: searchRegion))
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        TextField("Address, business or landmark", text: $completer.query)
                            .textContentType(.fullStreetAddress)
                            .disableAutocorrection(true)
                        AutoPresets_ClearTextButton(text: $completer.query)
                    }
                }
                if let error = resolveError ?? completer.errorText {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }
                Section {
                    ForEach(completer.results, id: \.self) { result in
                        Button {
                            resolve(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).foregroundColor(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .disabled(resolving)
                    }
                }
            }
            .navigationTitle("Search Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    if resolving { SwiftUI.ProgressView() }
                }
            }
        }
    }

    /// A suggestion has no coordinates; a full search for it returns them.
    private func resolve(_ completion: MKLocalSearchCompletion) {
        resolving = true
        resolveError = nil
        MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start { response, error in
            resolving = false
            guard let item = response?.mapItems.first else {
                resolveError = error?.localizedDescription ?? "No location found for that result."
                return
            }
            onSelect(AutoPresets_SearchedPlace(name: item.name ?? completion.title, coordinate: item.placemark.coordinate))
            dismiss()
        }
    }
}

// MARK: - Clear Button

/// Grey "x" that empties a text field; hidden while the field is already empty.
struct AutoPresets_ClearTextButton: View {
    @Binding var text: String

    var body: some View {
        if !text.isEmpty {
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            // Plain style keeps the tap on the icon; a Form row otherwise sends it to the whole row.
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Clear"))
        }
    }
}

// MARK: - Map Pin Helper

private struct MapPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Preview

#if DEBUG
struct AutoPresets_GeofenceSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AutoPresets_GeofenceSettingsView()
        }
    }
}
#endif
