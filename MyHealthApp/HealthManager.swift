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
    
    func requestAuthorization() {
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
}
