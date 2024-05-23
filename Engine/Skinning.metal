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

#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

struct SkinnedVertexIn {
    float3 position      [[attribute(0)]];
    float3 normal        [[attribute(1)]];
    float2 texCoords     [[attribute(2)]];
    float4 jointWeights  [[attribute(3)]];
    ushort4 jointIndices [[attribute(4)]];
};

// Since we use a fixed vertex layout for post-skinned vertices, this
// structure must exactly match Mesh.postSkinningVertexDescriptor.
struct SkinnedVertexOut {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 texCoords;
};

[[vertex]]
void vertex_skin(SkinnedVertexIn in                   [[stage_in]],
                 constant float4x4 *jointTransforms   [[buffer(VertexBufferSkinningJointTransforms)]],
                 device SkinnedVertexOut *outVertices [[buffer(VertexBufferSkinningVerticesOut)]],
                 uint vertexID                        [[vertex_id]])
{
    float4 weights = in.jointWeights;
    //float weightSum = weights[0] + weights[1] + weights[2] + weights[3];
    //weights /= weightSum;

    float4x4 skinningMatrix = weights[0] * jointTransforms[in.jointIndices[0]] +
                              weights[1] * jointTransforms[in.jointIndices[1]] +
                              weights[2] * jointTransforms[in.jointIndices[2]] +
                              weights[3] * jointTransforms[in.jointIndices[3]];

    float3 skinnedPosition = (skinningMatrix * float4(in.position, 1.0f)).xyz;
    // n.b. We'd ordinarily use the inverse transpose of the skinning matrix here to
    // get correct normal transformation, but if we assume uniform scale (which skinning
    // matrices almost always have), the inverse transpose produces the same vector
    // as the matrix itself, up to scale, so we avoid the expense of inverting.
    float3 skinnedNormal = normalize((skinningMatrix * float4(in.normal, 0.0f)).xyz);

    outVertices[vertexID].position = skinnedPosition;
    outVertices[vertexID].normal = skinnedNormal;
    outVertices[vertexID].texCoords = in.texCoords;
}
