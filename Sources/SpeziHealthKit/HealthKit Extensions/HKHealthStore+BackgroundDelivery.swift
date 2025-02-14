//
// This source file is part of the Stanford Spezi open-source project
//
// SPDX-FileCopyrightText: 2022 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import HealthKit
import OSLog
import Spezi


extension HKHealthStore {
    private static let activeObservationsLock = NSLock()
    private static nonisolated(unsafe) var activeObservations: [HKObjectType: Int] = [:]
    

    @MainActor
    func startBackgroundDelivery(
        for sampleTypes: Set<HKSampleType>,
        withPredicate predicate: NSPredicate? = nil,
        observerQuery: @escaping @Sendable @MainActor (
            Result<(sampleTypes: Set<HKSampleType>, completionHandler: HKObserverQueryCompletionHandler), Error>
        ) async -> Void
    ) async throws {
        var queryDescriptors: [HKQueryDescriptor] = []
        for sampleType in sampleTypes {
            queryDescriptors.append(
                HKQueryDescriptor(sampleType: sampleType, predicate: predicate)
            )
        }
        
        let observerQuery = HKObserverQuery(queryDescriptors: queryDescriptors) { query, samples, completionHandler, error in
            // From https://developer.apple.com/documentation/healthkit/hkobserverquery/executing_observer_queries:
            // "Whenever a matching sample is added to or deleted from the HealthKit store,
            // the system calls the query’s update handler on the same background queue (but not necessarily the same thread)."
            // So, the observerQuery has to be @Sendable!
            
            // Sadly necessary to enable capture of the `completionHandler` within the `Task`s below (isolation error)
            nonisolated(unsafe) let completionHandler = completionHandler
            
            guard error == nil,
                  let samples else {
                Logger.healthKit.error("Failed HealthKit background delivery for observer query \(query) with error: \(error)")
                Task { @MainActor in
                    await observerQuery(.failure(error ?? NSError(domain: "Spezi HealthKit", code: -1)))
                    completionHandler()
                }
                return
            }
            
            Task { @MainActor in
                await observerQuery(.success((samples, completionHandler)))
            }
        }
        
        self.execute(observerQuery)
        try await enableBackgroundDelivery(for: sampleTypes)
    }
    
    
    private func enableBackgroundDelivery(
        for objectTypes: Set<HKObjectType>,
        frequency: HKUpdateFrequency = .immediate
    ) async throws {
        try await self.requestAuthorization(toShare: [], read: objectTypes as Set<HKObjectType>)
        
        var enabledObjectTypes: Set<HKObjectType> = []
        do {
            for objectType in objectTypes {
                try await self.enableBackgroundDelivery(for: objectType, frequency: frequency)
                enabledObjectTypes.insert(objectType)
                Self.activeObservationsLock.withLock {
                    HKHealthStore.activeObservations[objectType] = HKHealthStore.activeObservations[objectType, default: 0] + 1
                }
            }
        } catch {
            Logger.healthKit.error("Could not enable HealthKit Backgound access for \(objectTypes): \(error.localizedDescription)")
            // Revert all changes as enable background delivery for the object types failed.
            disableBackgroundDelivery(for: enabledObjectTypes)
        }
    }
    
    
    private func disableBackgroundDelivery(
        for objectTypes: Set<HKObjectType>
    ) {
        for objectType in objectTypes {
            Self.activeObservationsLock.withLock {
                if let activeObservation = HKHealthStore.activeObservations[objectType] {
                    let newActiveObservation = activeObservation - 1
                    if newActiveObservation <= 0 {
                        HKHealthStore.activeObservations[objectType] = nil
                        Task { @MainActor in
                            try await self.disableBackgroundDelivery(for: objectType)
                        }
                    } else {
                        HKHealthStore.activeObservations[objectType] = newActiveObservation
                    }
                }
            }
        }
    }
}
