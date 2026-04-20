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
    @Published var isStepsAuthorized = false
    
    private var anchor: HKQueryAnchor?
    private let anchorKey = "walking_anchor" // Key for UserDefaults
    
    init() {
        // 1. Load the saved bookmark from disk
        loadAnchor()
        // 2. Load the visual data from DB
        loadLocalData()
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
        healthStore.requestAuthorization(toShare: nil, read: [type]) { _, _ in }
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
    func requestHealthAuthorization(completion: @escaping (Bool) -> Void) {
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
        
        print("STEP 3: All Types Created")
        
        let typesToShare: Set<HKSampleType> = [stepsType, weightType, tempType, o2Type, bpSystolic, bpDiastolic, glucoseType]
        let typesToRead: Set<HKObjectType> = [stepsType, weightType, tempType, o2Type, bpSystolic, bpDiastolic, glucoseType]
        
        print("STEP 4: About to call requestAuthorization")
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { (success, error) in
            print("STEP 5: Callback received inside closure")
            
            if let error = error {
                print("ERROR: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            DispatchQueue.main.async {
                // self.isHealthAuthorized = success
            }
            
            print("Authorization result: \(success)")
            completion(success)
        }
        
        print("STEP 6: Code execution continued after requestAuthorization call (waiting for callback)")
    }
    
    // MARK: - Dummy Data Insertion Helper
    // Helper to ensure auth exists before inserting
    func triggerDummyDataInsertion() {
        print("DEBUG: Requesting HealthKit authorization...")
        
        requestHealthAuthorization { [weak self] success in
            guard success else {
                // Error Log: Critical failure point
                print("ERROR: HealthKit authorization failed or was denied by user. Data insertion aborted.")
                return
            }
            
            print("DEBUG: Authorization granted. Proceeding to background queue.")
            
            // Run insertions on a background queue to avoid blocking UI
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async {
                print("DEBUG: Starting batch insertion operations...")
                
                // Note: Since these methods are called sequentially, we log as we go
                // to identify which specific operation might be causing issues if the app crashes.
                
                self?.insertDummyStepsData()
                print("DEBUG: Steps insertion executed.")
                
                self?.insertDummyWeightData()
                print("DEBUG: Weight insertion executed.")
                
                self?.insertDummyTemperatureData()
                print("DEBUG: Temperature insertion executed.")
                
                self?.insertDummyO2Data()
                print("DEBUG: Oxygen Saturation insertion executed.")
                
                self?.insertDummyBloodPressureData()
                print("DEBUG: Blood Pressure insertion executed.")
                
                self?.insertDummyBloodGlucoseData()
                print("DEBUG: Blood Glucose insertion executed.")
                
                print("DEBUG: All dummy data insertion tasks finished.")
            }
        }
    }
    
    // MARK: - 0. Steps
    private func insertDummyStepsData(startYear: Int = 2018, endYear: Int = 2022) {
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
    private func insertDummyWeightData(startYear: Int = 2018, endYear: Int = 2020) {
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
    private func insertDummyTemperatureData(startYear: Int = 2018, endYear: Int = 2020) {
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
    private func insertDummyO2Data(startYear: Int = 2018, endYear: Int = 2020) {
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
        
        healthStore.save(samplesToSave) { success, error in
            if let error = error { print("Error saving O2: \(error)") }
            else { print("Saved \(samplesToSave.count) O2 samples") }
        }
    }
    
    // MARK: - 4. Blood Pressure (Correlation)
    private func insertDummyBloodPressureData(startYear: Int = 2018, endYear: Int = 2020) {
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
    private func insertDummyBloodGlucoseData(startYear: Int = 2018, endYear: Int = 2020) {
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
}
