//
//  Database:WalkData.swift
//  MyHealthApp
//
//  Created by raven on 11/22/25.
//

import Foundation

// A simple model to store only the data we need in SQLite
struct WalkData: Identifiable, Equatable {
    // We use the HealthKit UUID string as our unique ID
    let id: String
    let startDate: Date
    let value: Double // Distance in meters
}
