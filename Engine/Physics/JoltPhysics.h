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

#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SRJBodyType) {
    SRJBodyTypeStatic,
    SRJBodyTypeDynamic,
    SRJBodyTypeKinematic,
};

typedef struct SRJRigidBodyTransform_t {
    simd_float3 position;
    simd_quatf orientation;
} SRJRigidBodyTransform;

typedef struct SRJBodyProperties_t {
    float mass;
    float friction;
    float restitution;
    bool isAffectedByGravity;
} SRJBodyProperties;

@interface SRJPhysicsShape : NSObject
+ (instancetype)newSphereShapeWithRadius:(float)radius scale:(simd_float3)scale
NS_SWIFT_NAME(makeSphereShape(radius:scale:));

+ (instancetype)newBoxShapeWithExtents:(simd_float3)extents scale:(simd_float3)scale
NS_SWIFT_NAME(makeBoxShape(extents:scale:));

+ (nullable instancetype)newConvexHullShapeWithVertices:(const simd_float3 *)vertices
                                            vertexCount:(NSInteger)vertexCount
                                                  scale:(simd_float3)scale
                                                  error:(NSError **)error
NS_SWIFT_NAME(makeConvexHullShape(vertices:vertexCount:scale:))
NS_REFINED_FOR_SWIFT;

+ (instancetype)newConcavePolyhedronShapeWithVertices:(const simd_float3 *)vertices
                                          vertexCount:(NSInteger)vertexCount
                                              indices:(const uint32_t *)indices
                                           indexCount:(NSInteger)indexCount
                                                scale:(simd_float3)scale
NS_SWIFT_NAME(makeConcavePolyhedronShape(vertices:vertexCount:indices:indexCount:scale:)) NS_REFINED_FOR_SWIFT;

- (instancetype)init NS_UNAVAILABLE;
@end

@interface SRJPhysicsBody : NSObject
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, assign) SRJRigidBodyTransform transform;

@end

@interface SRJHitTestResult : NSObject
@property (nonatomic, weak) SRJPhysicsBody *body;
@property (nonatomic, assign) simd_float3 position;
@property (nonatomic, assign) CGFloat distance;
@end

@interface SRJPhysicsWorld : NSObject

+ (void)initializeJoltPhysics;
+ (void)deinitializeJoltPhysics;

- (SRJPhysicsBody *)createAndAddPhysicsBodyWithType:(SRJBodyType)type
                                         properties:(SRJBodyProperties)bodyProperties
                                       physicsShape:(SRJPhysicsShape *)shape
                                   initialTransform:(SRJRigidBodyTransform)transform
NS_SWIFT_NAME(addPhysicsBody(type:bodyProperties:physicsShape:initialTransform:));

- (void)removePhysicsBody:(SRJPhysicsBody *)physicsBody;

- (void)updateWithTimestep:(NSTimeInterval)timestep NS_SWIFT_NAME(update(timestep:));

- (NSArray<SRJHitTestResult *> *)hitTestWithSegmentFromPoint:(simd_float3)origin toPoint:(simd_float3)dest
NS_SWIFT_NAME(hitTestWithSegment(from:to:));

@end

NS_ASSUME_NONNULL_END
