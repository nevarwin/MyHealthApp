//
//  ContentView.swift
//  HealthKit
//
//  Created by raven on 11/22/25.
//

import SwiftUI
import HealthKit

struct ContentView: View {
    // Initialize our manager
    @StateObject var hkManager = HealthKitManager()
    
    var body: some View {
        NavigationView {
            List {
                // Section 1: Distance Walking + Running
                NavigationLink(destination: DistanceDetailView(manager: hkManager)) {
                    HStack {
                        // Icon and Title
                        Image(systemName: "figure.walk")
                            .foregroundColor(.orange)
                            .imageScale(.large)
                        
                        Text("Distance Walking + Running")
                            .font(.subheadline)
                        
                        Spacer()
                        
                        // The Permission Button inside the cell
                        Button("Authorize") {
                            hkManager.requestAuthorization()
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        // .buttonStyle(.borderless) is important here!
                        // Without it, clicking the button triggers the NavigationLink
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Health Dashboard")
        }
    }
}

#Preview {
    ContentView()
}
