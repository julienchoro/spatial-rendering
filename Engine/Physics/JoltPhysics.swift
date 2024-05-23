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
import ModelIO

extension Mesh {
    func getPackedVertexPositions() -> [simd_float3] {
        let attribute = vertexDescriptor.attributeNamed(MDLVertexAttributePosition)!
        let layout = vertexDescriptor.bufferLayouts[attribute.bufferIndex]
        precondition(attribute.format == .float3)

        let vertexBuffer = vertexBuffers[attribute.bufferIndex]
        let stride = layout.stride
        let bufferBaseAddr = vertexBuffer.buffer.contents().advanced(by: vertexBuffer.offset)
        let attributeBaseAddr = bufferBaseAddr.advanced(by: attribute.offset)
        let positions = [simd_float3].init(unsafeUninitializedCapacity: vertexCount) { vertexPtr, initializedCount in
            for i in 0..<vertexCount {
                let componentPtr = attributeBaseAddr.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
                vertexPtr[i] = simd_float3(componentPtr[0], componentPtr[1], componentPtr[2])
            }
            initializedCount = vertexCount
        }
        return positions
    }

    func getPackedSubmeshIndices() -> [UInt32] {
        let indexCount = submeshes.reduce(0) { return $0 + $1.indexCount  }
        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        for submesh in self.submeshes {
            guard let indexBuffer = submesh.indexBuffer else { continue }
            if submesh.indexType == .uint16 {
                let indexBaseAddr = indexBuffer.buffer.contents().advanced(by: indexBuffer.offset).assumingMemoryBound(to: UInt16.self)
                for i in 0..<submesh.indexCount {
                    indices.append(UInt32(indexBaseAddr[i]))
                }
            } else if submesh.indexType == .uint32 {
                let indexBaseAddr = indexBuffer.buffer.contents().advanced(by: indexBuffer.offset).assumingMemoryBound(to: UInt32.self)
                for i in 0..<submesh.indexCount {
                    indices.append(indexBaseAddr[i])
                }
            }
        }
        return indices
    }
}

extension SRJPhysicsShape {
    class func makeConvexHullShape(points: [simd_float3], scale:simd_float3) throws -> SRJPhysicsShape {
        return try points.withUnsafeBufferPointer { ptr in
            return try makeConvexHullShape(vertices: ptr.baseAddress!, vertexCount: points.count, scale: scale)
        }
    }

    class func makeConcavePolyhedronShape(points: [simd_float3], indices: [UInt32], scale:simd_float3) -> SRJPhysicsShape {
        return points.withUnsafeBufferPointer { pointPtr in
            indices.withUnsafeBufferPointer { indexPtr in
                return makeConcavePolyhedronShape(vertices: pointPtr.baseAddress!,
                                                  vertexCount: points.count,
                                                  indices: indexPtr.baseAddress!,
                                                  indexCount: indices.count,
                                                  scale: scale)

            }
        }
    }
}

extension PhysicsShape {
    func makeJoltPhysicsShape(scale: simd_float3) throws -> SRJPhysicsShape {
        switch type {
        case .sphere(let radius):
            return SRJPhysicsShape.makeSphereShape(radius: radius, scale: scale)
        case .box(let extents):
            return SRJPhysicsShape.makeBoxShape(extents: extents, scale: scale)
        case .convexHull(let mesh):
            let points = mesh.getPackedVertexPositions()
            return try SRJPhysicsShape.makeConvexHullShape(points: points, scale: scale)
        case .concaveMesh(let mesh):
            let points = mesh.getPackedVertexPositions()
            let indices = mesh.getPackedSubmeshIndices()
            return SRJPhysicsShape.makeConcavePolyhedronShape(points: points, indices: indices, scale: scale)
        }
    }
}

class JoltPhysicsBridge : PhysicsBridge {
    let physicsWorld: SRJPhysicsWorld
    var registeredEntities: Set<Entity> = []
    var bodiesForEntities: [ObjectIdentifier: SRJPhysicsBody] = [:]
    var entitiesForBodies: [ObjectIdentifier: Entity] = [:]

    init() {
        physicsWorld = SRJPhysicsWorld()
    }

    func addEntity(_ entity: Entity) {
        if registeredEntities.contains(entity) {
            print("Tried to add entity \(entity.name) to physics bridge when it was already registered!")
            return
        }
        registeredEntities.insert(entity)
        if let physicsBody = entity.physicsBody {
            do {
                let bodyType: SRJBodyType = switch physicsBody.mode {
                case .static: .`static`
                case .dynamic: .dynamic
                case .kinematic: .kinematic
                }
                let worldTransform = entity.worldTransform
                let bodyTransform = SRJRigidBodyTransform(position: worldTransform.position,
                                                          orientation: worldTransform.orientation)
                let properties = SRJBodyProperties(mass: physicsBody.mass,
                                                   friction: physicsBody.friction,
                                                   restitution: physicsBody.restitution,
                                                   isAffectedByGravity: physicsBody.isAffectedByGravity)
                let backendShape = try physicsBody.shape.makeJoltPhysicsShape(scale: worldTransform.scale)
                let backendBody = physicsWorld.addPhysicsBody(type: bodyType,
                                                              bodyProperties: properties,
                                                              physicsShape: backendShape,
                                                              initialTransform: bodyTransform)
                bodiesForEntities[ObjectIdentifier(entity)] = backendBody
                entitiesForBodies[ObjectIdentifier(backendBody)] = entity
            } catch {
                print("Failed to register entity \(entity.name) to physics bridge with error: \(error.localizedDescription)")
            }
        } else {
            // TODO: Handle entities with no physics body but with a mesh that should be included in hit-testing?
        }
    }

    func removeEntity(_ entity: Entity) {
        if let body = bodiesForEntities[ObjectIdentifier(entity)] {
            physicsWorld.remove(body)
            entitiesForBodies.removeValue(forKey: ObjectIdentifier(body))
            bodiesForEntities.removeValue(forKey: ObjectIdentifier(entity))
        }
        registeredEntities.remove(entity)
    }

    func update(entities: [Entity], timestep: TimeInterval) {
        for physicsEntity in entities.filter({ $0.physicsBody != nil }) {
            if let body = bodiesForEntities[ObjectIdentifier(physicsEntity)] {
                let entityTransform = physicsEntity.worldTransform
                let bodyTransform = SRJRigidBodyTransform(position: entityTransform.position,
                                                          orientation: entityTransform.orientation)
                body.transform = bodyTransform
            } else {
                print("Tried to update entity \(physicsEntity.name) before it was added to the physics bridge.")
            }
        }

        physicsWorld.update(timestep: timestep)

        for dynamicEntity in entities.filter({ $0.physicsBody?.mode == .dynamic }) {
            if let dynamicBody = bodiesForEntities[ObjectIdentifier(dynamicEntity)] {
                let bodyTransform = dynamicBody.transform
                dynamicEntity.worldTransform = Transform(position: bodyTransform.position,
                                                         scale: dynamicEntity.modelTransform.scale,
                                                         orientation: bodyTransform.orientation)
            } else {
                print("Tried to update dynamic entity \(dynamicEntity.name) before it was added to the physics bridge.")
            }
        }
    }

    func hitTestWithSegment(from: simd_float3, to: simd_float3) -> [HitTestResult] {
        let results = physicsWorld.hitTestWithSegment(from: from, to: to)
        return results.map { result in
            if let backendBody = result.body {
                let entity = entitiesForBodies[ObjectIdentifier(backendBody)]
                return HitTestResult(entity: entity, worldPosition: result.position)
            }
            return HitTestResult(entity: nil, worldPosition: result.position)
        }
    }
}
