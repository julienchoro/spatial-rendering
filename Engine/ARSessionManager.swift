//
// Copyright 2024 Warren Moore
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#if os(visionOS)
import ARKit

typealias WorldAnchorUpdateHandler = (WorldAnchor, AnchorEvent) -> Void
typealias MeshAnchorUpdateHandler = (MeshAnchor, AnchorEvent) -> Void
typealias PlaneAnchorUpdateHandler = (PlaneAnchor, AnchorEvent) -> Void
typealias HandAnchorUpdateHandler = (HandAnchor, AnchorEvent) -> Void
typealias EnvironmentLightAnchorUpdateHandler = (EnvironmentLightAnchor, AnchorEvent) -> Void

/// This extension maps from ARKit anchor update events to our abstract anchor event type
extension AnchorEvent {
    init<AnchorType>(_ event: AnchorUpdate<AnchorType>.Event) where AnchorType : ARKit.Anchor {
        switch event {
        case .added:
            self = .added
        case .updated:
            self = .updated
        case .removed:
            self = .removed
        }
    }
}

class ARSessionManager {
    struct Options: OptionSet {
        let rawValue: Int
        
        static let planeDetection = Options(rawValue: 1 << 0)
        static let handTracking = Options(rawValue: 1 << 1)
        static let sceneReconstruction = Options(rawValue: 1 << 2)
        static let lightEstimation = Options(rawValue: 1 << 3)

        static let all: Options = [
            .planeDetection, .handTracking, .sceneReconstruction, .lightEstimation
        ]
    }

    let arSession: ARKitSession

    var onWorldAnchorUpdate: WorldAnchorUpdateHandler?
    var onPlaneAnchorUpdate: PlaneAnchorUpdateHandler?
    var onMeshAnchorUpdate: MeshAnchorUpdateHandler?
    var onHandAnchorUpdate: HandAnchorUpdateHandler?
    var onEnvironmentLightAnchorUpdate: EnvironmentLightAnchorUpdateHandler?

    private var worldTrackingProvider: WorldTrackingProvider
    private var handTrackingProvider: HandTrackingProvider?

    init() {
        arSession = ARKitSession()
        worldTrackingProvider = WorldTrackingProvider()
    }

    func start(options: Options) async throws {
        var authorizationTypes = Set(WorldTrackingProvider.requiredAuthorizations)

        var providers: [DataProvider] = [worldTrackingProvider]

        if WorldTrackingProvider.isSupported {
            startMonitoringWorldAnchorUpdates(worldTrackingProvider)
        }
        if PlaneDetectionProvider.isSupported && options.contains(.planeDetection) {
            let provider = PlaneDetectionProvider(alignments: [.horizontal])
            authorizationTypes.formUnion(PlaneDetectionProvider.requiredAuthorizations)
            providers.append(provider)
            startMonitoringPlaneAnchorUpdates(provider)
        }
        if HandTrackingProvider.isSupported && options.contains(.handTracking) {
            handTrackingProvider = HandTrackingProvider()
            authorizationTypes.formUnion(HandTrackingProvider.requiredAuthorizations)
            providers.append(handTrackingProvider!)
            startMonitoringHandTrackingUpdates(handTrackingProvider!)
        }
        if SceneReconstructionProvider.isSupported && options.contains(.sceneReconstruction) {
            let provider = SceneReconstructionProvider(modes: [])
            authorizationTypes.formUnion(SceneReconstructionProvider.requiredAuthorizations)
            providers.append(provider)
            startMonitoringSceneReconstructionUpdates(provider)
        }
        if EnvironmentLightEstimationProvider.isSupported && options.contains(.lightEstimation) {
            let provider = EnvironmentLightEstimationProvider()
            authorizationTypes.formUnion(EnvironmentLightEstimationProvider.requiredAuthorizations)
            providers.append(provider)
            startMonitoringLightingUpdates(provider)
        }

        #if !targetEnvironment(simulator)
        print("Will query authorization for: \(authorizationTypes)")
        let authorization = await arSession.queryAuthorization(for: Array(authorizationTypes))
        // When running an AR session, the system automatically requests the authorization
        // types contained by the Info.plist, so we don't need to explicitly request anything.
        // However, we regard all required authorization types to be mandatory to proceed,
        // so it is an error for the user to have explicitly denied access. In an app
        // where world sensing or other authorization types are optional, we'd handle this
        // more gracefully.
        if authorization.values.contains(.denied) {
            fatalError("Required authorization has been denied. Aborting.")
        }
        #endif

        try await arSession.run(providers)
    }

    func stop() {
        arSession.stop()
    }

    func addWorldAnchor(originFromAnchorTransform: simd_float4x4) async throws -> WorldAnchor {
        let anchor = ARKit.WorldAnchor(originFromAnchorTransform: originFromAnchorTransform)
        try await worldTrackingProvider.addAnchor(anchor)
        return WorldAnchor(anchor)
    }

    func removeAllWorldAnchors() async throws {
        let anchors = await worldTrackingProvider.allAnchors ?? []
        for i in 0..<anchors.count {
            try await worldTrackingProvider.removeAnchor(anchors[i])
        }
    }

    func queryDeviceAnchor(at timestamp: TimeInterval) -> ARKit.DeviceAnchor? {
        if worldTrackingProvider.state == .running {
            let anchor = worldTrackingProvider.queryDeviceAnchor(atTimestamp: timestamp)
            if anchor == nil {
                print("World tracking provider is running but failed to provide a device anchor at \(timestamp)")
            }
            return anchor
        } else {
            print("World tracking provider is not running; cannot retrieve device pose.")
            return nil
        }
    }

    func queryHandAnchors(at timestamp: TimeInterval) -> (ARKit.HandAnchor?, ARKit.HandAnchor?) {
        if let provider = handTrackingProvider, provider.state == .running {
            return provider.handAnchors(at: timestamp)
        }
        return (nil, nil)
    }

    private func startMonitoringWorldAnchorUpdates(_ provider: WorldTrackingProvider) {
        Task(priority: .high) { [weak self] in
            for await update in provider.anchorUpdates {
                self?.onWorldAnchorUpdate?(WorldAnchor(update.anchor), AnchorEvent(update.event))
            }
        }
    }

    private func startMonitoringPlaneAnchorUpdates(_ provider: PlaneDetectionProvider) {
        Task(priority: .low) { [weak self] in
            for await update in provider.anchorUpdates {
                self?.onPlaneAnchorUpdate?(PlaneAnchor(update.anchor), AnchorEvent(update.event))
            }
        }
    }

    private func startMonitoringSceneReconstructionUpdates(_ provider: SceneReconstructionProvider) {
        Task(priority: .low) { [weak self] in
            for await update in provider.anchorUpdates {
                self?.onMeshAnchorUpdate?(MeshAnchor(update.anchor), AnchorEvent(update.event))
            }
        }
    }

    private func startMonitoringHandTrackingUpdates(_ provider: HandTrackingProvider) {
        Task(priority: .high) { [weak self] in
            for await update in provider.anchorUpdates {
                self?.onHandAnchorUpdate?(HandAnchor(update.anchor), AnchorEvent(update.event))
            }
        }
    }

    private func startMonitoringLightingUpdates(_ provider: EnvironmentLightEstimationProvider) {
        Task(priority: .low) { [weak self] in
            for await update in provider.anchorUpdates {
                self?.onEnvironmentLightAnchorUpdate?(EnvironmentLightAnchor(update.anchor), AnchorEvent(update.event))
            }
        }
    }
}

#endif
