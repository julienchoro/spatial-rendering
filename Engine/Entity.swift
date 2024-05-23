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

// An entity is a named object that participates in a transform hierarchy
// and can have an associated mesh and/or physics body.
public class Entity {
    var name: String = ""
    var modelTransform: Transform
    public private(set) var parent: Entity?
    public private(set) var children: [Entity] = []
    var mesh: Mesh?
    var isHidden = false

    var worldTransform: Transform {
        get {
            if let parent {
                return parent.worldTransform * modelTransform
            } else {
                return modelTransform
            }
        }
        set {
            if let parent {
                let ancestorTransform = parent.worldTransform
                let newTransform = ancestorTransform.inverse * newValue
                modelTransform = newTransform
            } else {
                modelTransform = newValue
            }
        }
    }

    var skinner: Skinner?

    var physicsBody: PhysicsBody?

    init(mesh: Mesh? = nil, transform: Transform = Transform()) {
        self.mesh = mesh
        self.modelTransform = transform
    }

    func addChild(_ child: Entity) {
        child.removeFromParent()
        child.parent = self
        children.append(child)
        parent?.didAddChild(child)
    }

    func removeFromParent() {
        parent?.removeChild(self)
        parent = nil
    }

    private func removeChild(_ child: Entity) {
        children.removeAll {
            $0 == child
        }
        parent?.didRemoveChild(child)
    }

    // Creates a recursive "clone" of this entity and its children.
    // n.b. that this method "slices" subclasses of Entity, so only
    // use it to clone hierarchies of instances of this base class.
    // Also note that physics bodies and shapes are not cloned.
    func clone(recursively: Bool) -> Entity {
        let entity = Entity(mesh: mesh, transform: modelTransform)
        entity.isHidden = isHidden
        entity.skinner = skinner
        for child in children {
            entity.addChild(child.clone(recursively: recursively))
        }
        return entity
    }

    func update(_ timestep: TimeInterval) {}

    func didAddChild(_ entity: Entity) {
        parent?.didAddChild(entity)
    }

    func didRemoveChild(_ entity: Entity) {
        parent?.didRemoveChild(entity)
    }

    func generateCollisionShapes(recursive: Bool, bodyMode: PhysicsBodyMode) {
        if let mesh {
            let shape = PhysicsShape(convexHullFromMesh: mesh)
            let body = PhysicsBody(mode: bodyMode, shape: shape)
            physicsBody = body
        }
        if recursive {
            for child in children {
                child.generateCollisionShapes(recursive: recursive, bodyMode: bodyMode)
            }
        }
    }
}

extension Entity : Equatable {
    public static func == (lhs: Entity, rhs: Entity) -> Bool {
        return lhs === rhs
    }
}

extension Entity : Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

extension Entity {
    func visitBreadthFirst(_ root: Entity, _ body: (Entity) -> Void) {
        var queue = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            body(current)
            for child in current.children {
                queue.append(child)
            }
        }
    }

    func flattenedHierarchy(_ root: Entity) -> [Entity] {
        var entities: [Entity] = []
        visitBreadthFirst(root) { entities.append($0) }
        return entities
    }

    func child(named name: String, recursive: Bool = true) -> Entity? {
        if let immediateMatch = children.first(where: { $0.name == name }) {
            return immediateMatch
        } else if recursive {
            for child in children {
                if let match = child.child(named: name, recursive: recursive) {
                    return match
                }
            }
        }
        return nil
    }

    func childEntities(matching predicate: (Entity) -> Bool) -> [Entity] {
        var matches: [Entity] = []
        visitBreadthFirst(self) { if predicate($0) && $0 !== self { matches.append($0) } }
        return matches
    }
}

class AnchorEntity : Entity {
    override init(mesh: Mesh? = nil, transform: Transform = Transform()) {
        super.init(mesh: mesh, transform: transform)
    }

    func updatePose(from anchor: WorldAnchor) {
        worldTransform = Transform(anchor.originFromAnchorTransform)
    }
}

class HandEntity: Entity {
    let handedness: Handedness
    private let meshEntityName = "Mesh"
    private let jointConformationTransform: simd_float4x4
    private let colliderEntity = Entity()

    init(handedness: Handedness, mesh: Mesh? = nil, transform: Transform = Transform(), context: MetalContext) {
        self.handedness = handedness
        if handedness == .right {
            self.jointConformationTransform = simd_float4x4(rotationAbout: simd_float3(0, 1, 0), by: .pi / 2)
        } else {
            self.jointConformationTransform = simd_float4x4(rotationAbout: simd_normalize(simd_float3(1, 0, -1)), by: .pi)
        }
        super.init(mesh: mesh, transform: transform)

        let colliderRadius: Float = 0.0075
        let colliderColor = simd_float4(handedness == .right ? 0.8 : 0, handedness == .left ? 0.8 : 0, 0, 1)
        let colliderMesh = Mesh.generateSphere(radius: colliderRadius, context: context)
        colliderMesh.materials = [PhysicallyBasedMaterial(baseColor: colliderColor, roughness: 0.5, isMetal: false)]
        colliderEntity.mesh = colliderMesh
        let colliderBody = PhysicsBody(mode: .kinematic,
                                       shape: PhysicsShape(sphereWithRadius: colliderRadius), mass: 0.5)
        colliderEntity.physicsBody = colliderBody
        addChild(colliderEntity)
    }

    func updatePose(from anchor: HandAnchor) {
        guard let meshEntity = child(named: meshEntityName, recursive: true) else { return }
        guard let handSkeleton = anchor.handSkeleton else { return }
        guard let handSkinner = meshEntity.skinner else { return }
        var jointPoses = handSkinner.skeleton.restTransforms
        for (destinationIndex, jointPath) in handSkinner.skeleton.jointPaths.enumerated() {
            if let jointName = HandSkeleton.JointName(webXRJointName: jointPath),
               let sourceJoint = handSkeleton.joint(named: jointName)
            {
                jointPoses[destinationIndex] = sourceJoint.anchorFromJointTransform * jointConformationTransform
            }
        }
        handSkinner.jointTransforms = jointPoses
        if anchor.isTracked {
            worldTransform = Transform(anchor.originFromAnchorTransform)

            if let indexTipJoint = handSkeleton.joint(named: .indexFingerTip) {
                colliderEntity.isHidden = !indexTipJoint.isTracked
                if indexTipJoint.isTracked {
                    colliderEntity.modelTransform = Transform(indexTipJoint.anchorFromJointTransform)
                }
            }
        } else {
            isHidden = true
        }
    }
}
