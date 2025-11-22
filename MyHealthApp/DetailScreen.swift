//
//  DetailScreen.swift
//  MyHealthApp
//
//  Created by raven on 11/22/25.
//

import Foundation
import SwiftUI
import HealthKit

struct DistanceDetailView: View {
    @ObservedObject var manager: HealthKitManager
    
    var body: some View {
        VStack {
            if manager.walks.isEmpty {
                VStack {
                    Image(systemName: "figure.walk.circle")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("No Data Stored")
                        .foregroundColor(.gray)
                    Text("Tap Refresh to sync from HealthKit")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxHeight: .infinity)
            } else {
                // Iterating over custom 'WalkData' objects
                List(manager.walks) { walk in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Distance")
                                .font(.headline)
                            Text(walk.startDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        // Accessing walk.value directly
                        Text(String(format: "%.2f m", walk.value))
                            .fontWeight(.bold)
                    }
                }
                .animation(.default, value: manager.walks)
            }
            
            // We keep the manual button just in case the user wants to force it
            Button(action: {
                manager.fetchWalkingRunningDistance()
            }) {
                HStack {
                    if manager.isFetching {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(manager.isFetching ? "Syncing to DB..." : "Refresh & Save")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(manager.isFetching ? Color.gray : Color.blue)
                .cornerRadius(10)
            }
            .disabled(manager.isFetching)
            .padding()
        }
        .navigationTitle("History (SQLite)")
        // --- NEW: This triggers the fetch automatically when the view loads ---
        .onAppear {
            manager.fetchWalkingRunningDistance()
        }
    }
}
