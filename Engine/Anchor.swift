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
import simd

public enum AnchorEvent {
    case added
    case updated
    case removed
}

public protocol Anchor : Identifiable, Sendable {
    var originFromAnchorTransform: simd_float4x4 { get }
}

public struct WorldAnchor : Anchor {
    public typealias ID = UUID

    public let id: UUID
    public let originFromAnchorTransform: simd_float4x4

    init (id: UUID, originFromAnchorTransform: simd_float4x4) {
        self.id = id
        self.originFromAnchorTransform = originFromAnchorTransform
    }
}

public struct PlaneAnchor : Anchor, @unchecked Sendable {
    public typealias ID = UUID

    public struct Extent {
        let width: Float
        let height: Float
        let anchorFromExtentTransform: simd_float4x4

        init(width: Float, height: Float, anchorFromExtentTransform: simd_float4x4) {
            self.width = width
            self.height = height
            self.anchorFromExtentTransform = anchorFromExtentTransform
        }
    }

    public enum Alignment {
        case horizontal
        case vertical
        case slanted
    }

    public enum Classification : Int {
        case unknown
        case wall
        case floor
        case ceiling
        case table
        case seat
        case window
        case door
    }

    public let id: UUID
    public let originFromAnchorTransform: simd_float4x4
    public let alignment: PlaneAnchor.Alignment
    public let classification: PlaneAnchor.Classification
    public let extent: PlaneAnchor.Extent
    public let mesh: Mesh

    init(id: UUID,
         originFromAnchorTransform: simd_float4x4,
         alignment: PlaneAnchor.Alignment,
         classification: PlaneAnchor.Classification,
         extent: PlaneAnchor.Extent,
         mesh: Mesh)
    {
        self.id = id
        self.originFromAnchorTransform = originFromAnchorTransform
        self.alignment = alignment
        self.classification = classification
        self.extent = extent
        self.mesh = mesh
    }
}

public struct MeshAnchor : Anchor, @unchecked Sendable {
    public typealias ID = UUID

    public let id: UUID
    public let originFromAnchorTransform: simd_float4x4
    public let mesh: Mesh

    init(id: UUID, originFromAnchorTransform: simd_float4x4, mesh: Mesh) {
        self.id = id
        self.originFromAnchorTransform = originFromAnchorTransform
        self.mesh = mesh
    }
}

public struct HandSkeleton : Sendable {
    public enum JointName : String, CaseIterable, Sendable {
        case wrist
        case thumbKnuckle
        case thumbIntermediateBase
        case thumbIntermediateTip
        case thumbTip
        case indexFingerMetacarpal
        case indexFingerKnuckle
        case indexFingerIntermediateBase
        case indexFingerIntermediateTip
        case indexFingerTip
        case middleFingerMetacarpal
        case middleFingerKnuckle
        case middleFingerIntermediateBase
        case middleFingerIntermediateTip
        case middleFingerTip
        case ringFingerMetacarpal
        case ringFingerKnuckle
        case ringFingerIntermediateBase
        case ringFingerIntermediateTip
        case ringFingerTip
        case littleFingerMetacarpal
        case littleFingerKnuckle
        case littleFingerIntermediateBase
        case littleFingerIntermediateTip
        case littleFingerTip
        case forearmWrist
        case forearmArm
    }

    public struct Joint : Sendable {
        let name: HandSkeleton.JointName
        let anchorFromJointTransform: simd_float4x4
        let estimatedLinearVelocity: simd_float3
        let isTracked: Bool
    }

    let joints: [HandSkeleton.Joint]

    init(joints: [HandSkeleton.Joint]) {
        self.joints = joints
    }

    func joint(named name: JointName) -> Joint? {
        joints.first(where: { $0.name == name })
    }
}

extension HandSkeleton.JointName {
    init?(webXRJointName: String) {
        switch webXRJointName {
            case "wrist" : self = .wrist
            case "thumb_metacarpal" : self = .thumbKnuckle
            case "thumb_phalanx_proximal" : self = .thumbIntermediateBase
            case "thumb_phalanx_distal" : self = .thumbIntermediateTip
            case "thumb_tip" : self = .thumbTip
            case "index_finger_metacarpal" : self = .indexFingerMetacarpal
            case "index_finger_phalanx_proximal" : self = .indexFingerKnuckle
            case "index_finger_phalanx_intermediate" : self = .indexFingerIntermediateBase
            case "index_finger_phalanx_distal" : self = .indexFingerIntermediateTip
            case "index_finger_tip" : self = .indexFingerTip
            case "middle_finger_metacarpal" : self = .middleFingerMetacarpal
            case "middle_finger_phalanx_proximal" : self = .middleFingerKnuckle
            case "middle_finger_phalanx_intermediate" : self = .middleFingerIntermediateBase
            case "middle_finger_phalanx_distal" : self = .middleFingerIntermediateTip
            case "middle_finger_tip" : self = .middleFingerTip
            case "ring_finger_metacarpal" : self = .ringFingerMetacarpal
            case "ring_finger_phalanx_proximal" : self = .ringFingerKnuckle
            case "ring_finger_phalanx_intermediate" : self = .ringFingerIntermediateBase
            case "ring_finger_phalanx_distal" : self = .ringFingerIntermediateTip
            case "ring_finger_tip" : self = .ringFingerTip
            case "pinky_finger_metacarpal" : self = .littleFingerMetacarpal
            case "pinky_finger_phalanx_proximal" : self = .littleFingerKnuckle
            case "pinky_finger_phalanx_intermediate" : self = .littleFingerIntermediateBase
            case "pinky_finger_phalanx_distal" : self = .littleFingerIntermediateTip
            case "pinky_finger_tip" : self = .littleFingerTip
        default:
            return nil
        }
    }

    var webXRJointName: String? {
        switch self {
            case .wrist: return "wrist"
            case .thumbKnuckle: return "thumb_metacarpal"
            case .thumbIntermediateBase: return "thumb_phalanx_proximal"
            case .thumbIntermediateTip: return "thumb_phalanx_distal"
            case .thumbTip: return "thumb_tip"
            case .indexFingerMetacarpal: return "index_finger_metacarpal"
            case .indexFingerKnuckle: return "index_finger_phalanx_proximal"
            case .indexFingerIntermediateBase: return "index_finger_phalanx_intermediate"
            case .indexFingerIntermediateTip: return "index_finger_phalanx_distal"
            case .indexFingerTip: return "index_finger_tip"
            case .middleFingerMetacarpal: return "middle_finger_metacarpal"
            case .middleFingerKnuckle: return "middle_finger_phalanx_proximal"
            case .middleFingerIntermediateBase: return "middle_finger_phalanx_intermediate"
            case .middleFingerIntermediateTip: return "middle_finger_phalanx_distal"
            case .middleFingerTip: return "middle_finger_tip"
            case .ringFingerMetacarpal: return "ring_finger_metacarpal"
            case .ringFingerKnuckle: return "ring_finger_phalanx_proximal"
            case .ringFingerIntermediateBase: return "ring_finger_phalanx_intermediate"
            case .ringFingerIntermediateTip: return "ring_finger_phalanx_distal"
            case .ringFingerTip: return "ring_finger_tip"
            case .littleFingerMetacarpal: return "pinky_finger_metacarpal"
            case .littleFingerKnuckle: return "pinky_finger_phalanx_proximal"
            case .littleFingerIntermediateBase: return "pinky_finger_phalanx_intermediate"
            case .littleFingerIntermediateTip: return "pinky_finger_phalanx_distal"
            case .littleFingerTip: return "pinky_finger_tip"
            default: return nil
        }
    }
}

public enum Handedness : Sendable {
    case left
    case right
    case none
}

public struct HandAnchor : Anchor {
    public typealias ID = UUID

    public let id: UUID
    public let originFromAnchorTransform: simd_float4x4
    public let estimatedLinearVelocity: simd_float3
    public let handSkeleton: HandSkeleton?
    public let handedness: Handedness
    public let isTracked: Bool

    init(id: UUID,
         originFromAnchorTransform: simd_float4x4,
         estimatedLinearVelocity: simd_float3,
         handSkeleton: HandSkeleton?,
         handedness: Handedness,
         isTracked: Bool)
    {
        self.id = id
        self.originFromAnchorTransform = originFromAnchorTransform
        self.estimatedLinearVelocity = estimatedLinearVelocity
        self.handSkeleton = handSkeleton
        self.handedness = handedness
        self.isTracked = isTracked
    }
}

public struct EnvironmentLightAnchor : Anchor {
    public typealias ID = UUID

    public let id: UUID

    public let originFromAnchorTransform: simd_float4x4
    public let light: EnvironmentLight

    init(id: UUID, originFromAnchorTransform: simd_float4x4, light: EnvironmentLight) {
        self.id = id
        self.originFromAnchorTransform = originFromAnchorTransform
        self.light = light
    }
}
