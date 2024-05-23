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
import CoreGraphics
import simd

protocol Camera {
    var transform: Transform { get }
    var viewMatrix: simd_float4x4 { get }
    func projectionMatrix(for viewportSize: CGSize) -> simd_float4x4
}

class OrthographicCamera : Camera {
    var near: Float = 0.0
    var far: Float = 1.0

    var transform = Transform()

    var viewMatrix: simd_float4x4 {
        return transform.matrix.inverse
    }

    func projectionMatrix(for viewportSize: CGSize) -> simd_float4x4 {
        let width = Float(viewportSize.width), height = Float(viewportSize.height)
        return simd_float4x4(orthographicProjectionLeft: 0.0, top: 0.0,
                             right: width, bottom: height,
                             near: near, far: far)
    }
}

// A camera that produces a perspective projection based on a field-of-view and near clipping plane distance
// The projection matrix produced by this camera assumes an infinitely distant far viewing distance and reverse-Z
// (i.e. clip space depth runs from 1 to 0, near to far)
class PerspectiveCamera : Camera {
    // The total vertical field of view angle of the camera
    var fieldOfView: Angle = .degrees(60)

    // The distance to the camera's near viewing plane
    var near: Float = 0.005

    var transform = Transform()

    var viewMatrix: simd_float4x4 {
        return transform.matrix.inverse
    }

    func projectionMatrix(for viewportSize: CGSize) -> simd_float4x4 {
        let width = Float(viewportSize.width), height = Float(viewportSize.height)
        let aspectRatio = width / height
        return simd_float4x4(perspectiveProjectionFOV: Float(fieldOfView.radians), 
                             aspectRatio: aspectRatio,
                             near: near)
    }
}
