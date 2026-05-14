//
//  HealthManager.swift
//  MyHealthApp
//
//  Created by raven on 11/22/25.
//

import Combine
import Foundation
import HealthKit

class HealthKitManager: ObservableObject {
    let healthStore = HKHealthStore()
    let dbHelper = DBHelper.shared
    
    @Published var walks: [WalkData] = []
    @Published var isFetching = false
    /// True when step-count **sharing** is authorized (same gate used for the full read/write bundle in `requestHealthAuthorization`).
    @Published var isStepsAuthorized = false
    /// True when HealthKit reports that requesting read access for walking/running distance would be unnecessary (typically already handled).
    @Published var isDistanceWalkingReadAuthUnnecessary = false
    @Published var showSettingsAlert = false
    @Published var showPermissionAuthorizedAlert = false
    @Published var showDummyDataImportedAlert = false
    @Published var dummyDataImportedMessage = ""
    
    private var anchor: HKQueryAnchor?
    private let anchorKey = "walking_anchor" // Key for UserDefaults
    
    init() {
        // 1. Load the saved bookmark from disk
        loadAnchor()
        // 2. Load the visual data from DB
        loadLocalData()
        refreshAuthorizationButtonsState()
    }
    
    /// Updates published flags used to enable/disable Authorize buttons (call on launch, on appear, and after authorization flows).
    func refreshAuthorizationButtonsState() {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async {
                self.isStepsAuthorized = false
                self.isDistanceWalkingReadAuthUnnecessary = false
            }
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            
            if let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
                let stepStatus = self.healthStore.authorizationStatus(for: stepsType)
                self.isStepsAuthorized = (stepStatus == .sharingAuthorized)
            }
            
            guard let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else {
                self.isDistanceWalkingReadAuthUnnecessary = false
                return
            }
            self.healthStore.getRequestStatusForAuthorization(toShare: [], read: [distanceType]) { [weak self] status, error in
                guard let self else { return }
                if let error = error {
                    print("DEBUG: Distance read auth status error: \(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    self.isDistanceWalkingReadAuthUnnecessary = (status == .unnecessary)
                }
            }
        }
    }
    
    // MARK: - Anchor Persistence (The Fix)
    
    func saveAnchor(_ newAnchor: HKQueryAnchor) {
        // We must convert the Anchor object to Data to save it
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: anchorKey)
            self.anchor = newAnchor
        }
    }
    
    func loadAnchor() {
        guard let data = UserDefaults.standard.data(forKey: anchorKey) else { return }
        
        // Convert Data back to Anchor object
        do {
            self.anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        } catch {
            print("Failed to load anchor")
        }
    }
    
    // MARK: - Standard Logic
    
    func loadLocalData() {
        let savedData = dbHelper.readAll()
        DispatchQueue.main.async {
            self.walks = savedData
        }
    }
    
    func distanceWalkingRunningAuthorization() {
        guard let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return }
        healthStore.requestAuthorization(toShare: nil, read: [type]) { [weak self] _, _ in
            self?.refreshAuthorizationButtonsState()
        }
    }
    
    func fetchWalkingRunningDistance() {
        guard !isFetching else { return }
        DispatchQueue.main.async { self.isFetching = true }
        
        guard let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return }
        
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: self.anchor, limit: HKObjectQueryNoLimit) { [weak self] (_, newSamples, deletedSamples, newAnchor, error) in
            
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.isFetching = false } }
            
            if let error = error { print("Error: \(error)"); return }
            
            // STEP 1: Process the Data (Grouping)
            var dailyTotals: [String: Double] = [:]
            
            if let samples = newSamples as? [HKQuantitySample], !samples.isEmpty {
                print("Found \(samples.count) new items. Processing...")
                
                for sample in samples {
                    let dateKey = DateUtils.shared.dateKey(from: sample.startDate)
                    let distance = sample.quantity.doubleValue(for: .meter())
                    dailyTotals[dateKey, default: 0.0] += distance
                }
                
                // STEP 2: Write to Database
                // We only write if we actually calculated totals
                for (dateStr, totalDistance) in dailyTotals {
                    self.dbHelper.addDistanceToDate(dateStr: dateStr, amountToAdd: totalDistance)
                }
            } else {
                print("No new data to process.")
            }
            
            // STEP 3: Save the Anchor (ONLY after DB is updated)
            // We do this last so if Step 2 crashes, we download the data again next time.
            if let newAnchor = newAnchor {
                self.saveAnchor(newAnchor)
                print("Anchor saved.")
            }
            
            self.loadLocalData()
        }
        
        healthStore.execute(query)
    }
    // MARK: - Authorization
    /// - Parameter showPermissionSuccessAlert: When false, skips the "access granted" alert (use for flows that already show their own completion UI, e.g. dummy import).
    func requestHealthAuthorization(showPermissionSuccessAlert: Bool = true, completion: @escaping (Bool) -> Void) {
        print("STEP 1: Function started")
        
        guard HKHealthStore.isHealthDataAvailable() else {
            print("ERROR: HealthKit not available")
            completion(false)
            return
        }
        print("STEP 2: HealthKit is available")
        
        // Check types individually to ensure none are failing
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { print("FAIL: Steps Type"); return }
        guard let weightType = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { print("FAIL: Weight Type"); return }
        guard let tempType = HKQuantityType.quantityType(forIdentifier: .bodyTemperature) else { print("FAIL: Temp Type"); return }
        guard let o2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { print("FAIL: O2 Type"); return }
        guard let bpSystolic = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic) else { print("FAIL: BP Sys Type"); return }
        guard let bpDiastolic = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic) else { print("FAIL: BP Dia Type"); return }
        guard let glucoseType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { print("FAIL: Glucose Type"); return }
        guard let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { print("FAIL: Distance Type"); return }
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { print("FAIL: Heart Rate Type"); return }
        
        print("STEP 3: All Types Created")
        
        let typesToShare: Set<HKSampleType> = [stepsType, weightType, tempType, o2Type, bpSystolic, bpDiastolic, glucoseType, distanceType, heartRateType]
        let typesToRead: Set<HKObjectType> = [stepsType, weightType, tempType, o2Type, bpSystolic, bpDiastolic, glucoseType, distanceType, heartRateType]
        
        print("STEP 4: About to call requestAuthorization")
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] (success, error) in
            print("STEP 5: Callback received inside closure")
            guard let self = self else { return }
            
            if !success {
                print("Authorization failed or was cancelled. Prompting again...")
                // Recursive call to "prompt again" if the user cancelled
                self.requestHealthAuthorization(showPermissionSuccessAlert: showPermissionSuccessAlert, completion: completion)
                return
            }
            
            if let error = error {
                print("ERROR: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            let status = self.healthStore.authorizationStatus(for: stepsType)
            let granted = (status == .sharingAuthorized)
            
            print("Authorization status for steps: \(status.rawValue)")
            DispatchQueue.main.async {
                self.isStepsAuthorized = granted
                if status == .sharingDenied {
                    self.showSettingsAlert = true
                } else if granted, showPermissionSuccessAlert {
                    self.showPermissionAuthorizedAlert = true
                }
                completion(granted)
                self.refreshAuthorizationButtonsState()
            }
        }
        
        print("STEP 6: Code execution continued after requestAuthorization call (waiting for callback)")
    }
    
    // MARK: - Dummy Data Insertion Helper
    
    /// Deletes all samples of the given types that this app is allowed to remove (typically those this app saved), across all time.
    private func deleteAllSamplesForTypesThenRun(
        _ types: [HKObjectType],
        completion: @escaping () -> Void
    ) {
        guard !types.isEmpty else {
            completion()
            return
        }
        
        let predicate = HKQuery.predicateForSamples(
            withStart: .distantPast,
            end: .distantFuture,
            options: []
        )
        
        func deleteNext(index: Int) {
            if index >= types.count {
                completion()
                return
            }
            let objectType = types[index]
            healthStore.deleteObjects(of: objectType, predicate: predicate) { success, deletedCount, error in
                if let error = error {
                    print("DEBUG: Delete \(objectType) — error: \(error.localizedDescription)")
                } else {
                    print("DEBUG: Delete \(objectType) — success=\(success), removed=\(deletedCount)")
                }
                deleteNext(index: index + 1)
            }
        }
        
        print("DEBUG: Wiping prior app-written samples (\(types.count) object types)...")
        deleteNext(index: 0)
    }
    
    /// Runs `delete → insert` for each metric in order so we only clear HealthKit types tied to the import about to run.
    private func sequentiallyDeleteThenInsertDummyMetrics(
        _ metrics: [DummyHealthMetric],
        index: Int = 0,
        completion: @escaping () -> Void
    ) {
        if index >= metrics.count {
            completion()
            return
        }
        let metric = metrics[index]
        let types = metric.objectTypesToClear()
        deleteAllSamplesForTypesThenRun(types) { [weak self] in
            guard let self else {
                completion()
                return
            }
            print("DEBUG: Starting batch insertion for \(metric.displayTitle)...")
            self.insertDummySamples(for: metric)
            print("DEBUG: \(metric.displayTitle) insertion executed.")
            self.sequentiallyDeleteThenInsertDummyMetrics(metrics, index: index + 1, completion: completion)
        }
    }
    
    private func insertDummySamples(for metric: DummyHealthMetric) {
        switch metric {
            case .steps:
                insertDummyStepsData()
            case .weight:
                insertDummyWeightData()
            case .bodyTemperature:
                insertDummyTemperatureData()
            case .oxygenSaturation:
                insertDummyO2Data()
            case .bloodPressure:
                insertDummyBloodPressureData()
            case .bloodGlucose:
                insertDummyBloodGlucoseData()
            case .distanceWalkingRunning:
                insertDummyDistanceWalkingRunningData()
            case .heartRate:
                insertDummyHeartRateData()
        }
    }
    
    // Helper to ensure auth exists before inserting
    func triggerDummyDataInsertion() {
        print("DEBUG: Requesting HealthKit authorization...")
        
        requestHealthAuthorization(showPermissionSuccessAlert: false) { [weak self] success in
            guard success else {
                // Error Log: Critical failure point
                print("ERROR: HealthKit authorization failed or was denied by user. Data insertion aborted.")
                return
            }
            
            print("DEBUG: Authorization granted. Proceeding to background queue.")
            
            // Run insertions on a background queue to avoid blocking UI
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async {
                guard let self else { return }
                self.sequentiallyDeleteThenInsertDummyMetrics(Array(DummyHealthMetric.allCases)) {
                    print("DEBUG: All dummy data insertion tasks finished.")
                    DispatchQueue.main.async {
                        self.showDummyDataImportedAlert = true
                        self.dummyDataImportedMessage = "Sample data for every metric was written to Health. It may take a moment to appear in the Health app."
                    }
                }
            }
        }
    }
    
    /// One dummy metric at a time: clears only HealthKit types used by that metric, then inserts fresh dummy samples.
    enum DummyHealthMetric: String, CaseIterable, Identifiable {
        case steps
        case weight
        case bodyTemperature
        case oxygenSaturation
        case bloodPressure
        case bloodGlucose
        case distanceWalkingRunning
        case heartRate
        
        var id: String { rawValue }
        
        var displayTitle: String {
            switch self {
                case .steps: return "Steps"
                case .weight: return "Weight"
                case .bodyTemperature: return "Body Temperature"
                case .oxygenSaturation: return "Oxygen Saturation"
                case .bloodPressure: return "Blood Pressure"
                case .bloodGlucose: return "Blood Glucose"
                case .distanceWalkingRunning: return "Distance Walking/Running"
                case .heartRate: return "Heart Rate"
            }
        }
        
        fileprivate func objectTypesToClear() -> [HKObjectType] {
            func q(_ id: HKQuantityTypeIdentifier) -> HKObjectType? {
                HKQuantityType.quantityType(forIdentifier: id)
            }
            switch self {
                case .steps:
                    return [q(.stepCount)].compactMap { $0 }
                case .weight:
                    return [q(.bodyMass)].compactMap { $0 }
                case .bodyTemperature:
                    return [q(.bodyTemperature)].compactMap { $0 }
                case .oxygenSaturation:
                    return [q(.oxygenSaturation)].compactMap { $0 }
                case .bloodPressure:
                    var types: [HKObjectType] = [q(.bloodPressureSystolic), q(.bloodPressureDiastolic)].compactMap { $0 }
                    if let bp = HKCorrelationType.correlationType(forIdentifier: .bloodPressure) {
                        types.append(bp)
                    }
                    return types
                case .bloodGlucose:
                    return [q(.bloodGlucose)].compactMap { $0 }
                case .distanceWalkingRunning:
                    return [q(.distanceWalkingRunning)].compactMap { $0 }
                case .heartRate:
                    return [q(.heartRate)].compactMap { $0 }
            }
        }
    }
    
    func triggerDummyDataInsertion(for metric: DummyHealthMetric) {
        print("DEBUG: Requesting HealthKit authorization (single metric: \(metric.displayTitle))...")
        
        requestHealthAuthorization(showPermissionSuccessAlert: false) { [weak self] success in
            guard success else {
                print("ERROR: HealthKit authorization failed. \(metric.displayTitle) dummy insertion aborted.")
                return
            }
            
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async { [weak self] in
                guard let self else { return }
                let types = metric.objectTypesToClear()
                self.deleteAllSamplesForTypesThenRun(types) {
                    print("DEBUG: Starting dummy insertion for \(metric.displayTitle)...")
                    self.insertDummySamples(for: metric)
                    print("DEBUG: Dummy insertion dispatched for \(metric.displayTitle).")
                    DispatchQueue.main.async {
                        self.showDummyDataImportedAlert = true
                        self.dummyDataImportedMessage = "Sample data for \(metric.displayTitle) was written to Health. It may take a moment to appear in the Health app."
                    }
                }
            }
        }
    }
    
    /// Inserts `spO2SampleCount` SpO₂ readings (not “50k days”) inside at most **5 calendar years** ending at `anchor`: samples are split across each day in that window so days carry many readings. Pairs `pairedHeartRateCount` heart rate samples to a subset of those timestamps.
    func triggerStressTestSpO2HeartRateInsertion(
        spO2SpanYears: Int = 5,
        spO2SampleCount: Int = 50_000,
        pairedHeartRateCount: Int = 1000
    ) {
        print("DEBUG: Stress test — requesting HealthKit authorization...")
        
        requestHealthAuthorization(showPermissionSuccessAlert: false) { [weak self] success in
            guard success else {
                print("ERROR: HealthKit authorization failed. Stress test insertion aborted.")
                return
            }
            
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async { [weak self] in
                guard let self else { return }
                let stressTypes =
                    DummyHealthMetric.oxygenSaturation.objectTypesToClear()
                    + DummyHealthMetric.heartRate.objectTypesToClear()
                self.deleteAllSamplesForTypesThenRun(stressTypes) {
                    let anchor = Date()
                    let (spO2Dates, windowStart, _) = self.stressTestSpO2Window(spanYears: spO2SpanYears, spO2Count: spO2SampleCount, windowEnd: anchor)
                    guard !spO2Dates.isEmpty else {
                        print("ERROR: Stress test — empty SpO₂ timestamp list; insertion aborted.")
                        return
                    }
                    let hrCount = min(pairedHeartRateCount, spO2Dates.count)
                    let heartRateDates = self.stressTestEvenlySpacedSubsetDates(from: spO2Dates, subsetCount: hrCount)
                    print("DEBUG: Stress test — \(spO2Dates.count) SpO₂ from \(windowStart) … \(anchor); \(heartRateDates.count) HR on subset of those timestamps")
                    self.insertStressTestO2Data(sampleDates: spO2Dates)
                    print("DEBUG: Stress test SpO₂ save dispatched (chunked).")
                    self.insertStressTestHeartRateData(sampleDates: heartRateDates)
                    print("DEBUG: Stress test Heart Rate save dispatched.")
                }
            }
        }
    }
    
    // MARK: - 0. Steps
    private func insertDummyStepsData(startYear: Int = 2023, endYear: Int = 2025) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            print("Could not create step count type")
            return
        }
        
        let calendar = Calendar.current
        var currentDate = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1))!
        let endDate = calendar.date(from: DateComponents(year: endYear, month: 12, day: 31))!
        
        var samplesToSave: [HKQuantitySample] = []
        
        while currentDate <= endDate {
            // Generate random step count between 1000 and 10000
            let randomSteps = Double.random(in: 1000...10000)
            
            let quantity = HKQuantity(unit: .count(), doubleValue: randomSteps)
            
            let sample = HKQuantitySample(
                type: type,
                quantity: quantity,
                start: currentDate,
                end: currentDate
            )
            
            samplesToSave.append(sample)
            
            // Move to next day
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        healthStore.save(samplesToSave) { (success, error) in
            if let error = error {
                print("Error saving dummy steps data: \(error.localizedDescription)")
            } else {
                print("Successfully saved \(samplesToSave.count) dummy step samples")
            }
        }
    }
    
    // MARK: - 1. Weight (Body Mass)
    private func insertDummyWeightData(startYear: Int = 2023, endYear: Int = 2025) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return }
        
        let calendar = Calendar.current
        var currentDate = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1))!
        let endDate = calendar.date(from: DateComponents(year: endYear, month: 12, day: 31))!
        var samplesToSave: [HKQuantitySample] = []
        
        while currentDate <= endDate {
            // Random weight between 60kg and 80kg
            let randomWeight = Double.random(in: 60...80)
            let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: randomWeight)
            
            let sample = HKQuantitySample(type: type, quantity: quantity, start: currentDate, end: currentDate)
            samplesToSave.append(sample)
            
            // Weight is usually measured less often, e.g., once a week
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        healthStore.save(samplesToSave) { success, error in
            if let error = error { print("Error saving weight: \(error)") }
            else { print("Saved \(samplesToSave.count) weight samples") }
        }
    }
    
    // MARK: - 2. Body Temperature
    private func insertDummyTemperatureData(startYear: Int = 2023, endYear: Int = 2025) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyTemperature) else { return }
        
        let calendar = Calendar.current
        var currentDate = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1))!
        let endDate = calendar.date(from: DateComponents(year: endYear, month: 12, day: 31))!
        var samplesToSave: [HKQuantitySample] = []
        
        while currentDate <= endDate {
            // Random temp between 36.1 and 37.2 Celsius
            let randomTemp = Double.random(in: 36.1...37.2)
            let quantity = HKQuantity(unit: .degreeCelsius(), doubleValue: randomTemp)
            
            let sample = HKQuantitySample(type: type, quantity: quantity, start: currentDate, end: currentDate)
            samplesToSave.append(sample)
            
            // Measured daily
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        healthStore.save(samplesToSave) { success, error in
            if let error = error { print("Error saving temp: \(error)") }
            else { print("Saved \(samplesToSave.count) temp samples") }
        }
    }
    
    // MARK: - 3. Oxygen Saturation
    private func insertDummyO2Data(startYear: Int = 2023, endYear: Int = 2025) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { return }
        
        let calendar = Calendar.current
        var currentDate = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1))!
        let endDate = calendar.date(from: DateComponents(year: endYear, month: 12, day: 31))!
        var samplesToSave: [HKQuantitySample] = []
        
        while currentDate <= endDate {
            // Random O2 between 95% and 100% (0.95 - 1.00)
            let randomO2 = Double.random(in: 0.95...1.0)
            let quantity = HKQuantity(unit: .percent(), doubleValue: randomO2)
            
            let sample = HKQuantitySample(type: type, quantity: quantity, start: currentDate, end: currentDate)
            samplesToSave.append(sample)
            
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        healthStore.save(samplesToSave) { _, error in
            if let error = error { print("Error saving O2: \(error)") }
            else { print("Saved \(samplesToSave.count) O2 samples") }
        }
    }
    
    // MARK: - 4. Blood Pressure (Correlation)
    private func insertDummyBloodPressureData(startYear: Int = 2023, endYear: Int = 2025) {
        guard let systolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diastolicType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
              let correlationType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure) else {
            return
        }
        
        let calendar = Calendar.current
        var currentDate = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1))!
        let endDate = calendar.date(from: DateComponents(year: endYear, month: 12, day: 31))!
        var correlationsToSave: [HKCorrelation] = []
        
        while currentDate <= endDate {
            // 1. Generate random values (Normal range approx: 120/80)
            let randomSystolic = Double.random(in: 110...130)
            let randomDiastolic = Double.random(in: 70...85)
            
            // 2. Create Quantities
            let systolicQuantity = HKQuantity(unit: .millimeterOfMercury(), doubleValue: randomSystolic)
            let diastolicQuantity = HKQuantity(unit: .millimeterOfMercury(), doubleValue: randomDiastolic)
            
            // 3. Create Samples
            let systolicSample = HKQuantitySample(type: systolicType, quantity: systolicQuantity, start: currentDate, end: currentDate)
            let diastolicSample = HKQuantitySample(type: diastolicType, quantity: diastolicQuantity, start: currentDate, end: currentDate)
            
            // 4. Create Correlation (Grouping them together)
            let correlation = HKCorrelation(type: correlationType,
                                            start: currentDate,
                                            end: currentDate,
                                            objects: [systolicSample, diastolicSample])
            
            correlationsToSave.append(correlation)
            
            // Add daily
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        // 5. Save Correlations
        healthStore.save(correlationsToSave) { success, error in
            if let error = error { print("Error saving BP: \(error)") }
            else { print("Saved \(correlationsToSave.count) BP correlations") }
        }
    }
    
    // MARK: - 5. Blood Glucose
    private func insertDummyBloodGlucoseData(startYear: Int = 2023, endYear: Int = 2025) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { return }
        
        let calendar = Calendar.current
        var currentDate = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1))!
        let endDate = calendar.date(from: DateComponents(year: endYear, month: 12, day: 31))!
        var samplesToSave: [HKQuantitySample] = []
        
        // Define Unit: mg/dL
        let unit = HKUnit(from: "mg/dL")
        
        while currentDate <= endDate {
            // Random Glucose between 70 (Fasting) and 140 (Post-meal)
            let randomGlucose = Double.random(in: 70...140)
            let quantity = HKQuantity(unit: unit, doubleValue: randomGlucose)
            
            // Save usually happens 1-3 times a day for tracking, we'll just do one daily here
            let sample = HKQuantitySample(type: type, quantity: quantity, start: currentDate, end: currentDate)
            samplesToSave.append(sample)
            
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        healthStore.save(samplesToSave) { success, error in
            if let error = error { print("Error saving Glucose: \(error)") }
            else { print("Saved \(samplesToSave.count) Glucose samples") }
        }
    }
    
    // MARK: - 6. Distance Walking/Running
    private func insertDummyDistanceWalkingRunningData(startYear: Int = 2023, endYear: Int = 2025) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return }
        
        let calendar = Calendar.current
        var currentDate = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1))!
        let endDate = calendar.date(from: DateComponents(year: endYear, month: 12, day: 31))!
        var samplesToSave: [HKQuantitySample] = []
        
        while currentDate <= endDate {
            // Random distance between 500m and 5000m
            let randomDistance = Double.random(in: 500...5000)
            let quantity = HKQuantity(unit: .meter(), doubleValue: randomDistance)
            
            let sample = HKQuantitySample(type: type, quantity: quantity, start: currentDate, end: currentDate)
            samplesToSave.append(sample)
            
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        healthStore.save(samplesToSave) { success, error in
            if let error = error { print("Error saving Distance: \(error)") }
            else { print("Saved \(samplesToSave.count) Distance samples") }
        }
    }
    
    // MARK: - 7. Heart Rate
    private func insertDummyHeartRateData(startYear: Int = 2023, endYear: Int = 2025) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        
        let calendar = Calendar.current
        var currentDate = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1))!
        let endDate = calendar.date(from: DateComponents(year: endYear, month: 12, day: 31))!
        var samplesToSave: [HKQuantitySample] = []
        
        let unit = HKUnit.count().unitDivided(by: .minute())
        
        while currentDate <= endDate {
            // Random Heart Rate between 60 and 100 bpm
            let randomHR = Double.random(in: 60...100)
            let quantity = HKQuantity(unit: unit, doubleValue: randomHR)
            
            let sample = HKQuantitySample(type: type, quantity: quantity, start: currentDate, end: currentDate)
            samplesToSave.append(sample)
            
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        healthStore.save(samplesToSave) { _, error in
            if let error = error { print("Error saving Heart Rate: \(error)") }
            else { print("Saved \(samplesToSave.count) Heart Rate samples") }
        }
    }
    
    // MARK: - SpO₂ / Heart rate stress test inserts
    /// Up to **5 years** of calendar time ending at `windowEnd`. `spO2Count` samples are spread **by day**: each day gets roughly `spO2Count / dayCount` timestamps within that day so the total is still `spO2Count` (dense per-day data, not one sample per day across decades).
    private func stressTestSpO2Window(spanYears: Int, spO2Count: Int, windowEnd: Date) -> (sampleDates: [Date], windowStart: Date, windowEnd: Date) {
        let calendar = Calendar.current
        let cappedYears = min(max(1, spanYears), 5)
        guard let windowStart = calendar.date(byAdding: .year, value: -cappedYears, to: windowEnd) else {
            return ([], windowEnd, windowEnd)
        }
        guard spO2Count > 0 else { return ([], windowStart, windowEnd) }
        
        var dayStarts: [Date] = []
        var d = calendar.startOfDay(for: windowStart)
        while d <= windowEnd {
            dayStarts.append(d)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = nextDay
        }
        let numDays = dayStarts.count
        guard numDays > 0 else { return ([], windowStart, windowEnd) }
        
        let basePerDay = spO2Count / numDays
        let extraSamples = spO2Count % numDays
        
        var dates: [Date] = []
        dates.reserveCapacity(spO2Count)
        
        for (dayIndex, dayStart) in dayStarts.enumerated() {
            let nToday = basePerDay + (dayIndex < extraSamples ? 1 : 0)
            guard nToday > 0 else { continue }
            
            guard let dayEndExclusive = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let sliceStart = max(dayStart, windowStart)
            let sliceEnd = min(dayEndExclusive, windowEnd)
            let slice = sliceEnd.timeIntervalSince(sliceStart)
            guard slice > 0 else { continue }
            
            let denom = Double(max(1, nToday - 1))
            for i in 0..<nToday {
                let u = nToday == 1 ? 0.5 : Double(i) / denom
                // Keep samples strictly inside the clipped day slice so adjacent days do not collide at midnight.
                let t = sliceStart.addingTimeInterval(slice * (0.001 + u * 0.998))
                dates.append(t)
            }
        }
        
        dates.sort()
        return (dates, windowStart, windowEnd)
    }
    
    /// Picks `subsetCount` timestamps from `allDates` at evenly spaced indices (each HR aligns with a real SpO₂ sample time).
    private func stressTestEvenlySpacedSubsetDates(from allDates: [Date], subsetCount: Int) -> [Date] {
        guard subsetCount > 0, !allDates.isEmpty else { return [] }
        let last = allDates.count - 1
        if subsetCount == 1 { return [allDates[0]] }
        return (0..<subsetCount).map { i in
            let idx = Int((Double(last) * Double(i) / Double(subsetCount - 1)).rounded())
            return allDates[min(max(0, idx), last)]
        }
    }
    
    private func insertStressTestO2Data(sampleDates: [Date]) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { return }
        
        guard !sampleDates.isEmpty else {
            print("Error saving stress-test O2: empty timeline")
            return
        }
        
        var samplesToSave: [HKQuantitySample] = []
        samplesToSave.reserveCapacity(sampleDates.count)
        
        for d in sampleDates {
            let randomO2 = Double.random(in: 0.95...1.0)
            let quantity = HKQuantity(unit: .percent(), doubleValue: randomO2)
            samplesToSave.append(HKQuantitySample(type: type, quantity: quantity, start: d, end: d))
        }
        
        saveQuantitySamplesInChunks(samplesToSave) { error in
            if let error = error { print("Error saving stress-test O2: \(error)") }
            else { print("Saved \(samplesToSave.count) stress-test O2 samples (chunked)") }
        }
    }
    
    private func insertStressTestHeartRateData(sampleDates: [Date]) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        
        guard !sampleDates.isEmpty else {
            print("Error saving stress-test Heart Rate: empty timeline")
            return
        }
        
        let unit = HKUnit.count().unitDivided(by: .minute())
        var samplesToSave: [HKQuantitySample] = []
        samplesToSave.reserveCapacity(sampleDates.count)
        
        for d in sampleDates {
            let randomHR = Double.random(in: 60...100)
            let quantity = HKQuantity(unit: unit, doubleValue: randomHR)
            samplesToSave.append(HKQuantitySample(type: type, quantity: quantity, start: d, end: d))
        }
        
        healthStore.save(samplesToSave) { saveSucceeded, error in
            if let error = error { print("Error saving stress-test Heart Rate: \(error)") }
            else if !saveSucceeded { print("Error saving stress-test Heart Rate: success=false") }
            else { print("Saved \(samplesToSave.count) stress-test Heart Rate samples (subset of SpO₂ times)") }
        }
    }
    
    private func saveQuantitySamplesInChunks(_ samples: [HKQuantitySample], chunkSize: Int = 5_000, completion: @escaping (Error?) -> Void) {
        guard !samples.isEmpty else {
            completion(nil)
            return
        }
        
        func saveChunk(at index: Int) {
            let end = min(index + chunkSize, samples.count)
            let chunk = Array(samples[index..<end])
            healthStore.save(chunk) { saveSucceeded, error in
                if let error = error {
                    completion(error)
                    return
                }
                if !saveSucceeded {
                    completion(NSError(
                        domain: "HealthKit",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "healthStore.save returned success=false for chunk \(index)..<\(end)"]
                    ))
                    return
                }
                if end >= samples.count {
                    completion(nil)
                } else {
                    saveChunk(at: end)
                }
            }
        }
        
        saveChunk(at: 0)
    }
}
