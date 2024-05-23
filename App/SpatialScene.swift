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

import Foundation
import SwiftUI
import Metal
import MetalKit
import ModelIO

class SpatialScene : Entity, SceneContent {
    enum ScenePhase {
        case selectingPlacement
        case playing
    }
    var scenePhase = ScenePhase.selectingPlacement

    let sessionManager: ARSessionManager
    let context: MetalContext
    let rootEntity: Entity
    var anchoredContentRoot: AnchorEntity?

    var entities: [Entity] {
        return [Entity](flatEntities)
    }
    var lights: [Light] = []

    var environmentLight: EnvironmentLight?

    private let physicsBridge: PhysicsBridge
    private let eventQueue = LockingQueue<Event>()
    private var flatEntities = Set<Entity>()
    private var anchorEntities: [UUID : AnchorEntity] = [:]
    private var meshEntities: [UUID : Entity] = [:]
    private var planeEntities: [UUID : Entity] = [:]
    private var handEntities: [Handedness : HandEntity] = [:]
    private var environmentMeshMaterial: Material!
    private var reticleEntity: Entity?
    private var candidatePlanes = Set<Entity>()
    private var selectedPlane: Entity?
    private var blockPrototypes = [Entity]()

    #if targetEnvironment(simulator)
    let floorLevel: Float = -0.5
    #else
    let floorLevel: Float = 0.0
    #endif

    init(sessionManager: ARSessionManager, context: MetalContext) throws {
        self.sessionManager = sessionManager
        self.context = context
        self.rootEntity = Entity()
        self.physicsBridge = JoltPhysicsBridge()

        super.init()

        self.addChild(rootEntity)
        try makeScene()
    }

    func makeScene() throws {
        environmentMeshMaterial = OcclusionMaterial()
        environmentMeshMaterial.name = "Occlusion"

        let sunLight = Light(type: .directional, color: simd_float3(1, 1, 1), intensity: 1)
        sunLight.transform.look(at: simd_float3(0, 0, 0), from: simd_float3(0.1, 1, 0.1), up: simd_float3(0, 1, 0))
        lights.append(sunLight)

        #if targetEnvironment(simulator)
        let accentTop = Light(type: .point, color: simd_float3(1, 1, 1), intensity: 25)
        accentTop.transform.look(at: simd_float3(0, 0, 0), from: simd_float3(-3, 3, 0), up: simd_float3(0, 1, 0))
        lights.append(accentTop)

        let accentBottom = Light(type: .point, color: simd_float3(1, 1, 1), intensity: 25)
        accentBottom.transform.look(at: simd_float3(0, 0, 0), from: simd_float3(-3, -3, 0), up: simd_float3(0, 1, 0))
        lights.append(accentBottom)
        #endif

        if let handURL = Bundle.main.url(forResource: "Hand_Left", withExtension: "usdz") {
            let model = try Model(fileURL: handURL, context: context)
            if let handArmature = model.rootEntities.first {
                let handEntity = HandEntity(handedness: .left, context: context)
                handEntity.addChild(handArmature)
                rootEntity.addChild(handEntity)
                handEntities[.left] = handEntity
                handEntity.worldTransform = Transform(position: simd_float3(-0.15, floorLevel + 0.8, -0.15))
                if let handMaterial = handEntity.child(named: "Mesh")?.mesh?.materials.first as? PhysicallyBasedMaterial {
                    handMaterial.blendMode = .sourceOverPremultiplied
                    handMaterial.isDoubleSided = false
                    handMaterial.baseColor.baseColorFactor.w = 0.1
                }
            }
        }
        if let handURL = Bundle.main.url(forResource: "Hand_Right", withExtension: "usdz") {
            let model = try Model(fileURL: handURL, context: context)
            if let handArmature = model.rootEntities.first {
                let handEntity = HandEntity(handedness: .right, context: context)
                handEntity.addChild(handArmature)
                rootEntity.addChild(handEntity)
                handEntities[.right] = handEntity
                handEntity.worldTransform = Transform(position: simd_float3(0.15, floorLevel + 0.8, -0.15))
                if let handMaterial = handEntity.child(named: "Mesh")?.mesh?.materials.first as? PhysicallyBasedMaterial {
                    handMaterial.blendMode = .sourceOverPremultiplied
                    handMaterial.isDoubleSided = false
                    handMaterial.baseColor.baseColorFactor.w = 0.1
                }
            }
        }

        if let reticleURL = Bundle.main.url(forResource: "Placement_Reticle", withExtension: "usdz") {
            let model = try Model(fileURL: reticleURL, context: context)
            // USD tends to create unnecessarily deep prim hierarchies, so just reach in and grab the mesh node.
            if let meshEntity = model.rootEntities.first?.child(named: "mesh") {
                let reticleTransform = meshEntity.worldTransform
                meshEntity.removeFromParent()
                meshEntity.modelTransform = reticleTransform
                reticleEntity = meshEntity
            }
        }

        if let modelURL = Bundle.main.url(forResource: "Blocks", withExtension: "usdz") {
            let model = try Model(fileURL: modelURL, context: context)
            let blockEntities = model.rootEntities.first?.childEntities(matching: { $0.mesh != nil }) ?? []
            blockEntities.forEach { entity in
                // Since we want to apply physics to each object in the model, we move it to the scene root
                // by de-parenting it and assigning its initial world transform as its model transform.
                // This allows us to handle object scaling correctly in the rendering and physics systems.
                let placementTransform = entity.worldTransform
                entity.removeFromParent()
                entity.modelTransform = placementTransform
                entity.generateCollisionShapes(recursive: false, bodyMode: .dynamic)
            }
            self.blockPrototypes = blockEntities
        }

        // Create a large ground plane so that even if we don't have plane detection
        // or scene reconstruction enabled, virtual objects don't fall infinitely far
		let floorExtent = simd_float3(10, 0.02, 10)
		let groundPlane = Entity()
        groundPlane.name = "Ground Plane"
        groundPlane.isHidden = true
        groundPlane.modelTransform.position = simd_float3(0, floorLevel - floorExtent.y * 0.5, 0)
        let groundShape = PhysicsShape(boxWithExtents: floorExtent)
        groundPlane.physicsBody = PhysicsBody(mode: .static, shape: groundShape)
        rootEntity.addChild(groundPlane)

        #if targetEnvironment(simulator) || !os(visionOS)
        selectPlaneForPlacement(groundPlane, pose: Transform())
        #endif
    }

    func enqueueEvent(_ event: Event) {
        eventQueue.enqueue(event)
    }

    override func update(_ timestep: TimeInterval) {
        for event in eventQueue.popAll() {
            switch event {
            case .worldAnchor(let anchor, let anchorEvent):
                handleWorldAnchorEvent(anchor, event: anchorEvent)
            case .meshAnchor(let anchor, let anchorEvent):
                handleMeshAnchorEvent(anchor, event: anchorEvent)
            case .planeAnchor(let anchor, let anchorEvent):
                handlePlaneAnchorEvent(anchor, event: anchorEvent)
            case .handAnchor(let anchor, let anchorEvent):
                handleHandAnchorEvent(anchor, event: anchorEvent)
            case .spatialInput(let spatialEvents):
                handleSpatialInput(spatialEvents)
            case .environmentLightAnchor(let anchor, let anchorEvent):
                handleEnvironmentLightEvent(anchor, event: anchorEvent)
            }
        }

        for entity in entities {
            entity.update(timestep)
        }

        physicsBridge.update(entities: entities, timestep: timestep)
    }

    override func didAddChild(_ entity: Entity) {
        let flattenedSubtree = flattenedHierarchy(entity)
        for element in flattenedSubtree {
            flatEntities.insert(element)
            physicsBridge.addEntity(element)
        }
        super.didAddChild(entity)
    }

    override func didRemoveChild(_ entity: Entity) {
        let flattenedSubtree = flattenedHierarchy(entity)
        for element in flattenedSubtree {
            flatEntities.remove(element)
            physicsBridge.removeEntity(element)
        }
        super.didRemoveChild(entity)
    }

    private func updatePhysicsShapeForStaticEntity(_ entity: Entity) {
        physicsBridge.removeEntity(entity)
        if let mesh = entity.mesh {
            let shape = PhysicsShape(concaveMeshFromMesh: mesh)
            entity.physicsBody = PhysicsBody(mode: .static, shape: shape)
        } else {
            entity.physicsBody = nil
        }
        physicsBridge.addEntity(entity)
    }

    func handlePlaneAnchorEvent(_ anchor: PlaneAnchor, event: AnchorEvent) {
        let desiredPlacements: [PlaneAnchor.Classification] = [.table]
        switch event {
        case .added:
            let planeEntity = Entity()
            planeEntity.name = "Plane \(anchor.id)"
            planeEntity.worldTransform = Transform(anchor.originFromAnchorTransform)
            planeEntity.mesh = anchor.mesh
            planeEntity.mesh?.materials = [environmentMeshMaterial]
            planeEntities[anchor.id] = planeEntity
            if scenePhase == .selectingPlacement {
                if desiredPlacements.contains(anchor.classification) {
                    candidatePlanes.insert(planeEntity)
                    if let planeReticle = reticleEntity?.clone(recursively: false) {
                        let reticlePivot = Entity(transform: Transform(position: simd_float3(0, 0.005, 0)))
                        reticlePivot.addChild(planeReticle)
                        planeEntity.addChild(reticlePivot)
                    }
                }
            }
            rootEntity.addChild(planeEntity)
        case .updated:
            if let planeEntity = planeEntities[anchor.id] {
                planeEntity.worldTransform = Transform(anchor.originFromAnchorTransform)
                planeEntity.mesh = anchor.mesh
                planeEntity.mesh?.materials = [environmentMeshMaterial]
                updatePhysicsShapeForStaticEntity(planeEntity)
            }
        case .removed:
            if let planeEntity = planeEntities[anchor.id] {
                planeEntities.removeValue(forKey: anchor.id)
                candidatePlanes.remove(planeEntity)
                planeEntity.removeFromParent()
            }
        }
    }

    func handleMeshAnchorEvent(_ anchor: MeshAnchor, event: AnchorEvent) {
        switch event {
        case .added:
            let meshEntity = Entity()
            meshEntity.name = "World Mesh \(anchor.id)"
            meshEntity.worldTransform = Transform(anchor.originFromAnchorTransform)
            meshEntity.mesh = anchor.mesh
            meshEntity.mesh?.materials = [environmentMeshMaterial]
            meshEntities[anchor.id] = meshEntity
            rootEntity.addChild(meshEntity)
        case .updated:
            if let meshEntity = meshEntities[anchor.id] {
                meshEntity.worldTransform = Transform(anchor.originFromAnchorTransform)
                meshEntity.mesh = anchor.mesh
                meshEntity.mesh?.materials = [environmentMeshMaterial]
                updatePhysicsShapeForStaticEntity(meshEntity)
            }
        case .removed:
            if let meshEntity = meshEntities[anchor.id] {
                meshEntities.removeValue(forKey: anchor.id)
                meshEntity.removeFromParent()
            }
        }
    }

    func handleHandAnchorEvent(_ anchor: HandAnchor, event: AnchorEvent) {
        switch event {
        case .added:
            if let handEntity = handEntities[anchor.handedness] {
                handEntity.isHidden = false
                handEntity.updatePose(from: anchor)
            }
        case .updated:
            if let handEntity = handEntities[anchor.handedness] {
                handEntity.updatePose(from: anchor)
            }
        case .removed:
            if let handEntity = handEntities[anchor.handedness] {
                handEntity.isHidden = true
            }
        }
    }

    func handleWorldAnchorEvent(_ anchor: WorldAnchor, event: AnchorEvent) {
        switch event {
        case .added:
            if let anchorEntity = anchorEntities[anchor.id] {
                anchorEntity.updatePose(from: anchor)
            } else {
                let anchorEntity = AnchorEntity(transform: Transform(anchor.originFromAnchorTransform))
                anchorEntity.name = "Anchor \(anchor.id)"
                anchorEntities[anchor.id] = anchorEntity
            }
        case .updated:
            if let anchorEntity = anchorEntities[anchor.id] {
                anchorEntity.updatePose(from: anchor)
            }
        case .removed:
            anchorEntities.removeValue(forKey: anchor.id)
        }
    }

    private func handleEnvironmentLightEvent(_ anchor: EnvironmentLightAnchor, event: AnchorEvent) {
        switch event {
        case .added:
            fallthrough
        case .updated:
            // Only bother updating environmental lighting once we have an environment cube map
            if anchor.light.environmentTexture != nil {
                self.environmentLight = anchor.light
            }
        case .removed:
            // Although it might be more correct to remove environment lights when their
            // corresponding anchors go away, we prefer to use environment lighting even
            // if it's stale, so we retain the most recent update regardless. Handling this
            // comprehensively means tracking all environment probe anchors, since ARKit
            // may create multiple probes as the device moves around the environment.
            break
        }
    }

	private func handleSpatialInput(_ event: SpatialInputEvent) {
		switch event.phase {
		case .active:
			break
		case .ended:
			if let ray = event.selectionRay {
				let origin = simd_float3(ray.origin)
				let toward = simd_float3(ray.direction)
				let hitResults = physicsBridge.hitTestWithSegment(from: origin, to: origin + toward * 3.0)
                for hit in hitResults.sorted(by: { simd_length($0.worldPosition - origin) < simd_length($1.worldPosition - origin)}) {
                    if scenePhase == .selectingPlacement {
                        if let hitEntity = hit.entity, candidatePlanes.contains(hitEntity) {
                            selectPlaneForPlacement(hitEntity, pose: Transform(position: hit.worldPosition))
                        }
                    }
				}
			}
		case .cancelled:
			break
		@unknown default:
			break
		}
    }

    private func selectPlaneForPlacement(_ planeEntity: Entity, pose: Transform) {
        selectedPlane = planeEntity
        scenePhase = .playing
        print("Transitioned to playing state with selected plane \(selectedPlane?.name ?? "<none>")")
        Task {
            await buildTower(pose)
        }
    }

    private func buildTower(_ pose: Transform) async {
        guard blockPrototypes.count > 0 else {
            print("Failed to load block models; cannot construct tower")
            return
        }

        do {
            try await sessionManager.removeAllWorldAnchors()
            let worldAnchor = try await sessionManager.addWorldAnchor(originFromAnchorTransform: pose.matrix)
            let towerAnchor = AnchorEntity()
            towerAnchor.name = "Tower Anchor"
            towerAnchor.updatePose(from: worldAnchor)
            anchorEntities[worldAnchor.id] = towerAnchor
            rootEntity.addChild(towerAnchor)
            self.anchoredContentRoot = towerAnchor
        } catch {
            print("Could not create world anchor to place tower; creating default placement")
            let towerAnchor = AnchorEntity(transform: Transform(position: simd_float3(0, 0, -0.5)))
            rootEntity.addChild(towerAnchor)
            self.anchoredContentRoot = towerAnchor
        }

        let layerCount = 7
        let lateralMargin: Float = 0.0025
        let verticalMargin: Float = 0.005

        // Calculate the block bounds, assuming all prototypes have the same size
        let defaultBlockBounds = blockPrototypes[0].mesh!.boundingBox
        let blockWidth = defaultBlockBounds.max.x - defaultBlockBounds.min.x
        let blockHeight = defaultBlockBounds.max.y - defaultBlockBounds.min.y
        let blockDepth = defaultBlockBounds.max.z - defaultBlockBounds.min.z

        let rotation = Transform(orientation: simd_quatf(angle: .pi / 2, axis: simd_float3(0, 1, 0)))
        var layerIsRotated = false
        var yPosition = blockHeight * 0.5
        var blockNumber = 0
        for _ in 0..<layerCount {
            let blockPositions = [
                simd_float3(0, yPosition, 0),
                simd_float3(0, yPosition, -blockDepth - lateralMargin),
                simd_float3(0, yPosition, blockDepth + lateralMargin)
            ]
            for i in 0..<3 {
                let protoIndex = Int.random(in: 0..<blockPrototypes.count)
                let block = blockPrototypes[protoIndex].clone(recursively: false)
                block.name = "Block \(blockNumber)"
                block.modelTransform = Transform(position: blockPositions[i])
                let shape = PhysicsShape(boxWithExtents: simd_float3(blockWidth, blockHeight, blockDepth))
                block.physicsBody = PhysicsBody(mode: .dynamic, shape: shape)
                if layerIsRotated {
                    block.modelTransform = rotation * block.modelTransform
                }
                anchoredContentRoot?.addChild(block)
                blockNumber += 1
            }
            yPosition += blockHeight + verticalMargin
            layerIsRotated.toggle()
        }
    }
}
