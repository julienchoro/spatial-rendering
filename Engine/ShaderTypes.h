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

#pragma once

#include <simd/simd.h>

#if __METAL_VERSION__
#define CONST constant
#else
#define CONST static const
#endif

CONST unsigned int LightTypeDirectional = 0;
CONST unsigned int LightTypePoint       = 1;
CONST unsigned int LightTypeSpot        = 2;

// We reserve vertex buffer indices 0-3 for vertex attributes,
// since different materials and meshes may prefer different layouts.
CONST unsigned int VertexBufferPassConstants           = 4;
CONST unsigned int VertexBufferInstanceConstants       = 5;
CONST unsigned int VertexBufferSkinningJointTransforms = 6;
CONST unsigned int VertexBufferSkinningVerticesOut     = 16;

CONST unsigned int FragmentBufferPassConstants     = 0;
CONST unsigned int FragmentBufferMaterialConstants = 1;
CONST unsigned int FragmentBufferLights            = 2;

CONST unsigned int FragmentTextureBaseColor         = 0;
CONST unsigned int FragmentTextureNormal            = 1;
CONST unsigned int FragmentTextureMetalness         = 2;
CONST unsigned int FragmentTextureRoughness         = 3;
CONST unsigned int FragmentTextureEmissive          = 4;
CONST unsigned int FragmentTextureEnvironmentLight  = 30;

struct Frustum {
    simd_float4 planes[6];
};

#define MAX_VIEW_COUNT 2

struct PassConstants {
    simd_float4x4 viewMatrices[MAX_VIEW_COUNT];
    simd_float4x4 projectionMatrices[MAX_VIEW_COUNT];
    simd_float3 cameraPositions[MAX_VIEW_COUNT]; // world space
    simd_float4x4 environmentLightMatrix;
    unsigned int activeLightCount;
};

struct InstanceConstants {
    simd_float4x4 modelMatrix;
    simd_float3x3 normalMatrix;
};

struct PBRMaterialConstants {
    simd_float4 baseColorFactor;
    simd_float3 emissiveColor;
    float normalScale;
    float metallicFactor;
    float roughnessFactor;
    float emissiveStrength;
} ;

struct PBRLight {
    simd_float3 direction;
    simd_float3 position;
    simd_float3 color;
    float range;
    float intensity;
    float innerConeCos;
    float outerConeCos;
    unsigned int type;
};
