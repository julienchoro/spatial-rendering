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
import SwiftUI

public protocol SceneContent {
    var entities: [Entity] { get }
    var lights: [Light] { get }
    var environmentLight: EnvironmentLight? { get }

    func enqueueEvent(_ event: Event)
    func update(_ timestep: TimeInterval)
}

enum RenderLayout {
    case dedicated
    case shared
    case layered
}
struct FramebufferDescriptor {
    var layout: RenderLayout
    var colorPixelFormat: MTLPixelFormat
    var depthPixelFormat: MTLPixelFormat
    var rasterSampleCount: Int
}

protocol FrameResourceProvider {
    var colorTextures: [any MTLTexture] { get }
    var depthTextures: [any MTLTexture] { get }
    var rasterizationRateMaps: [any MTLRasterizationRateMap] { get }
    var storeDepth: Bool { get }
}

struct FrameViews {
    let viewTransforms: [simd_float4x4]
    let projectionTransforms: [simd_float4x4]
    let viewports: [MTLViewport]
    let cameraPositions: [simd_float3]

    var viewCount: Int {
        viewports.count
    }
}

fileprivate struct MeshDrawCall {
    let mesh: Mesh
    let submesh: Submesh
    let material: Material
    let modelMatrices: [simd_float4x4]
}

fileprivate struct RenderPipelineCacheKey : Hashable {
    let vertexDescriptor: MDLVertexDescriptor
    let materialClass: Material.Type

    static func == (lhs: RenderPipelineCacheKey, rhs: RenderPipelineCacheKey) -> Bool {
        lhs.vertexDescriptor == rhs.vertexDescriptor && lhs.materialClass == rhs.materialClass
    }

    func hash(into hasher: inout Hasher) {
        vertexDescriptor.hash(into: &hasher)
        // Intentionally omit material type from the hash. We'll collide more often, but it hardly matters.
    }
}

fileprivate extension Array  {
    func firstTwo(paddingWith defaultValue: Element) -> (Element, Element) {
        if count >= 2 {
            return (self[0], self[1])
        } else if count == 1 {
            return (self[0], defaultValue)
        } else {
            return (defaultValue, defaultValue)
        }
    }
}

extension MetalContext {
    func makeRenderPipelineState(framebufferDescriptor: FramebufferDescriptor,
                                 vertexFunctionName: String,
                                 fragmentFunctionName: String,
                                 vertexDescriptor: MTLVertexDescriptor,
                                 colorWriteMask: MTLColorWriteMask = .all,
                                 blendMode: BlendMode = .opaque) throws -> MTLRenderPipelineState
    {
        guard let library = defaultLibrary else {
            fatalError("Could not find default library; are there any .metal files in your target?")
        }

        var writesRenderTargetSlice = framebufferDescriptor.layout == .layered
        let functionConstants = MTLFunctionConstantValues()
        functionConstants.setConstantValue(&writesRenderTargetSlice, type: .bool, withName: "writesRenderTargetSlice")
        let vertexFunction = try library.makeFunction(name: vertexFunctionName, constantValues: functionConstants)
        let fragmentFunction = try library.makeFunction(name: fragmentFunctionName, constantValues: functionConstants)

        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.vertexDescriptor = vertexDescriptor
        renderPipelineDescriptor.vertexFunction = vertexFunction
        renderPipelineDescriptor.fragmentFunction = fragmentFunction
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = framebufferDescriptor.colorPixelFormat
        renderPipelineDescriptor.colorAttachments[0].writeMask = colorWriteMask
        renderPipelineDescriptor.depthAttachmentPixelFormat = framebufferDescriptor.depthPixelFormat
        renderPipelineDescriptor.rasterSampleCount = framebufferDescriptor.rasterSampleCount

        // When potentially using vertex amplfication, we need to specify the primitive type
        // and maximum amplification count up front.
        let stereoVertexAmplificationCount = 2
        if framebufferDescriptor.layout != .dedicated {
            if device.supportsVertexAmplificationCount(stereoVertexAmplificationCount) {
                renderPipelineDescriptor.inputPrimitiveTopology = .triangle
                renderPipelineDescriptor.maxVertexAmplificationCount = stereoVertexAmplificationCount
            } else {
                fatalError("Shared or layered layout selected, but device doesn't support required amplification count")
            }
        }

        switch blendMode {
        case .opaque:
            renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        case .sourceOverPremultiplied:
            renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true

            renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            renderPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

            renderPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            renderPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            renderPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
    }

    func makeNonRasterizingPipelineState(vertexFunctionName: String,
                                         vertexDescriptor: MTLVertexDescriptor,
                                         dummyColorPixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState
    {
        guard let library = defaultLibrary else {
            fatalError("Could not find default library; are there any .metal files in your target?")
        }

        let functionConstants = MTLFunctionConstantValues()
        let vertexFunction = try library.makeFunction(name: vertexFunctionName, constantValues: functionConstants)

        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.vertexDescriptor = vertexDescriptor
        renderPipelineDescriptor.vertexFunction = vertexFunction
        renderPipelineDescriptor.isRasterizationEnabled = false
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = dummyColorPixelFormat

        return try device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
    }
}

class SceneRenderer : NSObject {
    let context: MetalContext
    let layout: RenderLayout
    let rasterSampleCount: Int

    var clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    var clearDepth = 0.0 // Assume reverse-Z

    private let constantsBuffer: RingBuffer
    private let skinningJointBuffer: RingBuffer

    private var renderPipelineCache = [RenderPipelineCacheKey : MTLRenderPipelineState]()
    private var depthStateCache = [Material.ID : MTLDepthStencilState]()
    private var multisampleColorTargets: [any MTLTexture] = []
    private var multisampleDepthTargets: [any MTLTexture] = []

    private let dummyRenderTarget: MTLTexture

    init(context: MetalContext, layout: RenderLayout) throws {
        self.context = context
        self.layout = layout
        self.rasterSampleCount = context.preferredRasterSampleCount
        self.constantsBuffer = try RingBuffer(device: context.device,
                                              length: 256 * 1024,
                                              label: "Constants Scratch Buffer")
        self.skinningJointBuffer = try RingBuffer(device: context.device,
                                                  length: 4 * 1024 * 1024,
                                                  label: "Skinning Joint Matrix Buffer")

        let dummyTargetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: context.preferredColorPixelFormat,
                                                                             width: 1,
                                                                             height: 1,
                                                                             mipmapped: false)
        dummyTargetDescriptor.storageMode = .private
        dummyTargetDescriptor.usage = .renderTarget
        dummyRenderTarget = context.device.makeTexture(descriptor: dummyTargetDescriptor)!
    }

    private func renderPipeline(forMesh mesh: Mesh, material: Material) throws -> MTLRenderPipelineState {
        let key = RenderPipelineCacheKey(vertexDescriptor: mesh.vertexDescriptor, materialClass: type(of: material))
        if let existingPipeline = renderPipelineCache[key] {
            return existingPipeline
        }

        //print("Render pipeline cache miss for \(type(of: material)), \(mesh.vertexDescriptor)")

        let framebuffer = FramebufferDescriptor(layout: layout,
                                                colorPixelFormat: context.preferredColorPixelFormat,
                                                depthPixelFormat: context.preferredDepthPixelFormat,
                                                rasterSampleCount: rasterSampleCount)

        let vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(mesh.vertexDescriptor)!
        let pipeline = try context.makeRenderPipelineState(framebufferDescriptor: framebuffer,
                                                           vertexFunctionName: material.vertexFunctionName,
                                                           fragmentFunctionName: material.fragmentFunctionName,
                                                           vertexDescriptor: vertexDescriptor,
                                                           colorWriteMask: material.colorMask,
                                                           blendMode: material.blendMode)

        renderPipelineCache[key] = pipeline
        return pipeline
    }

    private func skinningPipeline(forMesh mesh: Mesh) throws -> MTLRenderPipelineState {
        let key = RenderPipelineCacheKey(vertexDescriptor: mesh.vertexDescriptor, materialClass: Material.self)
        if let existingPipeline = renderPipelineCache[key] {
            return existingPipeline
        }
        let vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(mesh.vertexDescriptor)!
        let pipeline = try context.makeNonRasterizingPipelineState(vertexFunctionName: "vertex_skin",
                                                                   vertexDescriptor: vertexDescriptor,
                                                                   dummyColorPixelFormat: context.preferredColorPixelFormat)
        renderPipelineCache[key] = pipeline
        return pipeline
    }

    private func depthStencilState(forMaterial material: Material) -> MTLDepthStencilState {
        if let existingDepthState = depthStateCache[material.id] {
            return existingDepthState
        }
        let device = context.device
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.isDepthWriteEnabled = material.writesDepthBuffer
        depthStencilDescriptor.depthCompareFunction = material.readsDepthBuffer ? .greater : .always
        let depthState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
        depthStateCache[material.id] = depthState
        return depthState
    }

    private func makeMultisampleTargetsIfNeeded(for resources: FrameResourceProvider) {
        guard let representativeTarget = resources.colorTextures.first else { return }

        let width = representativeTarget.width
        let height = representativeTarget.height
        let arrayLength = representativeTarget.arrayLength
        let colorFormat = representativeTarget.pixelFormat
        let depthFormat = resources.depthTextures.first?.pixelFormat ?? .invalid

        if let existingTarget = multisampleColorTargets.first,
            existingTarget.width == width &&
            existingTarget.height == height &&
            existingTarget.arrayLength == arrayLength
        {
            return
        }

        multisampleColorTargets.removeAll()
        multisampleDepthTargets.removeAll()

        let colorDescriptor = MTLTextureDescriptor()
        colorDescriptor.textureType = (arrayLength > 1) ? .type2DMultisampleArray : .type2DMultisample
        colorDescriptor.pixelFormat = colorFormat
        colorDescriptor.width = width
        colorDescriptor.height = height
        colorDescriptor.sampleCount = rasterSampleCount
        colorDescriptor.arrayLength = arrayLength
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = context.device.hasUnifiedMemory ? .memoryless : .private

        let depthDescriptor = MTLTextureDescriptor()
        depthDescriptor.textureType = (arrayLength > 1) ? .type2DMultisampleArray : .type2DMultisample
        depthDescriptor.pixelFormat = depthFormat
        depthDescriptor.width = width
        depthDescriptor.height = height
        depthDescriptor.sampleCount = rasterSampleCount
        depthDescriptor.arrayLength = arrayLength
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = context.device.hasUnifiedMemory ? .memoryless : .private

        for _ in 0..<resources.colorTextures.count {
            let colorTarget = context.device.makeTexture(descriptor: colorDescriptor)!
            multisampleColorTargets.append(colorTarget)
            if depthFormat != .invalid {
                let depthTarget = context.device.makeTexture(descriptor: depthDescriptor)!
                multisampleDepthTargets.append(depthTarget)
            }
        }
    }

    private func makeRenderPassDescriptor(for resources: FrameResourceProvider, passIndex: Int) -> MTLRenderPassDescriptor {
        if rasterSampleCount > 1 {
            makeMultisampleTargetsIfNeeded(for: resources)
        }

        let passDescriptor = MTLRenderPassDescriptor()

        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = clearColor
        if rasterSampleCount > 1 {
            passDescriptor.colorAttachments[0].texture = multisampleColorTargets[passIndex]
            passDescriptor.colorAttachments[0].resolveTexture = resources.colorTextures[passIndex]
            passDescriptor.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            passDescriptor.colorAttachments[0].texture = resources.colorTextures[passIndex]
            passDescriptor.colorAttachments[0].storeAction = .store
        }

        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.clearDepth = clearDepth
        if rasterSampleCount > 1 {
            passDescriptor.depthAttachment.texture = multisampleDepthTargets[passIndex]
            passDescriptor.depthAttachment.resolveTexture = resources.depthTextures[passIndex]
            passDescriptor.depthAttachment.storeAction = .multisampleResolve
        } else {
            passDescriptor.depthAttachment.texture = resources.depthTextures[passIndex]
            passDescriptor.depthAttachment.storeAction = resources.storeDepth ? .store : .dontCare
        }

        passDescriptor.renderTargetArrayLength = resources.colorTextures[passIndex].arrayLength

        if (!resources.rasterizationRateMaps.isEmpty) {
            passDescriptor.rasterizationRateMap = resources.rasterizationRateMaps[passIndex]
        }

        return passDescriptor
    }

    private func bindPassResources(views: FrameViews, scene: SceneContent, renderCommandEncoder: MTLRenderCommandEncoder) {
        let lights = scene.lights
        var passData = PassConstants(viewMatrices: views.viewTransforms.firstTwo(paddingWith: simd_float4x4()),
                                     projectionMatrices: views.projectionTransforms.firstTwo(paddingWith: simd_float4x4()),
                                     cameraPositions: views.cameraPositions.firstTwo(paddingWith: simd_float3()),
                                     environmentLightMatrix: scene.environmentLight?.cubeFromWorldTransform.matrix ?? simd_float4x4(),
                                     activeLightCount: UInt32(lights.count))

        let passDataOffset = constantsBuffer.copy(&passData)
        renderCommandEncoder.setVertexBuffer(constantsBuffer.buffer,
                                             offset: passDataOffset,
                                             index: Int(VertexBufferPassConstants))
        renderCommandEncoder.setFragmentBuffer(constantsBuffer.buffer,
                                               offset: passDataOffset,
                                               index: Int(FragmentBufferPassConstants))

        let pbrLights = lights.map { light in
            // Lights, like cameras, point down the -Z axis of their local frame
            let direction = -light.transform.matrix.columns.2.xyz
            return PBRLight(direction: direction,
                            position: light.transform.position,
                            color: light.color,
                            range: light.range,
                            intensity: light.intensity,
                            innerConeCos: Float(cos(light.innerConeAngle.radians)),
                            outerConeCos: Float(cos(light.outerConeAngle.radians)),
                            type: UInt32(light.type.rawValue))
        }
        let lightsOffset = constantsBuffer.copy(pbrLights)
        renderCommandEncoder.setFragmentBuffer(constantsBuffer.buffer,
                                               offset: lightsOffset,
                                               index: Int(FragmentBufferLights))

        if let environmentLight = scene.environmentLight {
            renderCommandEncoder.setFragmentTexture(environmentLight.environmentTexture, index: Int(FragmentTextureEnvironmentLight))
        }
    }

    private func bindMeshResources(_ mesh: Mesh, renderCommandEncoder: MTLRenderCommandEncoder) {
        for (bufferIndex, vertexBuffer) in mesh.vertexBuffers.enumerated() {
            renderCommandEncoder.setVertexBuffer(vertexBuffer.buffer,
                                                 offset: vertexBuffer.offset,
                                                 index: bufferIndex)
        }
    }

    private func bindInstanceResources(_ instances: MeshDrawCall, renderCommandEncoder: MTLRenderCommandEncoder) {
        let instances = instances.modelMatrices.map { modelMatrix in
            let normalMatrix = modelMatrix.inverse.transpose.upperLeft3x3
            return InstanceConstants(modelMatrix: modelMatrix,
                                     normalMatrix: normalMatrix)
        }

        let instanceOffset = constantsBuffer.copy(instances)
        renderCommandEncoder.setVertexBuffer(constantsBuffer.buffer,
                                             offset: instanceOffset,
                                             index: Int(VertexBufferInstanceConstants))
    }

    private func drawMesh(_ instances: MeshDrawCall, renderCommandEncoder: MTLRenderCommandEncoder) {
        let mesh = instances.mesh
        precondition(!mesh.materials.isEmpty)
        let submesh = instances.submesh
        let material = instances.material

        let instanceCount = instances.modelMatrices.count

        bindInstanceResources(instances, renderCommandEncoder: renderCommandEncoder)
        bindMeshResources(mesh, renderCommandEncoder: renderCommandEncoder)

        do {
            let renderPipelineState = try renderPipeline(forMesh: mesh, material: material)
            renderCommandEncoder.setRenderPipelineState(renderPipelineState)
        } catch {
            fatalError("Encountered error when building render pipeline: \(error)")
        }

        material.bindResources(constantBuffer: constantsBuffer, renderCommandEncoder: renderCommandEncoder)

        renderCommandEncoder.setCullMode(material.isDoubleSided ? .none : .back)
        renderCommandEncoder.setTriangleFillMode(material.fillMode)
        let depthStencilState = depthStencilState(forMaterial: material)
        renderCommandEncoder.setDepthStencilState(depthStencilState)

        if let indexBuffer = submesh.indexBuffer {
            renderCommandEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                       indexCount: submesh.indexCount,
                                                       indexType: submesh.indexType,
                                                       indexBuffer: indexBuffer.buffer,
                                                       indexBufferOffset: indexBuffer.offset,
                                                       instanceCount: instanceCount)
        }
    }

    private func drawMainPass(views: FrameViews, scene: SceneContent, renderCommandEncoder: MTLRenderCommandEncoder) {
        renderCommandEncoder.setViewports(views.viewports)
        if layout != .dedicated {
            renderCommandEncoder.setVertexAmplificationCount(views.viewCount, viewMappings: nil)
        }

        bindPassResources(views: views, scene: scene, renderCommandEncoder: renderCommandEncoder)

        var drawCalls: [MeshDrawCall] = []
        for entity in scene.entities {
            if entity.isHidden { continue }
            guard let mesh = entity.mesh else { continue }
            let instanceModelMatrix = entity.worldTransform.matrix
            for submesh in mesh.submeshes {
                let drawCall = MeshDrawCall(mesh: mesh,
                                            submesh: submesh,
                                            material: mesh.materials[submesh.materialIndex % mesh.materials.count],
                                            modelMatrices: [instanceModelMatrix])
                drawCalls.append(drawCall)
            }
        }

        drawCalls.sort { $0.material.relativeSortOrder < $1.material.relativeSortOrder }

        for drawCall in drawCalls {
            drawMesh(drawCall, renderCommandEncoder: renderCommandEncoder)
        }
    }

    private func skinMesh(_ outputMesh: Mesh, skinner: Skinner, renderCommandEncoder: MTLRenderCommandEncoder) {
        let inputMesh = skinner.baseMesh
        do {
            let skinningPipeline = try skinningPipeline(forMesh: inputMesh)
            renderCommandEncoder.setRenderPipelineState(skinningPipeline)
        } catch {
            fatalError("Encountered error when building skinning render pipeline: \(error)")
        }
        bindMeshResources(inputMesh, renderCommandEncoder: renderCommandEncoder)

        let jointTransforms = skinner.jointTransforms.enumerated().map { index, jointWorldTransform in
            jointWorldTransform * skinner.skeleton.inverseBindTransforms[index]
        }
        let jointOffset = skinningJointBuffer.copy(jointTransforms)
        renderCommandEncoder.setVertexBuffer(skinningJointBuffer.buffer,
                                             offset: jointOffset,
                                             index: Int(VertexBufferSkinningJointTransforms))
        // Assume all vertex attributes are laid out in accordance with Mesh.postSkinningVertexDescriptor
        let skinnedAttributeBuffer = outputMesh.vertexBuffers[0]
        renderCommandEncoder.setVertexBuffer(skinnedAttributeBuffer.buffer,
                                             offset: skinnedAttributeBuffer.offset,
                                             index: Int(VertexBufferSkinningVerticesOut))

        renderCommandEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: inputMesh.vertexCount)
        skinner.isDirty = false
    }

    private func updateSkinnedEntities(_ entities: [Entity], commandBuffer: MTLCommandBuffer) {
        let skinnedEntitiesNeedingUpdate = entities.filter { entity in
            if let skinner = entity.skinner, skinner.isDirty { return true } else { return false }
        }
        if skinnedEntitiesNeedingUpdate.count > 0 {
            let skinningPassDescriptor = MTLRenderPassDescriptor()
            skinningPassDescriptor.colorAttachments[0].texture = dummyRenderTarget
            commandBuffer.pushDebugGroup("Mesh Vertex Skinning")
            if let skinningCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: skinningPassDescriptor) {
                skinnedEntitiesNeedingUpdate.forEach { entity in
                    guard let skinnedMesh = entity.mesh, let skinner = entity.skinner else { return }
                    commandBuffer.pushDebugGroup("Vertex Skinning (\(entity.name))")
                    skinMesh(skinnedMesh, skinner: skinner, renderCommandEncoder: skinningCommandEncoder)
                    commandBuffer.popDebugGroup()
                }
                skinningCommandEncoder.endEncoding()
                commandBuffer.popDebugGroup()
            }
        }
    }

    func drawFrame(scene: SceneContent, views: FrameViews, resources: FrameResourceProvider) {
        let commandQueue = context.commandQueue
        let commandBuffer = commandQueue.makeCommandBuffer()!

        updateSkinnedEntities(scene.entities, commandBuffer: commandBuffer)

        let passCount = (layout == .dedicated) ? views.viewCount : 1
        for passIndex in 0..<passCount {
            commandBuffer.pushDebugGroup("Main Pass #\(passIndex)")
            let renderPassDescriptor = makeRenderPassDescriptor(for: resources, passIndex: passIndex)
            if let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                renderCommandEncoder.setFrontFacing(.counterClockwise)
                drawMainPass(views: views, scene: scene, renderCommandEncoder: renderCommandEncoder)
                renderCommandEncoder.endEncoding()
            }
            commandBuffer.popDebugGroup()
        }

        commandBuffer.commit()
    }
}
