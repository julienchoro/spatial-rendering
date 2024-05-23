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

import simd
import Spatial

func alignUp(_ base: Int, alignment: Int) -> Int {
    precondition(alignment > 0)
    return ((base + alignment - 1) / alignment) * alignment
}

// Given a range, determine the parameter for which lerp would produce the provided value.
// Will extrapolate if given a value outside the range.
func unlerp<T: FloatingPoint>(_ from: T, _ to: T, _ value: T) -> T {
    if to == from { return T(0) }
    return (value - from) / (to - from)
}

// Swift simd doesn't have a packed three-element float vector type, but this
// type has the same layout, size, and alignment such a type would have.
public typealias packed_float3 = (Float, Float, Float)

public extension simd_float4 {
    var xyz: simd_float3 {
        return simd_float3(x, y, z)
    }
}

extension simd_float4x4 {
    var upperLeft3x3: simd_float3x3 {
        return simd_float3x3(columns.0.xyz, columns.1.xyz, columns.2.xyz)
    }

    init(translation: simd_float3) {
        self.init(simd_float4(1, 0, 0, 0),
                  simd_float4(0, 1, 0, 0),
                  simd_float4(0, 0, 1, 0),
                  simd_float4(translation, 1))
    }

    init(rotationAbout axis: simd_float3, by angleRadians: Float) {
        let x = axis.x, y = axis.y, z = axis.z
        let c = cosf(angleRadians)
        let s = sinf(angleRadians)
        let t = 1 - c
        self.init(simd_float4( t * x * x + c,     t * x * y + z * s, t * x * z - y * s, 0),
                  simd_float4( t * x * y - z * s, t * y * y + c,     t * y * z + x * s, 0),
                  simd_float4( t * x * z + y * s, t * y * z - x * s,     t * z * z + c, 0),
                  simd_float4(                 0,                 0,                 0, 1))
    }

    init(orthographicProjectionLeft left: Float, top: Float, right: Float, bottom: Float, near: Float, far: Float)
    {
        let sx = 2.0 / (right - left)
        let sy = 2.0 / (top - bottom)
        let sz = 1.0 / (near - far)
        let tx = (left + right) / (left - right)
        let ty = (top + bottom) / (bottom - top)
        let tz = near / (near - far)
        self.init(simd_float4( sx, 0.0, 0.0, 0.0),
                  simd_float4(0.0,  sy, 0.0, 0.0),
                  simd_float4(0.0, 0.0,  sz, 0.0),
                  simd_float4( tx,  ty,  tz, 1.0))
    }

    // Produces a perspective projection with an infinitely distant "far plane" that
    // maps clip-space depth from 1 (near) to 0 (infinitely far)—so-called reverse-Z.
    // It also assumes that view space is right-handed, because...c'mon.
    init(perspectiveProjectionFOV fovYRadians: Float, aspectRatio: Float, near: Float)
    {
        let sy = 1 / tan(fovYRadians * 0.5)
        let sx = sy / aspectRatio
        self.init(simd_float4(sx, 0,  0,    0.0),
                  simd_float4(0, sy,  0,    0.0),
                  simd_float4(0,  0,  0,   -1.0),
                  simd_float4(0,  0, near,  0.0))
    }
}

extension simd_float4x4 {
    init(_ mat: simd_double4x4) {
        self.init(SIMD4<Float>(mat.columns.0),
                  SIMD4<Float>(mat.columns.1),
                  SIMD4<Float>(mat.columns.2),
                  SIMD4<Float>(mat.columns.3))
    }
}

/// Extracts the six frustum planes determined by the provided matrix.
// Ref. https://www8.cs.umu.se/kurser/5DV051/HT12/lab/plane_extraction.pdf
// Ref. https://fgiesen.wordpress.com/2012/08/31/frustum-planes-from-the-projection-matrix/
func frustumPlanes(from matrix: simd_float4x4) -> [simd_float4] {
    let mt = matrix.transpose
    let planes = [simd_float4](unsafeUninitializedCapacity: 6,
                               initializingWith: { buffer, initializedCount in
        buffer[0] = mt[3] + mt[0] // left
        buffer[1] = mt[3] - mt[0] // right
        buffer[2] = mt[3] - mt[1] // top
        buffer[3] = mt[3] + mt[1] // bottom
        buffer[4] = mt[2]         // near
        buffer[5] = mt[3] - mt[2] // far
        for i in 0..<6 {
            buffer[i] /= simd_length(buffer[i].xyz)
        }
        initializedCount = 6
    })
    return planes
}

public struct Angle {
    static func radians(_ radians: Double) -> Angle {
        return Angle(radians: radians)
    }

    static func degrees(_ degrees: Double) -> Angle {
        return Angle(degrees: degrees)
    }

    var radians: Double

    var degrees: Double {
        return radians * (180 / .pi)
    }

    init() {
        radians = 0.0
    }

    init(radians: Double) {
        self.radians = radians
    }

    init(degrees: Double) {
        self.radians = degrees * (.pi / 180)
    }

    static func + (lhs: Angle, rhs: Angle) -> Angle {
        return Angle(radians: lhs.radians + rhs.radians)
    }

    static func += (lhs: inout Angle, rhs: Angle) {
        lhs.radians += rhs.radians
    }
}

public struct Ray {
    let origin: simd_float3
    let direction: simd_float3
}

/*
struct BoundingSphere {
    var center = simd_float3()
    var radius: Float = 0.0

    init(points: StridedView<packed_float3>) {
        if points.count > 0 {
            // Ref. "A Simple Streaming Algorithm for Minimum Enclosing Balls" Zarrabi-Zadeh, Chan (2006)
            var center = simd_float3(points[0].0, points[0].1, points[0].2)
            var radius: Float = 0.0
            for pointTuple in points {
                let point = simd_float3(pointTuple.0, pointTuple.1, pointTuple.2)
                let distance = simd_distance(center, point)
                if distance > radius {
                    let deltaRadius = 0.5 * (distance - radius)
                    radius += deltaRadius
                    let deltaCenter = (deltaRadius / distance) * (point - center)
                    center += deltaCenter
                }
            }
            self.center = center
            self.radius = radius
        }
    }

    init(center: simd_float3 = simd_float3(), radius: Float = 0.0) {
        self.center = center
        self.radius = abs(radius)
    }

    func transformed(by transform: simd_float4x4) -> BoundingSphere {
        let newCenter = transform * simd_float4(center, 1.0)
        let stretchedRadius = transform * simd_float4(radius, radius, radius, 0.0)
        let newRadius = max(stretchedRadius.x, max(stretchedRadius.y, stretchedRadius.z))
        return BoundingSphere(center: newCenter.xyz, radius: newRadius)
    }
}
*/

struct BoundingBox {
    var min = simd_float3()
    var max = simd_float3()

    init(points: StridedView<packed_float3>) {
        if points.count > 0 {
            var min = simd_float3(points[0].0, points[0].1, points[0].2)
            var max = simd_float3(points[0].0, points[0].1, points[0].2)
            for pointTuple in points {
                let point = simd_float3(pointTuple.0, pointTuple.1, pointTuple.2)
                if point.x < min.x { min.x = point.x }
                if point.y < min.y { min.y = point.y }
                if point.z < min.z { min.z = point.z }
                if point.x > max.x { max.x = point.x }
                if point.y > max.y { max.y = point.y }
                if point.z > max.z { max.z = point.z }
            }
            self.min = min
            self.max = max
        }
    }

    init(min: simd_float3 = simd_float3(), max: simd_float3 = simd_float3()) {
        self.min = min
        self.max = max
    }

    func transformed(by transform: simd_float4x4) -> BoundingBox {
        let transformedCorners: [simd_float3] = [
            (transform * simd_float4(min.x, min.y, min.z, 1.0)).xyz,
            (transform * simd_float4(min.x, min.y, max.z, 1.0)).xyz,
            (transform * simd_float4(min.x, max.y, min.z, 1.0)).xyz,
            (transform * simd_float4(min.x, max.y, max.z, 1.0)).xyz,
            (transform * simd_float4(max.x, min.y, min.z, 1.0)).xyz,
            (transform * simd_float4(max.x, min.y, max.z, 1.0)).xyz,
            (transform * simd_float4(max.x, max.y, min.z, 1.0)).xyz,
            (transform * simd_float4(max.x, max.y, max.z, 1.0)).xyz,
        ]
        return transformedCorners.withUnsafeBufferPointer {
            BoundingBox(points: StridedView($0.baseAddress!,
                                            offset: 0,
                                            stride: MemoryLayout<simd_float3>.stride,
                                            count: transformedCorners.count))
        }
    }
}

public struct Transform {
    var position: simd_float3
    var scale: simd_float3
    var orientation: simd_quatf

    var matrix: simd_float4x4 {
        let R = matrix_float3x3(orientation)
        let TRS = simd_float4x4(simd_float4(scale.x * R.columns.0, 0),
                                simd_float4(scale.y * R.columns.1, 0),
                                simd_float4(scale.z * R.columns.2, 0),
                                simd_float4(position, 1))
        return TRS
    }

    var inverse: Transform {
        let RSinv = self.matrix.upperLeft3x3.inverse
        let TRSInv = simd_float4x4(simd_float4(RSinv.columns.0,   0.0),
                                   simd_float4(RSinv.columns.1,   0.0),
                                   simd_float4(RSinv.columns.2,   0.0),
                                   simd_float4(-RSinv * position, 1.0))
        return Transform(TRSInv)
    }

    init(position: simd_float3 = simd_float3(0, 0, 0),
         scale: simd_float3 = simd_float3(1, 1, 1),
         orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    {
        self.position = position
        self.scale = scale
        self.orientation = orientation
    }

    @available(macOS 13.0, *)
    init(_ pose: Pose3D) {
        self.position = simd_float3(pose.position)
        self.scale = simd_float3(repeating: 1.0)
        self.orientation = simd_quatf(pose.rotation)
    }

    /// Initializes a Transform by decomposing the provided affine transformation matrix.
    /// Assumes the provided matrix is a valid TRS matrix.
    init(_ matrix: simd_float4x4) {
        self.position = matrix.columns.3.xyz
        let RS = matrix.upperLeft3x3
        let sx = simd_length(RS.columns.0)
        let sy = simd_length(RS.columns.1)
        let sz = simd_length(RS.columns.2)
        let R = simd_float3x3(RS.columns.0 / sx, RS.columns.1 / sy, RS.columns.2 / sz)
        self.scale = simd_float3(sx, sy, sz)
        self.orientation = simd_quatf(R)
    }

    mutating func setRotation(axis: simd_float3, angle angleRadians: Float) {
        orientation = simd_quatf(angle: angleRadians, axis: axis)
    }

    mutating func look(at toPoint: simd_float3, from fromPoint: simd_float3, up upVector: simd_float3) {
        let zNeg = simd_normalize(toPoint - fromPoint)
        let x = simd_normalize(simd_cross(zNeg, upVector))
        let y = simd_normalize(simd_cross(x, zNeg))
        let R = matrix_float3x3(x, y, -zNeg)
        orientation = simd_quaternion(R)
        position = fromPoint
    }

    static func * (lhs: Transform, rhs: Transform) -> Transform {
        // TODO: Write a more efficient implementation exploiting affine matrix properties
        return Transform(lhs.matrix * rhs.matrix)
    }
}
