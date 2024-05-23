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

constant bool writesRenderTargetSlice [[function_constant(0)]];

struct MeshVertexIn {
    float3 position  [[attribute(0)]];
    float3 normal    [[attribute(1)]];
    float2 texCoords [[attribute(2)]];
};

struct MeshVertexOut {
    float4 clipPosition [[position]];
    float3 position; // world-space position
    float3 normal;
    float2 texCoords;
    uint renderTargetSlice [[render_target_array_index, function_constant(writesRenderTargetSlice)]];
    uint viewIndex [[viewport_array_index]];
};

struct PBRFragmentIn {
    float4 clipPosition [[position]];
    float3 position;
    float3 normal;
    float2 texCoords;
    uint viewIndex [[viewport_array_index]];
    bool frontFacing [[front_facing]];
};

struct Light {
    float3 direction;
    float3 position;
    float3 color;
    float range;
    float intensity;
    float innerConeCos;
    float outerConeCos;
    unsigned int type;

    float getDistanceAttenuation(float range, float distance) const {
        float recipDistanceSq = 1.0f / (distance * distance);
        if (range <= 0.0f) {
            // negative range means unlimited, so use unmodified inverse-square law
            return recipDistanceSq;
        }
        return max(min(1.0f - powr(distance / range, 4.0f), 1.0f), 0.0f) * recipDistanceSq;
    }

    float getSpotAttenuation(float3 pointToLight, float3 spotDirection) const
    {
        float actualCos = dot(normalize(spotDirection), normalize(-pointToLight));
        if (actualCos > outerConeCos) {
            if (actualCos < innerConeCos) {
                return smoothstep(outerConeCos, innerConeCos, actualCos);
            }
            return 1.0f;
        }
        return 0.0f;
    }

    half3 getIntensity(float3 pointToLight) const {
        float rangeAttenuation = 1.0;
        float spotAttenuation = 1.0;

        if (type != LightTypeDirectional) {
            rangeAttenuation = getDistanceAttenuation(range, length(pointToLight));
        }
        if (type == LightTypeSpot) {
            spotAttenuation = getSpotAttenuation(pointToLight, direction);
        }

        return rangeAttenuation * spotAttenuation * half3(intensity * color);
    }
};

struct TangentSpace {
    float3 T;  // Geometric tangent
    float3 B;  // Geometric bitangent
    float3 Ng; // Geometric normal
    float3 N;  // Shading normal (TBN() * Nt)

    float3x3 TBN() const {
        return { T, B, Ng };
    }
};

static TangentSpace getTangentSpace(PBRFragmentIn v, constant PBRMaterialConstants &material, 
                                    texture2d<float, access::sample> normalTexture, sampler normalSampler)
{
    float2 uv = v.texCoords;
    float3 uv_dx = dfdx(float3(uv, 0.0f));
    float3 uv_dy = dfdy(float3(uv, 0.0f));

    if (length(uv_dx) + length(uv_dy) <= 1e-6f) {
        uv_dx = float3(1.0f, 0.0f, 0.0f);
        uv_dy = float3(0.0f, 1.0f, 0.0f);
    }

    float3 Tapprox = (uv_dy.y * dfdx(v.position.xyz) - uv_dx.y * dfdy(v.position.xyz)) /
                     (uv_dx.x * uv_dy.y - uv_dy.x * uv_dx.y);

    float3 t, b, ng;

    ng = normalize(v.normal.xyz);
    t = normalize(Tapprox - ng * dot(ng, Tapprox));
    b = cross(ng, t);

    if (!v.frontFacing) {
        t *= -1.0f;
        b *= -1.0f;
        ng *= -1.0f;
    }

    // Apply normal map if available
    TangentSpace basis;
    basis.Ng = ng;
    if (!is_null_texture(normalTexture)) {
        float3 Nt = normalTexture.sample(normalSampler, uv).rgb * 2.0f - 1.0f;
        Nt *= float3(material.normalScale, material.normalScale, 1.0);
        Nt = normalize(Nt);
        basis.N = normalize(float3x3(t, b, ng) * Nt);
    } else {
        basis.N = ng;
    }

    basis.T = t;
    basis.B = b;
    return basis;
}

static half3 F_Schlick(half3 f0, half3 f90, half VdotH) {
    return f0 + (f90 - f0) * powr(saturate(1.h - VdotH), 5.0h);
}

static half V_GGX(half NdotL, half NdotV, half alphaRoughness)
{
    half alphaRoughnessSq = alphaRoughness * alphaRoughness;
    half GGXV = NdotL * sqrt(NdotV * NdotV * (1.0h - alphaRoughnessSq) + alphaRoughnessSq);
    half GGXL = NdotV * sqrt(NdotL * NdotL * (1.0h - alphaRoughnessSq) + alphaRoughnessSq);
    half GGX = GGXV + GGXL;
    if (GGX > 0.0) {
        return 0.5 / GGX;
    }
    return 0.0;
}

static float D_GGX(float NdotH, float alphaRoughness) {
    float alphaRoughnessSq = alphaRoughness * alphaRoughness;
    float f = (NdotH * NdotH) * (alphaRoughnessSq - 1.0f) + 1.0f;
    return alphaRoughnessSq / (M_PI_F * f * f);
}

static half3 BRDF_lambertian(half3 f0, half3 f90, half3 diffuseColor, float VdotH = 1.0f) {
    // see https://seblagarde.wordpress.com/2012/01/08/pi-or-not-to-pi-in-game-lighting-equation/
    return diffuseColor / M_PI_F;
}

static half3 BRDF_specularGGX(half3 f0, half3 f90, half alphaRoughness,
                              half VdotH, half NdotL, half NdotV, half NdotH)
{
    half3 F = F_Schlick(f0, f90, VdotH);
    half V = V_GGX(NdotL, NdotV, alphaRoughness);
    half D = D_GGX(NdotH, alphaRoughness);
    return F * V * D;
}

vertex MeshVertexOut vertex_main(MeshVertexIn in [[stage_in]],
                                 constant PassConstants &frame [[buffer(VertexBufferPassConstants)]],
                                 constant InstanceConstants *instances [[buffer(VertexBufferInstanceConstants)]],
                                 uint instanceID [[instance_id]],
                                 uint amplificationID [[amplification_id]],
                                 uint amplificationCount [[amplification_count]])
{
    uint viewIndex = amplificationID;
    constant auto& instance = instances[instanceID];

    float4 worldPosition = instance.modelMatrix * float4(in.position, 1.0f);
    float4x4 viewProjectionMatrix = frame.projectionMatrices[viewIndex] * frame.viewMatrices[viewIndex];

    MeshVertexOut out;
    out.position = worldPosition.xyz;
    out.normal = normalize(instance.normalMatrix * in.normal);
    out.texCoords = in.texCoords;
    out.clipPosition = viewProjectionMatrix * worldPosition;
    out.viewIndex = viewIndex;

    if (amplificationCount > 1) {
        if (writesRenderTargetSlice) {
            out.renderTargetSlice = viewIndex;
        }
    }

    return out;
}

half3 EnvDFGPolynomial_Knarkowicz(half3 specularColor, float gloss, float NdotV) {
    half x = gloss;
    half y = NdotV;

    half b1 = -0.1688h;
    half b2 = 1.895h;
    half b3 = 0.9903h;
    half b4 = -4.853h;
    half b5 = 8.404h;
    half b6 = -5.069h;
    half bias = saturate( min( b1 * x + b2 * x * x, b3 + b4 * y + b5 * y * y + b6 * y * y * y ) );

    half d0 = 0.6045h;
    half d1 = 1.699h;
    half d2 = -0.5228h;
    half d3 = -3.603h;
    half d4 = 1.404h;
    half d5 = 0.1939h;
    half d6 = 2.661h;
    half delta = saturate( d0 + d1 * x + d2 * y + d3 * x * x + d4 * x * y + d5 * y * y + d6 * x * x * x );
    half scale = delta - bias;

    bias *= saturate(50.0f * specularColor.y);
    return specularColor * scale + bias;
}

typedef half4 FragmentOut;

fragment FragmentOut fragment_pbr(PBRFragmentIn in [[stage_in]],
                                  constant PassConstants &frame           [[buffer(FragmentBufferPassConstants)]],
                                  constant PBRMaterialConstants &material [[buffer(FragmentBufferMaterialConstants)]],
                                  constant Light *lights                  [[buffer(FragmentBufferLights)]],
                                  texture2d<half, access::sample> baseColorTexture [[texture(FragmentTextureBaseColor)]],
                                  texture2d<float, access::sample> normalTexture   [[texture(FragmentTextureNormal)]],
                                  texture2d<half, access::sample> metalnessTexture [[texture(FragmentTextureMetalness)]],
                                  texture2d<half, access::sample> roughnessTexture [[texture(FragmentTextureRoughness)]],
                                  texture2d<half, access::sample> emissiveTexture  [[texture(FragmentTextureEmissive)]],
                                  sampler baseColorSampler [[sampler(FragmentTextureBaseColor)]],
                                  sampler normalSampler    [[sampler(FragmentTextureNormal)]],
                                  sampler metalnessSampler [[sampler(FragmentTextureMetalness)]],
                                  sampler roughnessSampler [[sampler(FragmentTextureRoughness)]],
                                  sampler emissiveSampler  [[sampler(FragmentTextureEmissive)]],
                                  texturecube<half, access::sample> environmentLightTexture [[texture(FragmentTextureEnvironmentLight)]])
{
    half4 baseColor = half4(material.baseColorFactor);
    if (!is_null_texture(baseColorTexture)) {
        baseColor *= baseColorTexture.sample(baseColorSampler, in.texCoords);
    }

    half metalness = material.metallicFactor;
    if (!is_null_texture(metalnessTexture)) {
        float sampledMetalness = metalnessTexture.sample(metalnessSampler, in.texCoords).b;
        metalness *= sampledMetalness;
    }
    metalness = saturate(metalness);

    half perceptualRoughness = material.roughnessFactor;
    if (!is_null_texture(roughnessTexture)) {
        half sampledRoughness = roughnessTexture.sample(roughnessSampler, in.texCoords).g;
        perceptualRoughness *= sampledRoughness;
    }
    perceptualRoughness = clamp(perceptualRoughness, 0.004h, 1.0h);
    half alphaRoughness = perceptualRoughness * perceptualRoughness;

    half3 diffuseReflectance = mix(baseColor.rgb, half3(0.0h), metalness);
    half3 F0 = mix(half3(0.04h), baseColor.rgb, metalness);
    half3 F90 = half3(1.0h);

    float3 V = normalize(frame.cameraPositions[in.viewIndex] - in.position);
    TangentSpace tangentSpace = getTangentSpace(in, material, normalTexture, normalSampler);
    float3 N = tangentSpace.N;

    half NdotV = saturate(dot(N, V));

    half3 f_diffuse {};
    half3 f_specular {};
    half3 f_emissive {};

    if (!is_null_texture(emissiveTexture)) {
        half3 sampledEmission = emissiveTexture.sample(emissiveSampler, in.texCoords).rgb;
        f_emissive = sampledEmission * material.emissiveStrength;
    } else {
        f_emissive = half3(material.emissiveColor * material.emissiveStrength);
    }

    if (!is_null_texture(environmentLightTexture)) {
        float3 N_cube = (frame.environmentLightMatrix * float4(N, 0.0f)).xyz;
        constexpr sampler environmentSampler(filter::linear, mip_filter::linear);
        float mipCount = environmentLightTexture.get_num_mip_levels();
        // Sample the highest mip level available, since this is essentially a per cube face average lighting estimate
        half3 I_diff = environmentLightTexture.sample(environmentSampler, N_cube, level(mipCount - 1)).rgb * M_PI_H;
        f_diffuse += I_diff * diffuseReflectance;
        // For specular environment lighting we use Knarkowicz's analytic DFG. Realitistically,
        // we should sample a much lower LOD than we do, since the environment maps from ARKit
        // are much coarser than we'd use with classical IBL. Conversely, they're not properly
        // prefiltered with an appropriate BRDF, so this is all just hacks anyway.
        float lod = perceptualRoughness * (mipCount - 1);
        half gloss = powr(1.0h - perceptualRoughness, 4.0h);
        half3 I_spec = environmentLightTexture.sample(environmentSampler, N_cube, level(lod)).rgb;
        f_specular += I_spec * EnvDFGPolynomial_Knarkowicz(F0, gloss, NdotV);
    }

    for (uint i = 0; i < frame.activeLightCount; ++i) {
        Light light = lights[i];

        float3 pointToLight;
        if (light.type != LightTypeDirectional) {
            pointToLight = light.position - in.position;
        } else {
            pointToLight = -light.direction;
        }

        float3 L = normalize(pointToLight);
        float3 H = normalize(L + V);
        half NdotL = saturate(dot(N, L));
        half NdotH = saturate(dot(N, H));
        half VdotH = saturate(dot(V, H));
        if (NdotL > 0.0h) {
            half3 intensity = light.getIntensity(pointToLight);
            f_diffuse += intensity * NdotL * BRDF_lambertian(F0, F90, diffuseReflectance, VdotH);
            if (NdotV > 0.0h) {
                f_specular += intensity * NdotL * BRDF_specularGGX(F0, F90, alphaRoughness, VdotH, NdotL, NdotV, NdotH);
            }
        }
    }

    half3 color = f_emissive + f_diffuse + f_specular;
    FragmentOut out = half4(color * baseColor.a, baseColor.a);
    return out;
}

using OcclusionFragmentIn = MeshVertexOut;

fragment FragmentOut fragment_occlusion(OcclusionFragmentIn in [[stage_in]]) {
    // What we return here doesn't matter because our color mask is zero.
    return {};
}
