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

class Model {
    let rootEntities: [Entity]

    // Model I/O doesn't expose this property, which in USD is configurable via asset metadata,
    // but most USDZ files in the wild seem to favor USD's default unit of centimeters, so we
    // use this as a heuristic to match content to the real world.
    var metersPerUnit: Float = 0.01

    init(fileURL url: URL, context: MetalContext) throws {
        var rootEntities = [Entity]()
        let resourceCache = MetalResourceCache(context: context)
        var entityMap = [ObjectIdentifier : Entity]()
        autoreleasepool {
            let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil)

            asset.loadTextures()

            var skeletonMap = [ObjectIdentifier : Skeleton]()

            for mdlObject in asset.childObjects(of: MDLObject.self) {
                let entity = Entity()
                entity.name = mdlObject.name
                entityMap[ObjectIdentifier(mdlObject)] = entity

                if let transformComponent = mdlObject.transform {
                    entity.modelTransform = Transform(transformComponent.matrix)
                }

                if let mdlMesh = mdlObject as? MDLMesh {
                    // If a mesh has an associated animation bind component, it may have a skeleton and be
                    // skeletally animated, so we need to apply a vertex descriptor that preserves any joint
                    // weight/index data. Otherwise, we conform the mesh to our default vertex descriptor.
                    let isSkinned = (mdlObject.animationBind != nil)
                    let vertexDescriptor = isSkinned ? Mesh.skinnedVertexDescriptor : Mesh.defaultVertexDescriptor
                    mdlMesh.vertexDescriptor = vertexDescriptor

                    let mesh = Mesh(mdlMesh, context: context, resourceCache: resourceCache)
                    entity.mesh = mesh
                }

                if let mdlSkeleton = mdlObject as? MDLSkeleton {
                    let skeleton = Skeleton(mdlSkeleton, context: context)
                    skeletonMap[ObjectIdentifier(mdlSkeleton)] = skeleton
                }

                if let animationBind = mdlObject.animationBind, let mdlSkeleton = animationBind.skeleton {
                    if let skeleton = skeletonMap[ObjectIdentifier(mdlSkeleton)], let baseMesh = entity.mesh {
                        entity.skinner = Skinner(skeleton: skeleton, baseMesh: baseMesh)
                        entity.mesh = baseMesh.copyForSkinning(context: context)
                    }
                }

                if let parent = mdlObject.parent {
                    let parentEntity = entityMap[ObjectIdentifier(parent)]
                    parentEntity?.addChild(entity)
                    if parentEntity == nil {
                        print("Could not retrieve object parent (\"\(parent.name)\") from entity map; hierarchy will be broken")
                    }
                }

                if entity.parent == nil {
                    rootEntities.append(entity)
                }
            }
        }
        self.rootEntities = rootEntities
    }
}
