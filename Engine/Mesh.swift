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
import Metal
import ModelIO

public class Submesh : Identifiable {
    let primitiveType: MTLPrimitiveType
    let indexBuffer: BufferView?
    let indexType: MTLIndexType
    let indexCount: Int
    let materialIndex: Int

    init(primitiveType: MTLPrimitiveType,
         indexBuffer: BufferView?,
         indexType: MTLIndexType = .uint32,
         indexCount: Int = 0,
         materialIndex: Int)
    {
        self.primitiveType = primitiveType
        self.indexBuffer = indexBuffer
        self.indexType = indexType
        self.indexCount = indexCount
        self.materialIndex = materialIndex
    }
}

public class Mesh : Identifiable {
    let vertexCount: Int
    let vertexBuffers: [BufferView]
    let vertexDescriptor: MDLVertexDescriptor
    let boundingBox: BoundingBox
    let submeshes: [Submesh]
    var materials: [Material]

    init(vertexCount: Int,
         vertexBuffers: [BufferView],
         vertexDescriptor: MDLVertexDescriptor,
         submeshes: [Submesh],
         materials: [Material],
         boundingBox: BoundingBox? = nil)
    {
        self.vertexCount = vertexCount
        self.vertexBuffers = vertexBuffers
        self.vertexDescriptor = vertexDescriptor
        if let boundingBox {
            self.boundingBox = boundingBox
        } else {
            if let positionAttribute = vertexDescriptor.attributeNamed(MDLVertexAttributePosition) {
                let positionView = vertexBuffers[positionAttribute.bufferIndex]
                let positionBufferLayout = vertexDescriptor.bufferLayouts[positionAttribute.bufferIndex]
                let positionAccessor = StridedView<packed_float3>(positionView.buffer.contents() + positionView.offset,
                                                                  offset: positionAttribute.offset,
                                                                  stride: positionBufferLayout.stride,
                                                                  count: vertexCount)
                self.boundingBox = BoundingBox(points: positionAccessor)
            } else {
                self.boundingBox = BoundingBox()
            }
        }
        self.submeshes = submeshes
        self.materials = materials
    }
}

extension Mesh {
    static var defaultVertexDescriptor: MDLVertexDescriptor {
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.vertexAttributes[0].name = MDLVertexAttributePosition
        vertexDescriptor.vertexAttributes[0].format = .float3
        vertexDescriptor.vertexAttributes[0].offset = 0
        vertexDescriptor.vertexAttributes[0].bufferIndex = 0
        vertexDescriptor.bufferLayouts[0].stride = MemoryLayout<simd_float4>.stride

        vertexDescriptor.vertexAttributes[1].name = MDLVertexAttributeNormal
        vertexDescriptor.vertexAttributes[1].format = .float3
        vertexDescriptor.vertexAttributes[1].offset = 0
        vertexDescriptor.vertexAttributes[1].bufferIndex = 1
        vertexDescriptor.vertexAttributes[2].name = MDLVertexAttributeTextureCoordinate
        vertexDescriptor.vertexAttributes[2].format = .float2
        vertexDescriptor.vertexAttributes[2].offset = MemoryLayout<simd_float4>.stride
        vertexDescriptor.vertexAttributes[2].bufferIndex = 1
        vertexDescriptor.bufferLayouts[1].stride = MemoryLayout<simd_float4>.stride + MemoryLayout<simd_float2>.stride

        return vertexDescriptor
    }

    static var skinnedVertexDescriptor: MDLVertexDescriptor {
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.vertexAttributes[0].name = MDLVertexAttributePosition
        vertexDescriptor.vertexAttributes[0].format = .float3
        vertexDescriptor.vertexAttributes[0].offset = 0
        vertexDescriptor.vertexAttributes[0].bufferIndex = 0
        vertexDescriptor.vertexAttributes[1].name = MDLVertexAttributeNormal
        vertexDescriptor.vertexAttributes[1].format = .float3
        vertexDescriptor.vertexAttributes[1].offset = MemoryLayout<Float>.stride * 3
        vertexDescriptor.vertexAttributes[1].bufferIndex = 0
        vertexDescriptor.vertexAttributes[2].name = MDLVertexAttributeTextureCoordinate
        vertexDescriptor.vertexAttributes[2].format = .float2
        vertexDescriptor.vertexAttributes[2].offset = MemoryLayout<Float>.stride * 6
        vertexDescriptor.vertexAttributes[2].bufferIndex = 0
        vertexDescriptor.vertexAttributes[3].name = MDLVertexAttributeJointWeights
        vertexDescriptor.vertexAttributes[3].format = .float4
        vertexDescriptor.vertexAttributes[3].offset = MemoryLayout<Float>.stride * 8
        vertexDescriptor.vertexAttributes[3].bufferIndex = 0
        vertexDescriptor.vertexAttributes[4].name = MDLVertexAttributeJointIndices
        vertexDescriptor.vertexAttributes[4].format = .uShort4
        vertexDescriptor.vertexAttributes[4].offset = MemoryLayout<Float>.stride * 12
        vertexDescriptor.vertexAttributes[4].bufferIndex = 0
        vertexDescriptor.bufferLayouts[0].stride = MemoryLayout<Float>.stride * 12 + MemoryLayout<simd_ushort4>.stride

        return vertexDescriptor
    }
}

public class Skeleton {
    var name: String
    var jointPaths: [String]
    var inverseBindTransforms: [simd_float4x4]
    var restTransforms: [simd_float4x4]

    init(name: String, jointPaths: [String], inverseBindTransforms: [simd_float4x4], restTransforms: [simd_float4x4]) {
        self.name = name
        self.jointPaths = jointPaths
        self.inverseBindTransforms = inverseBindTransforms
        self.restTransforms = restTransforms
    }
}

public class Skinner {
    let skeleton: Skeleton
    let baseMesh: Mesh

    var jointTransforms: [simd_float4x4] {
        didSet {
            precondition(jointTransforms.count == skeleton.jointPaths.count)
            isDirty = true
        }
    }

    var isDirty = true

    init(skeleton: Skeleton, baseMesh: Mesh) {
        self.skeleton = skeleton
        self.baseMesh = baseMesh
        self.jointTransforms = skeleton.restTransforms
    }
}

extension Mesh {
    /// A single-buffer, packed, interleaved vertex data layout suitable for simple vertex skinning use cases
    static let postSkinningVertexDescriptor: MDLVertexDescriptor = {
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.vertexAttributes[0].name = MDLVertexAttributePosition
        vertexDescriptor.vertexAttributes[0].format = .float3
        vertexDescriptor.vertexAttributes[0].offset = 0
        vertexDescriptor.vertexAttributes[0].bufferIndex = 0
        vertexDescriptor.vertexAttributes[1].name = MDLVertexAttributeNormal
        vertexDescriptor.vertexAttributes[1].format = .float3
        vertexDescriptor.vertexAttributes[1].offset = MemoryLayout<Float>.stride * 3
        vertexDescriptor.vertexAttributes[1].bufferIndex = 0
        vertexDescriptor.vertexAttributes[2].name = MDLVertexAttributeTextureCoordinate
        vertexDescriptor.vertexAttributes[2].format = .float2
        vertexDescriptor.vertexAttributes[2].offset = MemoryLayout<Float>.stride * 6
        vertexDescriptor.vertexAttributes[2].bufferIndex = 0
        vertexDescriptor.bufferLayouts[0].stride = MemoryLayout<Float>.stride * 8
        return vertexDescriptor
    }()

    /// Creates a copy of this mesh that is suitable as a post-skinning destination for skinned vertices.
    /// Submeshes and materials are copied by reference.
    func copyForSkinning(context: MetalContext) -> Mesh {
        let vertexDescriptor = Mesh.postSkinningVertexDescriptor
        let vertexBufferLength = vertexDescriptor.bufferLayouts[0].stride * vertexCount
        let vertexBuffer = context.device.makeBuffer(length: vertexBufferLength,
                                                     options: [.storageModePrivate])!
        vertexBuffer.label = "Post-Skinning Vertex Attributes"
        return Mesh(vertexCount: self.vertexCount,
                    vertexBuffers: [BufferView(buffer: vertexBuffer)],
                    vertexDescriptor: vertexDescriptor,
                    submeshes: submeshes,
                    materials: materials,
                    boundingBox: boundingBox)
    }
}

extension Mesh {
    class func generateSphere(radius: Float, context: MetalContext) -> Mesh {
        let mdlMesh = MDLMesh.init(sphereWithExtent: simd_float3(repeating: radius),
                                   segments: simd_uint2(24, 24),
                                   inwardNormals: false,
                                   geometryType: .triangles,
                                   allocator: nil)
        mdlMesh.vertexDescriptor = defaultVertexDescriptor
        let tempResourceCache = MetalResourceCache(context: context)
        let mesh = Mesh(mdlMesh, context: context, resourceCache: tempResourceCache)
        mesh.materials = [PhysicallyBasedMaterial.default]
        return mesh
    }

    class func generateBox(extents: simd_float3, context: MetalContext) -> Mesh {
        let mdlMesh = MDLMesh.init(boxWithExtent: extents,
                                   segments: simd_uint3(1, 1, 1),
                                   inwardNormals: false,
                                   geometryType: .triangles,
                                   allocator: nil)
        mdlMesh.vertexDescriptor = defaultVertexDescriptor
        let tempResourceCache = MetalResourceCache(context: context)
        let mesh = Mesh(mdlMesh, context: context, resourceCache: tempResourceCache)
        mesh.materials = [PhysicallyBasedMaterial.default]
        return mesh
    }
}
