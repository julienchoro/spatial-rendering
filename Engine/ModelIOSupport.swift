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
import MetalKit
import ModelIO

// The Swift interface for Model I/O has been broken since it was released in 2015.
// These extensions correct the types of a number of properties on Model I/O types.

extension MDLVertexDescriptor {
    var vertexAttributes: [MDLVertexAttribute] {
        return attributes as! [MDLVertexAttribute]
    }

    var bufferLayouts: [MDLVertexBufferLayout] {
        return layouts as! [MDLVertexBufferLayout]
    }
}

extension MDLMesh {
    var mdlSubmeshes: [MDLSubmesh]? {
        return submeshes as! [MDLSubmesh]?
    }
}

extension MTLSamplerDescriptor {
    convenience init(mdlTextureFilter: MDLTextureFilter?) {
        self.init()
        let metalAddressMode: (MDLMaterialTextureWrapMode) -> MTLSamplerAddressMode = { mode in
            switch mode {
            case .clamp:
                return .clampToEdge
            case .repeat:
                return .repeat
            case .mirror:
                return .mirrorRepeat
            @unknown default:
                return .repeat
            }
        }
        if let mdlTextureFilter {
            self.minFilter = mdlTextureFilter.minFilter == .nearest ? .nearest : .linear
            self.magFilter = mdlTextureFilter.magFilter == .nearest ? .nearest : .linear
            self.mipFilter = mdlTextureFilter.mipFilter == .nearest ? .nearest : .linear
            self.sAddressMode = metalAddressMode(mdlTextureFilter.sWrapMode)
            self.tAddressMode = metalAddressMode(mdlTextureFilter.tWrapMode)
        } else {
            self.minFilter = .linear
            self.magFilter = .linear
            self.mipFilter =  .linear
            self.sAddressMode = .repeat
            self.tAddressMode = .repeat
        }
    }
}

// This extension enables strided random access into a ModelIO vertex attribute data object.
// The type contained by the underlying data buffer must exactly match the Element type of
// the created view; otherwise behavior is undefined.
extension StridedView {
    init(attributeData: MDLVertexAttributeData, count: Int) {
        self.init(attributeData.dataStart, offset: 0, stride: attributeData.stride, count: count)
    }
}

class MetalResourceCache {
    let context: MetalContext

    private var textureCache: [ObjectIdentifier: MTLTexture] = [:]
    private var samplerCache: [MTLSamplerDescriptor : MTLSamplerState] = [:]

    init(context: MetalContext) {
        self.context = context
    }

    func makeTextureResource(for mdlMaterialProperty: MDLMaterialProperty,
                             contentType: TextureResource.ContentType) throws -> TextureResource
    {
        precondition(mdlMaterialProperty.type == .texture)

        let device = context.device

        guard let mdlTextureSampler = mdlMaterialProperty.textureSamplerValue else {
            throw ResourceError.invalidState
        }

        let samplerDescriptor = MTLSamplerDescriptor(mdlTextureFilter: mdlTextureSampler.hardwareFilter)

        let sampler = samplerCache[samplerDescriptor] ?? {
            let sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
            samplerCache[samplerDescriptor] = sampler
            return sampler
        }()

        guard let mdlTexture = mdlTextureSampler.texture else {
            throw ResourceError.imageLoadFailure
        }

        if let existingTexture = textureCache[ObjectIdentifier(mdlTexture)] {
            return .init(texture: existingTexture, sampler: sampler)
        }

        let textureLoader = TextureLoader(context: .shared)

        var options: [TextureLoader.Option : Any] = [
            .generateMipmaps : true,
            // Model I/O retains the lower-left origin texture coordinate convention of formats like USD[Z]
            // and OBJ, so we request that texel data be flipped on load. We could instead flip texture
            // coordinates when loading models or do this at runtime in the vertex shader, but this
            // seems the simplest approach, assuming that textures are always used with their corresponding
            // models and we don't mind that models' runtime texture coordinates follow the oppposite of
            // our preferred convention.
            .flipVertically : true
        ]
        if contentType == .raw {
            options[.sRGB] = false
        } else {
            options[.sRGB] = true
        }
        if device.supportsFamily(.apple2) {
            options[.storageMode] = MTLStorageMode.shared.rawValue
        }

        let texture = try textureLoader.makeTexture(mdlTexture: mdlTexture, options: options)
        texture.label = mdlMaterialProperty.name

        textureCache[ObjectIdentifier(mdlTexture)] = texture

        return .init(texture: texture, sampler: sampler)
    }
}

extension PhysicallyBasedMaterial {
    convenience init(mdlMaterial: MDLMaterial, resourceCache: MetalResourceCache) {
        self.init()

        if let baseColorProperty = mdlMaterial.property(with: MDLMaterialSemantic.baseColor) {
            if baseColorProperty.type == .texture {
                baseColor.baseColorTexture = try? resourceCache.makeTextureResource(for: baseColorProperty,
                                                                                    contentType: .color)
            } else if baseColorProperty.type == .float3 {
                let color = baseColorProperty.float3Value
                baseColor.baseColorFactor = simd_float4(color, 1.0)
            }
        }
        if let normalProperty = mdlMaterial.property(with: MDLMaterialSemantic.tangentSpaceNormal) {
            if normalProperty.type == .texture {
                normal.normalTexture = try? resourceCache.makeTextureResource(for: normalProperty,
                                                                              contentType: .raw)
            }
        }
        if let metalnessProperty = mdlMaterial.property(with: MDLMaterialSemantic.metallic) {
            if metalnessProperty.type == .texture {
                metalness.metalnessTexture = try? resourceCache.makeTextureResource(for: metalnessProperty,
                                                                                    contentType: .raw)
            } else if metalnessProperty.type == .float {
                metalness.metalnessFactor = metalnessProperty.floatValue
            }
        }
        if let roughnessProperty = mdlMaterial.property(with: MDLMaterialSemantic.roughness) {
            if roughnessProperty.type == .texture {
                roughness.roughnessTexture = try? resourceCache.makeTextureResource(for: roughnessProperty,
                                                                                    contentType: .raw)
            } else if roughnessProperty.type == .float {
                roughness.roughnessFactor = roughnessProperty.floatValue
            }
        }
        if let emissionProperty = mdlMaterial.property(with: MDLMaterialSemantic.emission) {
            if emissionProperty.type == .texture {
                emissive.emissiveTexture = try? resourceCache.makeTextureResource(for: emissionProperty,
                                                                                  contentType: .color)
            } else if emissionProperty.type == .float3 {
                emissive.emissiveColor = emissionProperty.float3Value
            }
        }
        if let _ = mdlMaterial.property(with: MDLMaterialSemantic.opacity) {
            // There are probably more precise checks we could do to determine if we should enable
            // alpha blending, but Model I/O doesn't have a convenient "blend mode" property, so
            // we use the presence of the opacity property as a simple heuristic.
            blendMode = .sourceOverPremultiplied
        }
    }
}

extension Mesh {
    convenience init(_ mdlMesh: MDLMesh, context: MetalContext, resourceCache: MetalResourceCache) {
        let device = context.device

        let vertexBuffers = mdlMesh.vertexBuffers.map { mdlBuffer in
            let bufferMap = mdlBuffer.map()
            let buffer = device.makeBuffer(bytes: bufferMap.bytes,
                                           length: mdlBuffer.length,
                                           options: .storageModeShared)!
            buffer.label = "Vertex Attributes"
            return BufferView(buffer: buffer)
        }

        var submeshes = [Submesh]()
        var materials = [Material]()
        for mdlSubmesh in (mdlMesh.mdlSubmeshes ?? []) {
            guard mdlSubmesh.geometryType == .triangles else { continue }

            let mdlIndexBuffer = mdlSubmesh.indexBuffer
            let bufferMap = mdlIndexBuffer.map()
            let buffer = device.makeBuffer(bytes: bufferMap.bytes,
                                           length: mdlIndexBuffer.length,
                                           options: .storageModeShared)!
            buffer.label = "Submesh Indices"
            let indexBuffer = BufferView(buffer: buffer)

            let indexType: MTLIndexType = mdlSubmesh.indexType == .uint16 ? .uint16 : .uint32

            var material = PhysicallyBasedMaterial.default
            if let mdlMaterial = mdlSubmesh.material {
                material = PhysicallyBasedMaterial(mdlMaterial: mdlMaterial, resourceCache: resourceCache)
                material.name = mdlMaterial.name
            }
            // ModelIO doesn't have any means of expressing whether a material is
            // double-sided, so we just assume all imported materials are.
            material.isDoubleSided = true

            let submesh = Submesh(primitiveType: .triangle,
                                  indexBuffer: indexBuffer,
                                  indexType: indexType,
                                  indexCount: mdlSubmesh.indexCount,
                                  materialIndex: materials.count)

            materials.append(material)
            submeshes.append(submesh)
        }

        let boundingBox = BoundingBox(min: mdlMesh.boundingBox.minBounds, max: mdlMesh.boundingBox.maxBounds)

        self.init(vertexCount: mdlMesh.vertexCount,
                  vertexBuffers: vertexBuffers,
                  vertexDescriptor: mdlMesh.vertexDescriptor,
                  submeshes: submeshes,
                  materials: materials,
                  boundingBox: boundingBox)
    }
}

extension Skeleton {
    convenience init(_ mdlSkeleton: MDLSkeleton, context: MetalContext) {
        let jointBindMatrices = mdlSkeleton.jointBindTransforms.float4x4Array.map { $0.inverse }
        let restMatrices = mdlSkeleton.jointRestTransforms.float4x4Array
        self.init(name: mdlSkeleton.name,
                  jointPaths: mdlSkeleton.jointPaths,
                  inverseBindTransforms: jointBindMatrices,
                  restTransforms: restMatrices)
    }
}

extension MDLObject {
    var animationBind: MDLAnimationBindComponent? {
        return components.filter({
            $0 is MDLAnimationBindComponent
        }).first as? MDLAnimationBindComponent
    }
}
