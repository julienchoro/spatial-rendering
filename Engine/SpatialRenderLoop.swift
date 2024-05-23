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
import CompositorServices
import Metal
import SwiftUI

extension LayerRenderer.Drawable : FrameResourceProvider {
    var storeDepth: Bool {
        // It is important that we provide accurate depth information to
        // Compositor Services so it can accurately reproject content,
        // especially in mixed immersion ("passthrough") mode.
        true
    }
}

extension LayerRenderer.Clock.Instant {
    var timeInterval: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}

class SpatialRenderLoop {
    let context: MetalContext
    let renderer: SceneRenderer
    let scene: SceneContent
    let sessionManager: ARSessionManager

    private let clock = LayerRenderer.Clock()
    private var layerRenderer: LayerRenderer!
    private var lastFramePresentationTime: TimeInterval

    init(scene: SceneContent, renderer: SceneRenderer, sessionManager: ARSessionManager) {
        self.renderer = renderer
        self.scene = scene
        self.context = renderer.context
        self.sessionManager = sessionManager

        lastFramePresentationTime = clock.now.timeInterval
    }

    func run(_ layerRenderer: LayerRenderer) async {
        self.layerRenderer = layerRenderer

        var isRendering = true
        while isRendering {
            switch layerRenderer.state {
            case .paused:
                print("Layer renderer is in paused state.")
                layerRenderer.waitUntilRunning()
                print("Layer renderer is running.")
            case .running:
                autoreleasepool {
                    frame()
                }
            case .invalidated:
                print("Layer renderer was invalidated.")
                fallthrough
            default:
                isRendering = false
            }
        }
    }

    func frame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }
        guard let predictedTiming = frame.predictTiming() else { return }

        // Calculate timestep from previous frame to this frame, capping it at 33 ms so
        // animations don't jump way ahead in case we were paused or had a long hitch.
        let deltaTime = min(predictedTiming.presentationTime.timeInterval - lastFramePresentationTime, 1.0 / 30.0)

        frame.startUpdate()
        updateHandAnchors(at: predictedTiming.trackableAnchorTime.timeInterval)
        scene.update(deltaTime)
        frame.endUpdate()

        clock.wait(until: predictedTiming.optimalInputTime)

        frame.startSubmission()

        guard let drawable = frame.queryDrawable() else { return }
        let finalTiming = drawable.frameTiming
        let presentationTimestamp = finalTiming.presentationTime.timeInterval
        let deviceAnchor = sessionManager.queryDeviceAnchor(at: presentationTimestamp)
        drawable.deviceAnchor = deviceAnchor
        if let deviceAnchor {
            renderFrame(frame: frame, drawable: drawable, deviceAnchor: deviceAnchor)
        }

        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        commandBuffer.label = "Present Drawable"
        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()

        lastFramePresentationTime = presentationTimestamp

        frame.endSubmission()
    }

    private func updateHandAnchors(at time: TimeInterval) {
        let (maybeLeftHand, maybeRightHand) = sessionManager.queryHandAnchors(at: time)
        if let hand = maybeLeftHand {
            scene.enqueueEvent(.handAnchor(HandAnchor(hand), .updated))
        }
        if let hand = maybeRightHand {
            scene.enqueueEvent(.handAnchor(HandAnchor(hand), .updated))
        }
    }

    func renderFrame(frame: LayerRenderer.Frame, drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor) {
        let viewCount = drawable.views.count
        let deviceTransform = deviceAnchor.originFromAnchorTransform
        let cameraTransforms = drawable.views.map { view in deviceTransform * view.transform }
        let viewMatrices = cameraTransforms.map(\.inverse)
        let projectionMatrices = (0..<viewCount).map { viewIndex in drawable.computeProjection(viewIndex: viewIndex) }
        let viewports = drawable.views.map { view in view.textureMap.viewport }
        let cameraPositions = cameraTransforms.map { cameraMatrix in cameraMatrix.columns.3.xyz }
        let views = FrameViews(viewTransforms: viewMatrices,
                               projectionTransforms: projectionMatrices,
                               viewports: viewports,
                               cameraPositions: cameraPositions)

        renderer.drawFrame(scene: scene, views: views, resources: drawable)
    }
}

#endif
