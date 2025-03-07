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

import Metal
import ModelIO

enum BlendMode {
    case opaque
    case sourceOverPremultiplied
}

class Material : Identifiable {
    var name: String = ""
    var blendMode: BlendMode = .opaque
    var fillMode: MTLTriangleFillMode = .fill
    var isDoubleSided: Bool = false
    var writesDepthBuffer: Bool = true
    var readsDepthBuffer: Bool = true
    var colorMask: MTLColorWriteMask = [.red, .green, .blue, .alpha]

    var vertexFunctionName: String {
        fatalError("Material subclasses must implement vertexFunctionName")
    }

    var fragmentFunctionName: String {
        fatalError("Material subclasses must implement fragmentFunctionName")
    }

    var relativeSortOrder: Int {
        0
    }

    func bindResources(constantBuffer: RingBuffer, renderCommandEncoder: MTLRenderCommandEncoder) {}
}

class OcclusionMaterial : Material {
    override init() {
        super.init()
        colorMask = []
    }

    override var vertexFunctionName: String {
        "vertex_main"
    }

    override var fragmentFunctionName: String {
        "fragment_occlusion"
    }
    override var relativeSortOrder: Int {
        -1 // Occluders render first because they lay down the depth of real-world objects
    }
}

class PhysicallyBasedMaterial : Material {
    static var `default` : PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.name = "Default"
        material.baseColor.baseColorFactor = simd_float4(0.5, 0.5, 0.5, 1.0)
        material.roughness.roughnessFactor = 0.5
        material.metalness.metalnessFactor = 0.0
        return material
    }

    struct BaseColor {
        var baseColorTexture: TextureResource?
        var baseColorFactor: simd_float4 = simd_float4(1, 1, 1, 1)
    }

    struct Normal {
        var normalTexture: TextureResource?
        var normalStrength: Float = 1.0
    }

    struct Metalness {
        var metalnessTexture: TextureResource?
        var metalnessFactor: Float = 1.0
    }

    struct Roughness {
        var roughnessTexture: TextureResource?
        var roughnessFactor: Float = 1.0
    }

    struct Emissive {
        var emissiveTexture: TextureResource?
        var emissiveColor: simd_float3 = simd_float3(0, 0, 0)
        var emissiveStrength: Float = 1.0
    }

    var baseColor = BaseColor()
    var normal = Normal()
    var metalness = Metalness()
    var roughness = Roughness()
    var emissive = Emissive()

    override var vertexFunctionName: String {
        "vertex_main"
    }

    override var fragmentFunctionName: String {
        "fragment_pbr"
    }

    override var relativeSortOrder: Int {
        if colorMask.isEmpty {
            -1 // Occluders render first because they lay down the depth of real-world objects
        } else if blendMode != .opaque {
            1 // Transparents render last so they can read the depth buffer without affecting it
        } else {
            0
        }
    }

    private var defaultSampler: MTLSamplerState?

    override init() {
    }

    init(baseColor: simd_float4, roughness: Float, isMetal: Bool) {
        self.baseColor.baseColorFactor = baseColor
        self.roughness.roughnessFactor = roughness
        self.metalness.metalnessFactor = isMetal ? 1.0 : 0.0
    }

    override func bindResources(constantBuffer: RingBuffer, renderCommandEncoder: MTLRenderCommandEncoder) {
        if defaultSampler == nil {
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.mipFilter = .linear
            samplerDescriptor.sAddressMode = .repeat
            samplerDescriptor.tAddressMode = .repeat
            defaultSampler = renderCommandEncoder.device.makeSamplerState(descriptor: samplerDescriptor)
        }

        var material = PBRMaterialConstants(baseColorFactor: baseColor.baseColorFactor,
                                            emissiveColor: emissive.emissiveColor,
                                            normalScale: normal.normalStrength,
                                            metallicFactor: metalness.metalnessFactor,
                                            roughnessFactor: roughness.roughnessFactor,
                                            emissiveStrength: emissive.emissiveStrength)
        let materialOffset = constantBuffer.copy(&material)
        renderCommandEncoder.setFragmentBuffer(constantBuffer.buffer,
                                               offset: materialOffset,
                                               index: Int(FragmentBufferMaterialConstants))

        if let baseColorTexture = baseColor.baseColorTexture {
            renderCommandEncoder.setFragmentTexture(baseColorTexture.texture, index: Int(FragmentTextureBaseColor))
            renderCommandEncoder.setFragmentSamplerState(baseColorTexture.sampler ?? defaultSampler, index: Int(FragmentTextureBaseColor))
        } else {
            renderCommandEncoder.setFragmentTexture(nil, index: Int(FragmentTextureBaseColor))
            renderCommandEncoder.setFragmentSamplerState(defaultSampler, index: Int(FragmentTextureBaseColor))
        }

        if let normalTexture = normal.normalTexture {
            renderCommandEncoder.setFragmentTexture(normalTexture.texture, index: Int(FragmentTextureNormal))
            renderCommandEncoder.setFragmentSamplerState(normalTexture.sampler ?? defaultSampler, index: Int(FragmentTextureNormal))
        } else {
            renderCommandEncoder.setFragmentSamplerState(defaultSampler, index: Int(FragmentTextureNormal))
        }

        if let metalnessTexture = metalness.metalnessTexture {
            renderCommandEncoder.setFragmentTexture(metalnessTexture.texture, index: Int(FragmentTextureMetalness))
            renderCommandEncoder.setFragmentSamplerState(metalnessTexture.sampler ?? defaultSampler, index: Int(FragmentTextureMetalness))
        } else {
            renderCommandEncoder.setFragmentSamplerState(defaultSampler, index: Int(FragmentTextureMetalness))
        }

        if let roughnessTexture = roughness.roughnessTexture {
            renderCommandEncoder.setFragmentTexture(roughnessTexture.texture, index: Int(FragmentTextureRoughness))
            renderCommandEncoder.setFragmentSamplerState(roughnessTexture.sampler ?? defaultSampler, index: Int(FragmentTextureRoughness))
        } else {
            renderCommandEncoder.setFragmentSamplerState(defaultSampler, index: Int(FragmentTextureRoughness))
        }

        if let emissiveTexture = emissive.emissiveTexture {
            renderCommandEncoder.setFragmentTexture(emissiveTexture.texture, index: Int(FragmentTextureEmissive))
            renderCommandEncoder.setFragmentSamplerState(emissiveTexture.sampler ?? defaultSampler, index: Int(FragmentTextureEmissive))
        } else {
            renderCommandEncoder.setFragmentSamplerState(defaultSampler, index: Int(FragmentTextureEmissive))
        }
    }
}
