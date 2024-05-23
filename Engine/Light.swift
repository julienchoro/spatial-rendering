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
import Metal

public class Light {
    enum LightType : Int {
        case directional = 0
        case point       = 1
        case spot        = 2
    }

    var type = LightType.directional
    var transform = Transform()
    var color = simd_float3(1, 1, 1)
    var intensity: Float = 1
    var range: Float = 0
    var innerConeAngle = Angle.degrees(90)
    var outerConeAngle = Angle.degrees(90)

    init(type: LightType = LightType.directional,
         color: simd_float3 = simd_float3(1, 1, 1),
         intensity: Float = 1)
    {
        self.type = type
        self.color = color
        self.intensity = intensity
    }
}

public struct EnvironmentLight : @unchecked Sendable {
    let cubeFromWorldTransform: Transform
    let environmentTexture: MTLTexture?
    let scaleFactor: Float

    init(cubeFromWorldTransform: Transform, environmentTexture: MTLTexture?, scaleFactor: Float) {
        self.cubeFromWorldTransform = cubeFromWorldTransform
        self.environmentTexture = environmentTexture
        self.scaleFactor = scaleFactor
    }
}
