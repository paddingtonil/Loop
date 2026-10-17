//
//  BarcodeScannerTests.swift
//  LoopTests
//
//  Created by Claude Code for Barcode Scanner Testing
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
import Vision
import Combine
@testable import Loop

class BarcodeScannerServiceTests: XCTestCase {

    var barcodeScannerService: BarcodeScannerService!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        barcodeScannerService = BarcodeScannerService.mock()
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables.removeAll()
        barcodeScannerService = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testServiceInitialization() {
        XCTAssertNotNil(barcodeScannerService)
        XCTAssertFalse(barcodeScannerService.isScanning)
        XCTAssertNil(barcodeScannerService.lastScanResult)
        XCTAssertNil(barcodeScannerService.scanError)
    }

    func testSharedInstanceExists() {
        let sharedInstance = BarcodeScannerService.shared
        XCTAssertNotNil(sharedInstance)
    }

    // MARK: - Mock Testing

    func testSimulateSuccessfulScan() {
        let expectation = XCTestExpectation(description: "Barcode scan result received")
        let testBarcode = "1234567890123"

        barcodeScannerService.$lastScanResult
            .compactMap { $0 }
            .sink { result in
                XCTAssertEqual(result.barcodeString, testBarcode)
                XCTAssertGreaterThan(result.confidence, 0.0)
                XCTAssertEqual(result.barcodeType, .ean13)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        barcodeScannerService.simulateScan(barcode: testBarcode)

        wait(for: [expectation], timeout: 2.0)
    }

    func testSimulateScanError() {
        let expectation = XCTestExpectation(description: "Scan error received")
        let testError = BarcodeScanError.invalidBarcode

        barcodeScannerService.$scanError
            .compactMap { $0 }
            .sink { error in
                XCTAssertEqual(error.localizedDescription, testError.localizedDescription)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        barcodeScannerService.simulateError(testError)

        wait(for: [expectation], timeout: 2.0)
    }

    func testScanningStateUpdates() {
        let expectation = XCTestExpectation(description: "Scanning state updated")

        barcodeScannerService.$isScanning
            .dropFirst() // Skip initial value
            .sink { isScanning in
                XCTAssertFalse(isScanning) // Should be false after simulation
                expectation.fulfill()
            }
            .store(in: &cancellables)

        barcodeScannerService.simulateScan(barcode: "test")

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Error Testing

    func testBarcodeScanErrorTypes() {
        let errors: [BarcodeScanError] = [
            .cameraNotAvailable,
            .cameraPermissionDenied,
            .scanningFailed("Test failure"),
            .invalidBarcode,
            .sessionSetupFailed
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    func testErrorDescriptionsAreLocalized() {
        let error = BarcodeScanError.cameraPermissionDenied
        let description = error.errorDescription

        XCTAssertNotNil(description)
        XCTAssertFalse(description!.isEmpty)

        let suggestion = error.recoverySuggestion
        XCTAssertNotNil(suggestion)
        XCTAssertFalse(suggestion!.isEmpty)
    }
}

// MARK: - BarcodeScanResult Tests

class BarcodeScanResultTests: XCTestCase {

    func testBarcodeScanResultInitialization() {
        let barcode = "1234567890123"
        let barcodeType = VNBarcodeSymbology.ean13
        let confidence: Float = 0.95
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)

        let result = BarcodeScanResult(
            barcodeString: barcode,
            barcodeType: barcodeType,
            confidence: confidence,
            bounds: bounds
        )

        XCTAssertEqual(result.barcodeString, barcode)
        XCTAssertEqual(result.barcodeType, barcodeType)
        XCTAssertEqual(result.confidence, confidence)
        XCTAssertEqual(result.bounds, bounds)
        XCTAssertNotNil(result.timestamp)
    }

    func testSampleBarcodeScanResult() {
        let sampleResult = BarcodeScanResult.sample()

        XCTAssertEqual(sampleResult.barcodeString, "1234567890123")
        XCTAssertEqual(sampleResult.barcodeType, .ean13)
        XCTAssertEqual(sampleResult.confidence, 0.95)
        XCTAssertNotNil(sampleResult.timestamp)
    }

    func testCustomSampleBarcodeScanResult() {
        let customBarcode = "9876543210987"
        let sampleResult = BarcodeScanResult.sample(barcode: customBarcode)

        XCTAssertEqual(sampleResult.barcodeString, customBarcode)
        XCTAssertEqual(sampleResult.barcodeType, .ean13)
        XCTAssertEqual(sampleResult.confidence, 0.95)
    }

    func testTimestampIsRecent() {
        let result = BarcodeScanResult.sample()
        let now = Date()
        let timeDifference = abs(now.timeIntervalSince(result.timestamp))

        // Timestamp should be very recent (within 1 second)
        XCTAssertLessThan(timeDifference, 1.0)
    }
}

// MARK: - Permission and Authorization Tests

class BarcodeScannerAuthorizationTests: XCTestCase {

    var barcodeScannerService: BarcodeScannerService!

    override func setUp() {
        super.setUp()
        barcodeScannerService = BarcodeScannerService.mock()
    }

    override func tearDown() {
        barcodeScannerService = nil
        super.tearDown()
    }

    func testMockServiceHasAuthorizedStatus() {
        // Mock service should have authorized camera access
        XCTAssertEqual(barcodeScannerService.cameraAuthorizationStatus, .authorized)
    }

    func testRequestCameraPermissionReturnsPublisher() {
        let publisher = barcodeScannerService.requestCameraPermission()
        XCTAssertNotNil(publisher)
    }

    func testGetPreviewLayerReturnsLayer() {
        let previewLayer = barcodeScannerService.getPreviewLayer()
        XCTAssertNotNil(previewLayer)
    }
}

// MARK: - Integration Tests

class BarcodeScannerIntegrationTests: XCTestCase {

    func testBarcodeScannerServiceIntegrationWithCarbEntry() {
        let service = BarcodeScannerService.mock()
        let testBarcode = "7622210992338" // Example EAN-13 barcode

        // Simulate a barcode scan
        service.simulateScan(barcode: testBarcode)

        // The simulate helpers publish on the main queue; let that run before checking.
        let published = expectation(description: "main queue")
        DispatchQueue.main.async { published.fulfill() }
        wait(for: [published], timeout: 1)

        // Verify the result is available
        XCTAssertNotNil(service.lastScanResult)
        XCTAssertEqual(service.lastScanResult?.barcodeString, testBarcode)
        XCTAssertFalse(service.isScanning)
    }

    func testErrorHandlingFlow() {
        let service = BarcodeScannerService.mock()
        let error = BarcodeScanError.cameraPermissionDenied

        service.simulateError(error)

        // The simulate helpers publish on the main queue; let that run before checking.
        let published = expectation(description: "main queue")
        DispatchQueue.main.async { published.fulfill() }
        wait(for: [published], timeout: 1)

        XCTAssertNotNil(service.scanError)
        XCTAssertEqual(service.scanError?.localizedDescription, error.localizedDescription)
        XCTAssertFalse(service.isScanning)
    }
}

// MARK: - QR code preference

final class FoodFinder_CodePreferenceTests: XCTestCase {
    private func code(_ value: String, _ type: VNBarcodeSymbology, _ confidence: Float = 0.9) -> BarcodeScanResult {
        BarcodeScanResult(barcodeString: value, barcodeType: type, confidence: confidence, bounds: .zero)
    }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testBarcodeWinsOverQRInTheSameFrame() {
        let picked = FoodFinder_CodePreference.choose(from: [code("https://x/0123", .qr, 0.99), code("012345678905", .ean13, 0.85)], mode: .preferBarcode)
        XCTAssertEqual(picked?.barcodeType, .ean13)
    }

    func testEqualModePicksHighestConfidence() {
        let picked = FoodFinder_CodePreference.choose(from: [code("q", .qr, 0.99), code("012345678905", .ean13, 0.85)], mode: .equal)
        XCTAssertEqual(picked?.barcodeType, .qr)
    }

    func testOffModeNeverPicksQROrDataMatrix() {
        XCTAssertNil(FoodFinder_CodePreference.choose(from: [code("q", .qr), code("d", .dataMatrix)], mode: .off))
        XCTAssertEqual(FoodFinder_CodePreference.choose(from: [code("q", .qr), code("012345678905", .upce)], mode: .off)?.barcodeType, .upce)
    }

    func testQRAloneWaitsThenIsAccepted() {
        var wait = FoodFinder_QRWait()
        let qr = code("0123456789012", .qr)
        XCTAssertFalse(wait.shouldAccept(qr, mode: .preferBarcode, now: start))
        XCTAssertFalse(wait.shouldAccept(qr, mode: .preferBarcode, now: start.addingTimeInterval(FoodFinder_QRWait.delay - 0.1)))
        XCTAssertTrue(wait.shouldAccept(qr, mode: .preferBarcode, now: start.addingTimeInterval(FoodFinder_QRWait.delay)))
    }

    func testDifferentQRRestartsTheWait() {
        var wait = FoodFinder_QRWait()
        XCTAssertFalse(wait.shouldAccept(code("a", .qr), mode: .preferBarcode, now: start))
        XCTAssertFalse(wait.shouldAccept(code("b", .qr), mode: .preferBarcode, now: start.addingTimeInterval(FoodFinder_QRWait.delay)))
    }

    func testBarcodeAndEqualModeAreAcceptedAtOnceAndClearTheWait() {
        var wait = FoodFinder_QRWait()
        XCTAssertFalse(wait.shouldAccept(code("a", .qr), mode: .preferBarcode, now: start))
        XCTAssertTrue(wait.shouldAccept(code("012345678905", .ean13), mode: .preferBarcode, now: start.addingTimeInterval(0.2)))
        XCTAssertFalse(wait.shouldAccept(code("a", .qr), mode: .preferBarcode, now: start.addingTimeInterval(FoodFinder_QRWait.delay)))
        var equalWait = FoodFinder_QRWait()
        XCTAssertTrue(equalWait.shouldAccept(code("a", .qr), mode: .equal, now: start))
    }

    func testModeDefaultsToPreferBarcode() {
        let defaults = UserDefaults(suiteName: "FoodFinder_CodePreferenceTests")!
        defaults.removePersistentDomain(forName: "FoodFinder_CodePreferenceTests")
        XCTAssertEqual(FoodFinder_QRCodeMode.load(from: defaults), .preferBarcode)
        defaults.set("off", forKey: FoodFinder_FeatureFlags.Keys.qrCodeMode)
        XCTAssertEqual(FoodFinder_QRCodeMode.load(from: defaults), .off)
    }
}
