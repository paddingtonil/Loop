//
//  FoodFinder_AICameraView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Camera view for AI-powered food image analysis.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import SwiftUI
import UIKit
import Photos

/// Camera view for AI-powered food analysis
struct AICameraView: View {
    let onFoodAnalyzed: (AIFoodAnalysisResult, UIImage?) -> Void
    let onCancel: () -> Void

    @State private var capturedImage: UIImage?
    @State private var imageForAnalysis: UIImage?
    @State private var showingImagePicker = false
    @State private var showingCropView = false
    @State private var isAnalyzing = false
    @State private var analysisError: String?
    @State private var showingErrorAlert = false
    @State private var imageSourceType: UIImagePickerController.SourceType = .camera
    @State private var telemetryLogs: [String] = []
    @State private var showTelemetry = false
    @State private var showingTips = false
    /// Incremented when the user taps the "Reset Crop" toolbar button.
    /// `FoodFinder_ImageCropView` observes the change and resets its crop rect.
    @State private var cropResetCounter: Int = 0
    /// When true (set at crop completion if eligible), show the restaurant +
    /// item entry sheet instead of auto-running AI analysis. A menu match skips
    /// the AI call entirely; choosing "analyze with AI" clears this and proceeds.
    @State private var showingRestaurantMenu = false
    /// Non-nil while the user is browsing a restaurant's full menu list (reached
    /// from the entry sheet). Holds the restaurant name to load.
    @State private var browseFullMenuFor: String?

    /// Nearby restaurants for the entry-sheet picker; falls back to the single
    /// tagged venue, then empty.
    private var nearbyRestaurantNames: [String] {
        let venues = FoodFinder_LocationService.shared.nearbyVenues
        if !venues.isEmpty { return venues }
        if let name = FoodFinder_LocationService.shared.locationName { return [name] }
        return []
    }

    /// Eligible for the menu-first path: location tagging on, GPS confirms a
    /// restaurant within 200 ft, and a Spoonacular key is configured.
    private var canTryRestaurantMenu: Bool {
        FoodFinder_FeatureFlags.locationTaggingEnabled &&
        FoodFinder_LocationService.shared.isAtKnownRestaurant &&
        FoodFinder_SpoonacularService.shared.isConfigured
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Auto-launch camera interface
                if capturedImage == nil {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 24) {
                                // Camera icon
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 64))
                                    .foregroundColor(.accentColor)
                                    .padding(.top, 24)

                                // Heading
                                Text("Better photos = better estimates")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)

                                // Tips
                                VStack(alignment: .leading, spacing: 20) {
                                    CameraTipRow(icon: "sun.max.fill", title: "Use bright, even light", detail: "Harsh shadows confuse the AI and dim light can hide textures.")
                                    CameraTipRow(icon: "arrow.2.circlepath", title: "Clear the area", detail: "Remove napkins, lids, or packaging that may be misidentified as food.")
                                    CameraTipRow(icon: "square.dashed", title: "Frame the full meal", detail: "Make sure every food item is in the frame.")
                                    CameraTipRow(icon: "ruler", title: "Add a size reference", detail: "Forks, cups, or hands help AI calculate realistic portions.")
                                    CameraTipRow(icon: "camera.metering.spot", title: "Shoot from slightly above", detail: "Keep the camera level to reduce distortion and keep portions proportional.")
                                }
                                .padding(.horizontal)
                            }
                        }

                        Spacer()

                        // Take a Photo — the library-thumbnail button lives
                        // inside the camera overlay (mirrors iOS Camera app),
                        // so no separate "Choose from Library" button here.
                        Button(action: {
                            imageSourceType = .camera
                            showingImagePicker = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Take a Photo")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(red: 0.85, green: 0.25, blue: 0.85))
                            .foregroundColor(.white)
                            .cornerRadius(14)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 30)
                    }

                } else if imageForAnalysis != nil && showingRestaurantMenu {
                    // Menu-first path — confirmed within 200 ft of a restaurant
                    // with a Spoonacular key.
                    if let venue = browseFullMenuFor {
                        // Full-menu browser, reached from the entry sheet.
                        FoodFinder_RestaurantMenuView(
                            restaurantName: venue,
                            onPicked: { result in
                                showingRestaurantMenu = false
                                browseFullMenuFor = nil
                                onFoodAnalyzed(result, capturedImage)
                            },
                            onUseAI: {
                                // Drops to the analyzing view, whose onAppear runs analyzeImage().
                                showingRestaurantMenu = false
                                browseFullMenuFor = nil
                            }
                        )
                    } else {
                        // Ask which restaurant + what they ordered, then look up
                        // menu nutrition (no AI tokens). No match → AI fallback.
                        FoodFinder_RestaurantItemEntryView(
                            nearbyRestaurants: nearbyRestaurantNames,
                            onPicked: { result in
                                showingRestaurantMenu = false
                                onFoodAnalyzed(result, capturedImage)
                            },
                            onUseAI: {
                                // Drops to the analyzing view, whose onAppear runs analyzeImage().
                                showingRestaurantMenu = false
                            },
                            onBrowseFullMenu: { venue in
                                browseFullMenuFor = venue
                            }
                        )
                    }
                } else if let finalImage = imageForAnalysis {
                    // Show final image (cropped or full) and auto-start analysis
                    VStack(spacing: 20) {
                        Image(uiImage: finalImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 300)
                            .cornerRadius(12)
                            .padding(.horizontal)

                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)

                            Text("Analyzing food with AI...")
                                .font(.body)
                                .foregroundColor(.secondary)

                            Text("Use Cancel to retake photo")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if showTelemetry && !telemetryLogs.isEmpty {
                                TelemetryWindow(logs: telemetryLogs)
                                    .transition(.opacity.combined(with: .scale))
                            }
                        }
                        .padding()

                        Spacer()
                    }
                    .padding(.top)
                    .onAppear {
                        if !isAnalyzing && analysisError == nil {
                            analyzeImage()
                        }
                    }
                } else {
                    // Crop step — shown after image capture, before analysis.
                    // `resetTrigger` lets the outer toolbar's "Reset Crop"
                    // button drive a reset so we don't need a nested
                    // NavigationView inside the crop view.
                    FoodFinder_ImageCropView(
                        image: capturedImage!,
                        onCrop: { croppedImage in
                            imageForAnalysis = croppedImage
                            showingRestaurantMenu = canTryRestaurantMenu
                        },
                        onSkip: { originalImage in
                            imageForAnalysis = originalImage
                            showingRestaurantMenu = canTryRestaurantMenu
                        },
                        resetTrigger: cropResetCounter
                    )
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                // Conditional ToolbarItems via `if` inside `.toolbar` need
                // iOS 16 (ToolbarContentBuilder.buildIf). Loop targets iOS
                // 15, so keep one ToolbarItem and conditionally render the
                // Button vs an EmptyView inside its body (regular
                // ViewBuilder — supported on iOS 15).
                ToolbarItem(placement: .navigationBarTrailing) {
                    if capturedImage != nil && imageForAnalysis == nil {
                        Button("Reset Crop") {
                            cropResetCounter += 1
                        }
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(
                image: $capturedImage,
                sourceType: $imageSourceType,
                onLibraryRequested: {
                    // Tapping the camera overlay's thumbnail flips the source
                    // type, triggering ImagePicker.updateUIViewController to
                    // switch the active picker into library mode in place.
                    imageSourceType = .photoLibrary
                }
            )
        }
        .powerPackAPIUsageGate()
        .alert("Analysis Error", isPresented: $showingErrorAlert) {
            // Credit/quota exhaustion errors - provide direct guidance
            if analysisError?.contains("credits exhausted") == true || analysisError?.contains("quota exceeded") == true {
                Button("Check Account") {
                    // This could open settings or provider website in future enhancement
                    analysisError = nil
                }
                Button("Retry Analysis") {
                    analysisError = nil
                    analyzeImage()
                }
                Button("Retake Photo") {
                    capturedImage = nil
                    imageForAnalysis = nil
                    analysisError = nil
                }
                Button("Cancel", role: .cancel) {
                    analysisError = nil
                }
            }
            // Rate limit errors - suggest waiting
            else if analysisError?.contains("rate limit") == true {
                Button("Wait and Retry") {
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        analyzeImage()
                    }
                }
                Button("Retry Analysis") {
                    analysisError = nil
                    analyzeImage()
                }
                Button("Retake Photo") {
                    capturedImage = nil
                    imageForAnalysis = nil
                    analysisError = nil
                }
                Button("Cancel", role: .cancel) {
                    analysisError = nil
                }
            }
            // General errors - provide standard options
            else {
                Button("Retry Analysis") {
                    analyzeImage()
                }
                Button("Retake Photo") {
                    capturedImage = nil
                    imageForAnalysis = nil
                    analysisError = nil
                }
                if analysisError?.contains("404") == true || analysisError?.contains("service error") == true {
                    Button("Check Settings") {
                        analysisError = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    analysisError = nil
                }
            }
        } message: {
            if analysisError?.contains("credits exhausted") == true {
                Text("Your AI provider has run out of credits. Please check your account billing or try a different provider.")
            } else if analysisError?.contains("quota exceeded") == true {
                Text("Your AI provider quota has been exceeded. Please check your usage limits or try a different provider.")
            } else if analysisError?.contains("rate limit") == true {
                Text("Too many requests sent to your AI provider. Please wait a moment before trying again.")
            } else {
                Text(analysisError ?? "Unknown error occurred")
            }
        }
    }

    private func analyzeImage() {
        guard let image = imageForAnalysis else { return }

        // Check if AI service is configured
        let aiService = ConfigurableAIService.shared
        guard aiService.isConfigured else {
            analysisError = "AI service not configured. Please check settings."
            showingErrorAlert = true
            return
        }

        isAnalyzing = true
        analysisError = nil
        telemetryLogs = []
        showTelemetry = true

        // Start telemetry logging with progressive steps
        addTelemetryLog("🔍 Initializing AI food analysis...")

        Task {
            // User-initiated paid AI action — pass through the spend gate.
            guard await PowerPack_APIUsage.shared.gate(actionLabel: "Analyzing this photo", estCostUSD: 0.02) else {
                await MainActor.run {
                    isAnalyzing = false
                    showTelemetry = false
                }
                return
            }
            do {
                // Brief fallback wait if location is still resolving
                // (location request fires on camera button tap, so it usually
                // resolves during photo framing — this is just a safety net)
                let locService = FoodFinder_LocationService.shared
                if locService.isResolving {
                    await MainActor.run {
                        addTelemetryLog("📍 Resolving location...")
                    }
                    for _ in 0..<15 {
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        if !locService.isResolving { break }
                    }
                }
                if let locLabel = locService.locationName ?? locService.cityName {
                    await MainActor.run {
                        addTelemetryLog("📍 \(locLabel)")
                    }
                }

                // Image preparation + send
                await MainActor.run {
                    addTelemetryLog("📡 Sending to AI provider...")
                }

                // Actual AI call — no artificial delays
                let result = try await aiService.analyzeFoodImage(image) { telemetryMessage in
                    Task { @MainActor in
                        addTelemetryLog(telemetryMessage)
                    }
                }

                await MainActor.run {
                    addTelemetryLog("✅ Analysis complete!")
                    showTelemetry = false
                    isAnalyzing = false
                    onFoodAnalyzed(result, capturedImage)
                }
            } catch {
                await MainActor.run {
                    addTelemetryLog("❌ Analysis failed")
                    showTelemetry = false
                    isAnalyzing = false
                    analysisError = error.localizedDescription
                    showingErrorAlert = true
                }
            }
        }
    }

    private func addTelemetryLog(_ message: String) {
        telemetryLogs.append(message)

        // Keep only the last 10 messages to prevent overflow
        if telemetryLogs.count > 10 {
            telemetryLogs.removeFirst()
        }
    }
}

private struct CameraTipRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .fontWeight(.bold)
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Image Picker

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Binding var sourceType: UIImagePickerController.SourceType
    /// Optional callback fired when the user taps the library-thumbnail
    /// button in the camera overlay. The host flips `sourceType` to
    /// `.photoLibrary`, which triggers `updateUIViewController` to switch
    /// the picker's mode in place.
    var onLibraryRequested: (() -> Void)? = nil
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        applyBaseAppearance(to: picker)
        configurePicker(picker, for: sourceType)
        return picker
    }

    private func applyBaseAppearance(to picker: UIImagePickerController) {
        if let navigationBar = picker.navigationBar as UINavigationBar? {
            navigationBar.tintColor = UIColor.systemBlue
            navigationBar.titleTextAttributes = [
                .foregroundColor: UIColor.systemBlue,
                .font: UIFont.boldSystemFont(ofSize: 17)
            ]
        }

        picker.navigationBar.tintColor = UIColor.systemBlue
        picker.view.tintColor = UIColor.systemBlue
        picker.toolbar?.tintColor = UIColor.systemBlue
        picker.toolbar?.barTintColor = UIColor.systemBlue.withAlphaComponent(0.1)

        UIBarButtonItem.appearance(whenContainedInInstancesOf: [UIImagePickerController.self]).tintColor = UIColor.systemBlue
        UIButton.appearance(whenContainedInInstancesOf: [UIImagePickerController.self]).tintColor = UIColor.systemBlue
        UILabel.appearance(whenContainedInInstancesOf: [UIImagePickerController.self]).tintColor = UIColor.systemBlue
        UIToolbar.appearance(whenContainedInInstancesOf: [UIImagePickerController.self]).tintColor = UIColor.systemBlue
        UIToolbar.appearance(whenContainedInInstancesOf: [UIImagePickerController.self]).barTintColor = UIColor.systemBlue.withAlphaComponent(0.1)

        setupCameraButtonStyling(picker)
    }

    private func configurePicker(_ picker: UIImagePickerController, for desiredType: UIImagePickerController.SourceType) {
        guard UIImagePickerController.isSourceTypeAvailable(desiredType) else {
            return
        }

        let wasCamera = picker.sourceType == .camera

        // When leaving camera mode, clear overlays and restore native chrome
        // before we switch types (camera-only APIs).
        if wasCamera && desiredType != .camera {
            picker.cameraOverlayView = nil
            picker.showsCameraControls = true
        }

        if picker.sourceType != desiredType {
            picker.sourceType = desiredType
        }

        picker.allowsEditing = false

        if desiredType == .camera {
            // Replace iOS's standard camera chrome (which forces a Retake /
            // Use Photo review screen after capture) with our own overlay so
            // the captured image goes straight to FoodFinder_ImageCropView.
            // With `showsCameraControls = false`, `picker.takePicture()`
            // fires `didFinishPickingMediaWithInfo` directly — no review.
            picker.showsCameraControls = false
            if !(picker.cameraOverlayView is FoodFinder_CameraOverlay) {
                let callback = onLibraryRequested
                picker.cameraOverlayView = FoodFinder_CameraOverlay(
                    picker: picker,
                    onLibraryRequested: callback
                )
            }
            // Scale + translate the live camera preview so it fills the
            // entire screen (matches iOS native Camera). Without this the
            // preview is a 4:3 letterbox and the bottom of the screen is the
            // picker's solid black background — a translucent overlay bar
            // over that region just looks fully black, and the seam where
            // the preview ends shows as a thin grey line.
            //
            // Scaling alone anchors at the view's center, so the scaled
            // preview's bottom only reaches y ≈ screen.height -
            // (screen.height - previewHeight)/2 — short of the screen edge.
            // Add a downward translation of half that gap to push the bottom
            // edge flush with the screen bottom. Captured image is
            // unaffected (still the full 4:3 sensor frame).
            let screen = UIScreen.main.bounds.size
            let unscaledPreviewHeight = screen.width * 4.0 / 3.0
            let scale = screen.height / unscaledPreviewHeight
            let translateY = (screen.height - unscaledPreviewHeight) / 2
            picker.cameraViewTransform = CGAffineTransform(translationX: 0, y: translateY)
                .scaledBy(x: scale, y: scale)
        }
        // Note: do NOT touch `showsCameraControls` or `cameraOverlayView`
        // when sourceType != .camera — those properties are camera-only and
        // setting them on a `.photoLibrary` picker can freeze the system
        // picker. The non-camera path uses the OS-native chrome unchanged.
    }

    private func setupCameraButtonStyling(_ picker: UIImagePickerController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.applyBasicBlueStyling(to: picker.view)
        }
    }

    private func applyBasicBlueStyling(to view: UIView) {
        for subview in view.subviews {
            if let toolbar = subview as? UIToolbar {
                toolbar.tintColor = UIColor.systemBlue
                toolbar.barTintColor = UIColor.systemBlue.withAlphaComponent(0.1)
                toolbar.items?.forEach { item in
                    item.tintColor = UIColor.systemBlue
                }
            }

            if let navBar = subview as? UINavigationBar {
                navBar.tintColor = UIColor.systemBlue
                navBar.titleTextAttributes = [.foregroundColor: UIColor.systemBlue]
            }

            applyBasicBlueStyling(to: subview)
        }
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        configurePicker(uiViewController, for: sourceType)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.applyBasicBlueStyling(to: uiViewController.view)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let uiImage = info[.editedImage] as? UIImage {
                parent.image = uiImage
            } else if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }
            parent.presentationMode.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Telemetry Window

struct TelemetryWindow: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.green)
                    .font(.caption2)
                Text("Analysis Status")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))

            // Scrolling logs
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { index, log in
                            HStack {
                                Text(log)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .id(index)
                        }

                        // Add bottom padding to prevent cutoff
                        Color.clear
                            .frame(height: 56)
                    }
                    .onAppear {
                        // Auto-scroll to latest log
                        if !logs.isEmpty {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(logs.count - 1, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: logs.count) { _ in
                        // Auto-scroll to latest log when new ones are added
                        if !logs.isEmpty {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(logs.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 14)
            .frame(height: 320)
            .background(Color(.systemBackground))
        }
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
        .padding(.top, 8)
    }
}

// MARK: - Preview

#if DEBUG
struct AICameraView_Previews: PreviewProvider {
    static var previews: some View {
        AICameraView(
            onFoodAnalyzed: { result, image in
                print("Food analyzed: \(result)")
            },
            onCancel: {
                print("Cancelled")
            }
        )
    }
}

struct TelemetryWindow_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            TelemetryWindow(logs: [
                "🔍 Initializing AI food analysis...",
                "📱 Processing image data...",
                "🧠 Connecting to AI provider...",
                "📊 Analyzing nutritional content...",
                "✅ Analysis complete!"
            ])
            Spacer()
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}
#endif

// MARK: - Custom Camera Overlay

/// Custom chrome that replaces UIImagePickerController's built-in camera
/// controls. We use this so the captured photo bypasses iOS's mandatory
/// "Retake / Use Photo" review screen and goes straight to the crop step.
/// `UIImagePickerController.showsCameraControls = false` suppresses the
/// review; calling `picker.takePicture()` from our shutter button fires
/// `didFinishPickingMediaWithInfo` directly.
final class FoodFinder_CameraOverlay: UIView {
    private weak var picker: UIImagePickerController?
    /// Fires when the user taps the bottom-left library thumbnail. The host
    /// SwiftUI view flips `imageSourceType` to `.photoLibrary`, which causes
    /// `updateUIViewController` to re-configure the picker in library mode.
    private let onLibraryRequested: (() -> Void)?

    // Stored references so `layoutSubviews` can position each view against
    // the overlay's current real bounds (not whatever bounds we guessed at
    // init). The cameraOverlayView ends up sized to the picker's visible
    // content area, which on a SwiftUI sheet is shorter than the full screen
    // — positioning against UIScreen.main.bounds at init drove the bottom
    // controls below the visible region.
    private let bottomBar = UIView()
    private let shutterButton = UIButton(type: .custom)
    private let shutterInnerDisc = UIView()
    private let cancelButton = UIButton(type: .system)
    private let flipButton = UIButton(type: .custom)
    private let libraryThumbnailButton = UIButton(type: .custom)

    // Layout constants
    private let shutterSize: CGFloat = 72
    private let innerDiscSize: CGFloat = 56
    private let shutterBottomInset: CGFloat = 175
    private let topInset: CGFloat = 56
    private let bottomControlsBottomPadding: CGFloat = 130
    private let thumbSize: CGFloat = 48
    private let flipSize: CGFloat = 44

    init(picker: UIImagePickerController, onLibraryRequested: (() -> Void)? = nil) {
        self.picker = picker
        self.onLibraryRequested = onLibraryRequested
        super.init(frame: UIScreen.main.bounds)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        buildSubviews()
        loadLatestLibraryThumbnail()
    }

    required init?(coder: NSCoder) {
        fatalError("FoodFinder_CameraOverlay does not support NSCoder")
    }

    // Build (style + add) the subviews once. Positioning happens in
    // `layoutSubviews` so it tracks the overlay's actual bounds.
    private func buildSubviews() {
        // Semi-transparent black bar behind the bottom controls — preview
        // shows through faintly (iOS native Camera look). Added first so
        // the buttons render on top.
        bottomBar.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        bottomBar.isUserInteractionEnabled = false
        addSubview(bottomBar)

        // Shutter — white ring + inner disc.
        shutterButton.backgroundColor = .clear
        shutterButton.layer.borderWidth = 4
        shutterButton.layer.borderColor = UIColor.white.cgColor
        shutterButton.layer.cornerRadius = shutterSize / 2
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        shutterInnerDisc.backgroundColor = .white
        shutterInnerDisc.layer.cornerRadius = innerDiscSize / 2
        shutterInnerDisc.isUserInteractionEnabled = false
        shutterButton.addSubview(shutterInnerDisc)
        addSubview(shutterButton)

        // Cancel — top-left below status bar.
        cancelButton.contentHorizontalAlignment = .left
        cancelButton.setTitle(NSLocalizedString("Cancel", comment: "Camera cancel button"), for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(cancelButton)

        // Flip — bottom-right, circular chip with circular-arrows icon.
        flipButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        flipButton.layer.cornerRadius = flipSize / 2
        let flipSymbolConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let flipIcon = UIImage(systemName: "arrow.triangle.2.circlepath", withConfiguration: flipSymbolConfig)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        flipButton.setImage(flipIcon, for: .normal)
        flipButton.addTarget(self, action: #selector(flipTapped), for: .touchUpInside)
        addSubview(flipButton)

        // Library thumbnail — bottom-left, mirrors iOS native Camera app.
        // `.custom` (not `.system`) because `.system` would tint a real
        // photo with `tintColor` and turn it into a solid white dot.
        libraryThumbnailButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        let fallbackIcon = UIImage(systemName: "photo.on.rectangle", withConfiguration: symbolConfig)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        libraryThumbnailButton.setImage(fallbackIcon, for: .normal)
        libraryThumbnailButton.imageView?.contentMode = .scaleAspectFit
        libraryThumbnailButton.layer.cornerRadius = thumbSize / 2
        libraryThumbnailButton.clipsToBounds = true
        libraryThumbnailButton.addTarget(self, action: #selector(libraryTapped), for: .touchUpInside)
        addSubview(libraryThumbnailButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return }

        // Bar height: from a little above the shutter to the bottom of the
        // overlay. Anchoring to bounds.height means it always reaches the
        // actual visible bottom, even when the picker shrinks the overlay.
        let barHeight = shutterBottomInset + shutterSize / 2 + 60
        bottomBar.frame = CGRect(
            x: 0,
            y: bounds.height - barHeight,
            width: bounds.width,
            height: barHeight
        )

        // Shutter — center horizontally, anchored to bounds.bottom.
        let shutterX = (bounds.width - shutterSize) / 2
        let shutterY = bounds.height - shutterSize - shutterBottomInset
        shutterButton.frame = CGRect(x: shutterX, y: shutterY, width: shutterSize, height: shutterSize)
        let discOffset = (shutterSize - innerDiscSize) / 2
        shutterInnerDisc.frame = CGRect(x: discOffset, y: discOffset, width: innerDiscSize, height: innerDiscSize)

        // Cancel — top-left below status bar.
        cancelButton.frame = CGRect(x: 16, y: topInset, width: 80, height: 36)

        // Flip + thumbnail — pinned to bounds.bottom so they always land
        // inside the visible region.
        let bottomControlY = bounds.height - bottomControlsBottomPadding
        flipButton.frame = CGRect(
            x: bounds.width - flipSize - 28,
            y: bottomControlY - flipSize,
            width: flipSize,
            height: flipSize
        )
        libraryThumbnailButton.frame = CGRect(
            x: 28,
            y: bottomControlY - thumbSize,
            width: thumbSize,
            height: thumbSize
        )
    }

    // MARK: - Library Thumbnail Fetch

    /// Fetch the most recently created photo from the user's library and set
    /// it as the thumbnail-button image. Requests Photos authorization on
    /// first use; falls back to the generic SF Symbol if denied or empty.
    private func loadLatestLibraryThumbnail() {
        let apply: (UIImage?) -> Void = { [weak self] image in
            guard let self = self, let image = image else { return }
            DispatchQueue.main.async {
                // `setBackgroundImage` fills the entire button frame, where
                // `setImage` would just place the photo at its intrinsic
                // size in the content area (most of the photo cropped off
                // and reduced to a tiny tile). Clear the foreground SF
                // Symbol so it doesn't overlay the photo. Use alwaysOriginal
                // so the photo isn't recolored by tintColor.
                self.libraryThumbnailButton.setImage(nil, for: .normal)
                self.libraryThumbnailButton.setBackgroundImage(
                    image.withRenderingMode(.alwaysOriginal),
                    for: .normal
                )
            }
        }

        let status: PHAuthorizationStatus
        if #available(iOS 14, *) {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus()
        }

        switch status {
        case .authorized, .limited:
            fetchLatestAsset(apply: apply)
        case .notDetermined:
            if #available(iOS 14, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                    guard let self = self, newStatus == .authorized || newStatus == .limited else { return }
                    self.fetchLatestAsset(apply: apply)
                }
            } else {
                PHPhotoLibrary.requestAuthorization { [weak self] newStatus in
                    guard let self = self, newStatus == .authorized else { return }
                    self.fetchLatestAsset(apply: apply)
                }
            }
        default:
            // Denied / restricted — keep the generic icon. The tap still
            // works because UIImagePickerController(.photoLibrary) doesn't
            // require Photos authorization.
            break
        }
    }

    private func fetchLatestAsset(apply: @escaping (UIImage?) -> Void) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        let result = PHAsset.fetchAssets(with: .image, options: options)
        guard let asset = result.firstObject else { return }

        let scale = UIScreen.main.scale
        let target = CGSize(width: 48 * scale, height: 48 * scale)
        let requestOpts = PHImageRequestOptions()
        requestOpts.deliveryMode = .opportunistic
        requestOpts.isNetworkAccessAllowed = false
        requestOpts.resizeMode = .fast
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFill,
            options: requestOpts
        ) { image, _ in
            apply(image)
        }
    }

    @objc private func shutterTapped() {
        // Light haptic to mirror the iOS native camera feel.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        picker?.takePicture()
    }

    @objc private func cancelTapped() {
        guard let picker = picker else { return }
        // Notify delegate first so the SwiftUI host can clean up `@State`
        // values (e.g. `showingImagePicker = false`), then dismiss the
        // picker directly so we don't rely on the host's @Environment
        // presentation mode being captured correctly inside a sheet.
        picker.delegate?.imagePickerControllerDidCancel?(picker)
        picker.dismiss(animated: true)
    }

    @objc private func flipTapped() {
        guard let picker = picker else { return }
        picker.cameraDevice = (picker.cameraDevice == .rear) ? .front : .rear
    }

    @objc private func libraryTapped() {
        onLibraryRequested?()
    }
}
