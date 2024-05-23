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

enum PhysicsShapeType {
    case box(_ extents: simd_float3)
    case sphere(_ radius: Float)
    case convexHull(_ mesh: Mesh)
    case concaveMesh(_ mesh: Mesh)
}

enum PhysicsBodyMode {
    case `static`
    case dynamic
    case kinematic
}

struct CollisionGroup : OptionSet {
    let rawValue: UInt32

    static let `default`: CollisionGroup = CollisionGroup(rawValue: 1 << 0)
    static let sceneUnderstanding: CollisionGroup = CollisionGroup(rawValue: 1 << 1)
    static let all: CollisionGroup = CollisionGroup(rawValue: UInt32.max)
}

struct CollisionFilter : Equatable {
    static let `default`: CollisionFilter = .init(group: .default, mask: .all)

    var group: CollisionGroup
    var mask: CollisionGroup

    init(group: CollisionGroup, mask: CollisionGroup) {
        self.group = group
        self.mask = mask
    }
}

struct Contact : Sendable {
    let point: simd_float3
    //let normal: simd_float3
    let impulse: Float
    let impulseDirection: simd_float3
    let penetrationDistance: Float
}

class PhysicsShape {
    let type: PhysicsShapeType

    init(boxWithExtents extents: simd_float3) {
        self.type = .box(extents)
    }

    init(sphereWithRadius radius: Float) {
        self.type = .sphere(radius)
    }

    init(convexHullFromMesh mesh: Mesh) {
        self.type = .convexHull(mesh)
    }

    init(concaveMeshFromMesh mesh: Mesh) {
        self.type = .concaveMesh(mesh)
    }
}

struct PhysicsBody {
    let mode: PhysicsBodyMode
    let shape: PhysicsShape
    let mass: Float // For dynamic/kinematic bodies, mass=0 tells the system to calculate the mass. Ignored otherwise.
    let friction: Float
    let restitution: Float
    let filter: CollisionFilter = .default
    let isAffectedByGravity: Bool = true

    init(mode: PhysicsBodyMode,
         shape: PhysicsShape,
         mass: Float = 0.0,
         friction: Float = 0.5,
         restitution: Float = 0.0)
    {
        self.mode = mode
        self.shape = shape
        self.mass = mass
        self.friction = friction
        self.restitution = restitution
    }
}
