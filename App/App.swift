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

import SwiftUI

#if os(visionOS)
import CompositorServices

extension RenderLayout {
    init (_ layout: LayerRenderer.Layout) {
        switch layout {
        case .shared:
            self = .shared
        case .layered:
            self = .layered
        case .dedicated:
            fallthrough
        default:
            self = .dedicated
        }
    }
}

// A type that can be used to customize the creation of a LayerRenderer
struct LayerConfiguration : CompositorLayerConfiguration {
    let context: MetalContext

    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration)
    {
        // Enable foveated rendering if available
        let supportsFoveation = capabilities.supportsFoveation
        configuration.isFoveationEnabled = supportsFoveation

        // Select a layout based on device capabilities
        let canUseAmplification = context.device.supportsVertexAmplificationCount(2)
        let supportedLayouts = capabilities.supportedLayouts(options: supportsFoveation ? .foveationEnabled : [])
        if supportedLayouts.contains(.layered) {
            // Layered rendering isn't supported everywhere, but when available, it is the most efficient option.
            configuration.layout = .layered
            print("Selected layered renderer layout")
        } else if canUseAmplification && !configuration.isFoveationEnabled {
            // On platforms where layered rendering isn't supported, we can use a
            // shared layout, provided we don't use foeveated rendering.
            configuration.layout = .shared
            print("Selected shared renderer layout")
        } else {
            // If all else fails, we can use a dedicated layout, but this requires one pass per view.
            configuration.layout = .dedicated
            print("Selected dedicated renderer layout")
        }

        // Use the global preferred pixel formats as our drawable formats
        configuration.colorFormat = context.preferredColorPixelFormat
        configuration.depthFormat = context.preferredDepthPixelFormat
    }
}

@main
struct SpatialApp: App {
    @State var context = MetalContext.shared
    @State var selectedImmersionStyle: (any ImmersionStyle) = .mixed

    init() {
        SRJPhysicsWorld.initializeJoltPhysics()
    }

    var body: some Scene {
        ImmersiveSpace(id: "Immersive Space") {
            // The content of this immersive space is a compositor layer, which
            // allows us to render mixed and fully immersive 3D content via a
            // layer renderer
            CompositorLayer(configuration: LayerConfiguration(context: context)) { layerRenderer in
                // Spin up a high-priority task so updates and rendering happen off the main thread
                Task.detached(priority: .high) {
                    await runRenderLoop(layerRenderer)
                }
            }
        }
        .immersionStyle(selection: $selectedImmersionStyle, in: .mixed, .full)
        // Prevent hands from occluding rendered content
        .upperLimbVisibility(.hidden)
        // Prevent home button from interfering with interaction/gestures
        .persistentSystemOverlays(.hidden)
    }

    func runRenderLoop(_ layerRenderer: LayerRenderer) async {
        do {
            // We need an ARKit session to be running in order to determine where
            // spatial content should be drawn, so get that going first.
            let sessionManager = ARSessionManager()
            try await sessionManager.start(options: [.planeDetection, .sceneReconstruction, .handTracking, .lightEstimation])

            // Load scene content
            let scene = try SpatialScene(sessionManager: sessionManager, context: context)

            // Create a renderer
            let renderer = try SceneRenderer(context: context, layout: RenderLayout(layerRenderer.configuration.layout))

            // Subscribe to world-sensing updates
            sessionManager.onWorldAnchorUpdate = { worldAnchor, event in
                scene.enqueueEvent(.worldAnchor(worldAnchor, event))
            }
            sessionManager.onPlaneAnchorUpdate = { planeAnchor, event in
                scene.enqueueEvent(.planeAnchor(planeAnchor, event))
            }
            sessionManager.onMeshAnchorUpdate = { meshAnchor, event in
                scene.enqueueEvent(.meshAnchor(meshAnchor, event))
            }
            sessionManager.onEnvironmentLightAnchorUpdate = { lightAnchor, event in
                scene.enqueueEvent(.environmentLightAnchor(lightAnchor, event))
            }

            // Subscribe to spatial events from the layer renderer
            layerRenderer.onSpatialEvent = { events in
				for event in events {
					scene.enqueueEvent(.spatialInput(SpatialInputEvent(event)))
				}
            }

            // Create a render loop to draw our immersive content on a cadence determined by the system
            let renderLoop = SpatialRenderLoop(scene: scene, renderer: renderer, sessionManager: sessionManager)
            await renderLoop.run(layerRenderer)
        } catch {
            print("Failed to start render loop: \(error.localizedDescription)")
        }
        print("Exiting render loop...")
    }
}

#endif

