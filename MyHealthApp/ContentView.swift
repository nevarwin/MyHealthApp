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
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDeleteAllLocalDataConfirm = false
    
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
                            hkManager.distanceWalkingRunningAuthorization()
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        // .buttonStyle(.borderless) is important here!
                        // Without it, clicking the button triggers the NavigationLink
                        .buttonStyle(.borderless)
                        .disabled(hkManager.isDistanceWalkingReadAuthUnnecessary)
                    }
                    .padding(.vertical, 8)
                }
                
                HStack {
                    Button(action: {
                        hkManager.triggerDummyDataInsertion()
                    }){
                        Image(systemName: "cylinder.split.1x2")
                            .foregroundColor(.orange)
                            .imageScale(.large)
                    }
                    Text("All data")
                        .font(.subheadline)
                    
                    Spacer()
                    
                    // The Permission Button inside the cell
                    Button("Authorize") {
                        hkManager.requestHealthAuthorization { success in
                            print("Authorization result: \(success)")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    // .buttonStyle(.borderless) is important here!
                    // Without it, clicking the button triggers the NavigationLink
                    .buttonStyle(.borderless)
                    .disabled(hkManager.isStepsAuthorized)
                    
                }
                .padding(.vertical, 8)
                
                Section("Dummy data (one type)") {
                    ForEach(HealthKitManager.DummyHealthMetric.allCases) { metric in
                        HStack {
                            Button(action: {
                                hkManager.triggerDummyDataInsertion(for: metric)
                            }) {
                                Image(systemName: "cylinder.split.1x2")
                                    .foregroundColor(.orange)
                                    .imageScale(.large)
                            }
                            Text(metric.displayTitle)
                                .font(.subheadline)
                            
                            Spacer()
                            
                            Button("Authorize") {
                                hkManager.requestHealthAuthorization { success in
                                    print("Authorization result: \(success)")
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                            .buttonStyle(.borderless)
                            .disabled(hkManager.isStepsAuthorized)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                HStack {
                    Button(action: {
                        hkManager.triggerStressTestSpO2HeartRateInsertion()
                    }) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.orange)
                            .imageScale(.large)
                    }
                    Text("SpO₂ / HR stress test (1k + 50k)")
                        .font(.subheadline)
                    
                    Spacer()
                    
                    Button("Authorize") {
                        hkManager.requestHealthAuthorization { success in
                            print("Authorization result: \(success)")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .buttonStyle(.borderless)
                    .disabled(hkManager.isStepsAuthorized)
                }
                .padding(.vertical, 8)
                
                Section {
                    Button(role: .destructive) {
                        showDeleteAllLocalDataConfirm = true
                    } label: {
                        Label("Delete all app health data", systemImage: "trash")
                    }
                } footer: {
                    Text("Removes walking history saved in this app and resets sync. Samples in the Apple Health app are not deleted.")
                }
                
            }
            .navigationTitle("Health Dashboard")
            .onAppear {
                hkManager.refreshAuthorizationButtonsState()
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    hkManager.refreshAuthorizationButtonsState()
                }
            }
            .alert("Health Access Required", isPresented: $hkManager.showSettingsAlert) {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Authorization was previously denied. Please enable Health access in Settings to use this feature.")
            }
            .alert("Health access granted", isPresented: $hkManager.showPermissionAuthorizedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Health permissions were authorized. You can import or read data from Health.")
            }
            .alert("Dummy data import complete", isPresented: $hkManager.showDummyDataImportedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(hkManager.dummyDataImportedMessage)
            }
            .confirmationDialog(
                "Delete all data stored in this app?",
                isPresented: $showDeleteAllLocalDataConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete all", role: .destructive) {
                    hkManager.deleteAllLocallyCachedHealthData()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This clears your local walking totals and the sync bookmark. You can pull data from Health again with Refresh.")
            }
        }
    }
}

#Preview {
    ContentView()
}
