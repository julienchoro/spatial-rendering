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
import simd

extension WorldAnchor {
    init(_ worldAnchor: ARKit.WorldAnchor) {
        self.init(id: worldAnchor.id,
                  originFromAnchorTransform: worldAnchor.originFromAnchorTransform)
    }
}

extension PlaneAnchor {
    init(_ planeAnchor: ARKit.PlaneAnchor) {
        let alignment: PlaneAnchor.Alignment = switch planeAnchor.alignment {
            case .horizontal : .horizontal
            case .vertical : .vertical
            default: .slanted
        }
        let classification: PlaneAnchor.Classification = switch planeAnchor.classification {
            case .wall : .wall
            case .floor : .floor
            case .ceiling : .ceiling
            case .table : .table
            case .seat : .seat
            case .window : .window
            case .door : .door
            default: .unknown
        }
        let originalExtent = planeAnchor.geometry.extent
        let extent = PlaneAnchor.Extent(width: originalExtent.width,
                                         height: originalExtent.height,
                                         anchorFromExtentTransform: originalExtent.anchorFromExtentTransform)
        self.init(id: planeAnchor.id,
                  originFromAnchorTransform: planeAnchor.originFromAnchorTransform,
                  alignment: alignment,
                  classification: classification,
                  extent: extent,
                  mesh: Mesh(planeAnchor))
    }
}

extension MeshAnchor {
    init(_ meshAnchor: ARKit.MeshAnchor) {
        self.init(id: meshAnchor.id, originFromAnchorTransform: meshAnchor.originFromAnchorTransform, mesh: Mesh(meshAnchor))
    }
}

extension HandSkeleton {
    init(_ skeleton: ARKit.HandSkeleton) {
        let joints = skeleton.allJoints.map { joint in
            // Sometimes ARKit unhelpfully gives us joint transforms that are purportedly tracked, but also all zeroes
            let det = joint.anchorFromJointTransform.determinant
            return HandSkeleton.Joint(name: HandSkeleton.JointName(rawValue: joint.name.description)!,
                                      anchorFromJointTransform: joint.anchorFromJointTransform,
                                      estimatedLinearVelocity: simd_float3(),
                                      isTracked: joint.isTracked && (det != 0))
        }
        self.init(joints: joints)
    }
}

extension HandAnchor {
    init(_ handAnchor: ARKit.HandAnchor) {
        let handedness: Handedness = switch handAnchor.chirality {
            case .left: .left
            case .right: .right
        }
        let skeleton = handAnchor.handSkeleton.map { HandSkeleton($0) } ?? nil
        self.init(id: handAnchor.id,
                  originFromAnchorTransform: handAnchor.originFromAnchorTransform,
                  estimatedLinearVelocity: simd_float3(),
                  handSkeleton: skeleton,
                  handedness: handedness,
                  isTracked: handAnchor.isTracked)
    }
}

extension EnvironmentLightAnchor {
    init(_ environmentProbeAnchor: ARKit.EnvironmentProbeAnchor) {
        let light = EnvironmentLight(cubeFromWorldTransform: Transform(environmentProbeAnchor.originFromAnchorTransform.inverse),
                                     environmentTexture: environmentProbeAnchor.environmentTexture,
                                     scaleFactor: environmentProbeAnchor.cameraScaleReference)
        self.init(id: environmentProbeAnchor.id,
                  originFromAnchorTransform: environmentProbeAnchor.originFromAnchorTransform,
                  light: light)
    }
}

#endif
