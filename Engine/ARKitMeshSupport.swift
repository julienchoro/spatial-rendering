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
import Metal
import ModelIO

extension Mesh {
    convenience init(_ meshAnchor: ARKit.MeshAnchor) {
        let geometry = meshAnchor.geometry
        precondition(geometry.faces.primitive == .triangle)
        precondition(geometry.vertices.format == .float3)
        precondition(geometry.normals.format == .float3)
        precondition(geometry.faces.bytesPerIndex == 2 || geometry.faces.bytesPerIndex == 4)

        let device = geometry.vertices.buffer.device
        let vertexCount = geometry.vertices.count

        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.vertexAttributes[0].name = MDLVertexAttributePosition
        vertexDescriptor.vertexAttributes[0].format = .float3
        vertexDescriptor.vertexAttributes[0].offset = 0
        vertexDescriptor.vertexAttributes[0].bufferIndex = 0
        vertexDescriptor.vertexAttributes[1].name = MDLVertexAttributeNormal
        vertexDescriptor.vertexAttributes[1].format = .float3
        vertexDescriptor.vertexAttributes[1].offset = 0
        vertexDescriptor.vertexAttributes[1].bufferIndex = 1
        vertexDescriptor.vertexAttributes[2].name = MDLVertexAttributeTextureCoordinate
        vertexDescriptor.vertexAttributes[2].format = .float2
        vertexDescriptor.vertexAttributes[2].offset = 0
        vertexDescriptor.vertexAttributes[2].bufferIndex = 2
        vertexDescriptor.bufferLayouts[0].stride = geometry.vertices.stride
        vertexDescriptor.bufferLayouts[1].stride = geometry.normals.stride
        vertexDescriptor.bufferLayouts[2].stride = MemoryLayout<simd_float2>.stride

        let positionView = BufferView(buffer: geometry.vertices.buffer, offset: geometry.vertices.offset)
        let normalView = BufferView(buffer: geometry.normals.buffer, offset: geometry.normals.offset)
        let texCoords = [simd_float2](repeating: simd_float2(), count: vertexCount)
        let texCoordBuffer = device.makeBuffer(bytes: texCoords,
                                               length: MemoryLayout<simd_float2>.stride * vertexCount,
                                               options: .storageModeShared)!
        texCoordBuffer.label = "Mesh Anchor Texture Coordinates"
        let texCoordView = BufferView(buffer: texCoordBuffer)

        let indexBuffer = BufferView(buffer: geometry.faces.buffer)

        let submesh = Submesh(primitiveType: .triangle,
                              indexBuffer: indexBuffer,
                              indexType: geometry.faces.bytesPerIndex == 4 ? .uint32 : .uint16,
                              indexCount: geometry.faces.count * geometry.faces.primitive.indexCount,
                              materialIndex: 0)

        self.init(vertexCount: vertexCount,
                  vertexBuffers: [positionView, normalView, texCoordView],
                  vertexDescriptor: vertexDescriptor,
                  submeshes: [submesh],
                  materials: [PhysicallyBasedMaterial.default])
    }

    convenience init(_ planeAnchor: ARKit.PlaneAnchor) {
        let geometry = planeAnchor.geometry
        precondition(geometry.meshVertices.format == .float3)
        precondition(geometry.meshFaces.primitive == .triangle)
        precondition(geometry.meshFaces.bytesPerIndex == 2 || geometry.meshFaces.bytesPerIndex == 4)

        let device = geometry.meshVertices.buffer.device
        let vertexCount = geometry.meshVertices.count

        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.vertexAttributes[0].name = MDLVertexAttributePosition
        vertexDescriptor.vertexAttributes[0].format = .float3
        vertexDescriptor.vertexAttributes[0].offset = 0
        vertexDescriptor.vertexAttributes[0].bufferIndex = 0
        vertexDescriptor.vertexAttributes[1].name = MDLVertexAttributeNormal
        vertexDescriptor.vertexAttributes[1].format = .float3
        vertexDescriptor.vertexAttributes[1].offset = 0
        vertexDescriptor.vertexAttributes[1].bufferIndex = 1
        vertexDescriptor.vertexAttributes[2].name = MDLVertexAttributeTextureCoordinate
        vertexDescriptor.vertexAttributes[2].format = .float2
        vertexDescriptor.vertexAttributes[2].offset = 0
        vertexDescriptor.vertexAttributes[2].bufferIndex = 2
        vertexDescriptor.bufferLayouts[0].stride = geometry.meshVertices.stride
        vertexDescriptor.bufferLayouts[1].stride = MemoryLayout<simd_float3>.stride
        vertexDescriptor.bufferLayouts[2].stride = MemoryLayout<simd_float2>.stride

        let positionView = BufferView(buffer: geometry.meshVertices.buffer, offset: geometry.meshVertices.offset)
        let normalData = [simd_float3](repeating: simd_float3(0, 1, 0), count: vertexCount)
        let normalBuffer = device.makeBuffer(bytes: normalData,
                                             length: MemoryLayout<simd_float3>.stride * vertexCount,
                                             options: .storageModeShared)!
        normalBuffer.label = "Plane Anchor Normals"
        let normalView = BufferView(buffer: normalBuffer)
        let texCoordData = [simd_float2](repeating: simd_float2(), count: vertexCount)
        let texCoordBuffer = device.makeBuffer(bytes: texCoordData,
                                               length: MemoryLayout<simd_float2>.stride * vertexCount,
                                               options: .storageModeShared)!
        texCoordBuffer.label = "Plane Anchor Texture Coordinates"
        let texCoordView = BufferView(buffer: texCoordBuffer)

        let indexBuffer = BufferView(buffer: geometry.meshFaces.buffer)

        let submesh = Submesh(primitiveType: .triangle,
                              indexBuffer: indexBuffer,
                              indexType: geometry.meshFaces.bytesPerIndex == 4 ? .uint32 : .uint16,
                              indexCount: geometry.meshFaces.count * geometry.meshFaces.primitive.indexCount,
                              materialIndex: 0)

        self.init(vertexCount: vertexCount,
                  vertexBuffers: [positionView, normalView, texCoordView],
                  vertexDescriptor: vertexDescriptor,
                  submeshes: [submesh],
                  materials: [PhysicallyBasedMaterial.default])
    }
}

#endif
