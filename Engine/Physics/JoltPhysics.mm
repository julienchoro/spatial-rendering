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

#include "JoltPhysics.h"

#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyActivationListener.h>
#include <Jolt/Physics/Collision/CastResult.h>
#include <Jolt/Physics/Collision/NarrowPhaseQuery.h>
#include <Jolt/Physics/Collision/RayCast.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/ConvexHullShape.h>
#include <Jolt/Physics/Collision/Shape/MeshShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>

#include <cstdarg>
#include <memory>
#include <thread>

JPH_SUPPRESS_WARNINGS

using namespace JPH::literals;

static NSString *const SRJErrorDomain = @"com.metalbyexample.spatial-rendering.jolt-physics";

static const uint cMaxBodies = 1024;
static const uint cNumBodyMutexes = 0;
static const uint cMaxBodyPairs = 1024;
static const uint cMaxContactConstraints = 1024;

static std::unique_ptr<JPH::Factory> sFactoryInstance;
static std::unique_ptr<JPH::TempAllocatorImpl> sTempAllocator;
static std::unique_ptr<JPH::JobSystemThreadPool> sJobSystem;

static void TraceImpl(const char *format, ...) {
    va_list list;
    va_start(list, format);
    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, list);
    va_end(list);
    NSLog(@"%s", buffer);
}

#ifdef JPH_ENABLE_ASSERTS

static bool AssertFailedImpl(const char *expr, const char *msg, const char *filename, uint line) {
    NSLog(@"%s:%d: (%s) %s", filename, line, expr, msg);
    return true; // Break to debugger
};

#endif // JPH_ENABLE_ASSERTS

namespace Layers {
    static constexpr JPH::ObjectLayer NON_MOVING = 0;
    static constexpr JPH::ObjectLayer MOVING = 1;
    static constexpr JPH::ObjectLayer NUM_LAYERS = 2;
};

class SRJObjectLayerPairFilter : public JPH::ObjectLayerPairFilter {
public:
    virtual bool ShouldCollide(JPH::ObjectLayer inObject1, JPH::ObjectLayer inObject2) const override {
        switch (inObject1) {
            case Layers::NON_MOVING:
                return inObject2 == Layers::MOVING; // Non-moving only collides with moving
            case Layers::MOVING:
                return true; // Moving collides with everything
            default:
                JPH_ASSERT(false);
                return false;
        }
    }
};

namespace BroadPhaseLayers {
    static constexpr JPH::BroadPhaseLayer NON_MOVING(0);
    static constexpr JPH::BroadPhaseLayer MOVING(1);
    static constexpr uint NUM_LAYERS(2);
};

class SRJBroadPhaseLayerInterface final : public JPH::BroadPhaseLayerInterface {
public:
    SRJBroadPhaseLayerInterface() {
        mObjectToBroadPhase[Layers::NON_MOVING] = BroadPhaseLayers::NON_MOVING;
        mObjectToBroadPhase[Layers::MOVING] = BroadPhaseLayers::MOVING;
    }

    virtual uint GetNumBroadPhaseLayers() const override {
        return BroadPhaseLayers::NUM_LAYERS;
    }

    virtual JPH::BroadPhaseLayer GetBroadPhaseLayer(JPH::ObjectLayer inLayer) const override {
        JPH_ASSERT(inLayer < Layers::NUM_LAYERS);
        return mObjectToBroadPhase[inLayer];
    }

#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
    virtual const char *GetBroadPhaseLayerName(JPH::BroadPhaseLayer inLayer) const override
    {
        switch ((JPH::BroadPhaseLayer::Type)inLayer) {
            case (JPH::BroadPhaseLayer::Type)BroadPhaseLayers::NON_MOVING:
                return "NON_MOVING";
            case (JPH::BroadPhaseLayer::Type)BroadPhaseLayers::MOVING:
                return "MOVING";
            default:
                JPH_ASSERT(false); return "INVALID";
        }
    }
#endif // JPH_EXTERNAL_PROFILE || JPH_PROFILE_ENABLED

private:
    JPH::BroadPhaseLayer mObjectToBroadPhase[Layers::NUM_LAYERS];
};

class SRJObjectVsBroadPhaseLayerFilter : public JPH::ObjectVsBroadPhaseLayerFilter
{
public:
    virtual bool ShouldCollide(JPH::ObjectLayer inLayer1, JPH::BroadPhaseLayer inLayer2) const override {
        switch (inLayer1) {
            case Layers::NON_MOVING:
                return inLayer2 == BroadPhaseLayers::MOVING;
            case Layers::MOVING:
                return true;
            default:
                JPH_ASSERT(false);
                return false;
        }
    }
};

class SRJContactListener : public JPH::ContactListener
{
public:
    virtual JPH::ValidateResult OnContactValidate(const JPH::Body &inBody1,
                                                  const JPH::Body &inBody2,
                                                  JPH::RVec3Arg inBaseOffset,
                                                  const JPH::CollideShapeResult &inCollisionResult) override
    {
        return JPH::ValidateResult::AcceptAllContactsForThisBodyPair;
    }

    virtual void OnContactAdded(const JPH::Body &inBody1, const JPH::Body &inBody2,
                                const JPH::ContactManifold &inManifold, JPH::ContactSettings &ioSettings) override
    {
    }

    virtual void OnContactPersisted(const JPH::Body &inBody1, const JPH::Body &inBody2,
                                    const JPH::ContactManifold &inManifold, JPH::ContactSettings &ioSettings) override
    {
    }

    virtual void OnContactRemoved(const JPH::SubShapeIDPair &inSubShapePair) override
    {
    }
};

class SRJBodyActivationListener : public JPH::BodyActivationListener {
public:
    virtual void OnBodyActivated(const JPH::BodyID &inBodyID, JPH::uint64 inBodyUserData) override
    {
        //std::cout << "A body got activated" << std::endl;
    }

    virtual void OnBodyDeactivated(const JPH::BodyID &inBodyID, JPH::uint64 inBodyUserData) override
    {
        //std::cout << "A body went to sleep" << std::endl;
    }
};

static inline bool scale_is_unity(simd_float3 s) {
    float eps = 1e-4;
    return (fabsf(s.x - 1.0f) < eps) && (fabsf(s.y - 1.0f) < eps) && (fabsf(s.z - 1.0f) < eps);
}

@implementation SRJHitTestResult
@end

@interface SRJPhysicsShape (/*JoltInternals*/)
@property (nonatomic, assign) JPH::ShapeRefC shapeRef;

- (instancetype)initWithShapeRef:(JPH::ShapeRefC)shapeRef;

@end

@implementation SRJPhysicsShape

+ (instancetype)newSphereShapeWithRadius:(float)radius scale:(simd_float3)scale
{
    JPH::SphereShapeSettings shapeSettings {radius};
    shapeSettings.SetEmbedded();
    JPH::ShapeSettings::ShapeResult shapeResult = shapeSettings.Create();
    JPH::ShapeRefC shape = shapeResult.Get(); // Assume success
    if (!scale_is_unity(scale)) {
        shape = shape->ScaleShape({ scale.x, scale.y, scale.z }).Get();
    }
    return [[SRJPhysicsShape alloc] initWithShapeRef:shape];
}

+ (instancetype)newBoxShapeWithExtents:(simd_float3)extents scale:(simd_float3)scale
{
    const float convexRadius = 0.0f;
    JPH::BoxShapeSettings shapeSettings {
        JPH::Vec3 { extents.x * 0.5f, extents.y * 0.5f, extents.z * 0.5f },
        convexRadius
    };
    shapeSettings.SetEmbedded();
    JPH::ShapeSettings::ShapeResult shapeResult = shapeSettings.Create();
    JPH::ShapeRefC shape = shapeResult.Get(); // Assume success
    if (!scale_is_unity(scale)) {
        shape = shape->ScaleShape({ scale.x, scale.y, scale.z }).Get();
    }
    return [[SRJPhysicsShape alloc] initWithShapeRef:shape];
}

+ (instancetype)newConvexHullShapeWithVertices:(const simd_float3 *)vertices
                                   vertexCount:(NSInteger)vertexCount
                                         scale:(simd_float3)scale
                                         error:(NSError **)error
{
    // JPH::Vec3 has the same size and alignment as simd_float3 (16 bytes),
    // so we treat them as interchangeable instead of taking a copy.
    auto shapeSettings = JPH::ConvexHullShapeSettings {
        reinterpret_cast<const JPH::Vec3 *>(vertices),
        static_cast<int>(vertexCount)
    };
    shapeSettings.SetEmbedded();
    shapeSettings.mMaxConvexRadius = 0.005f;
    JPH::ShapeSettings::ShapeResult shapeResult = shapeSettings.Create();

    if (shapeResult.IsValid()) {
        JPH::ShapeRefC shape = shapeResult.Get();
        if (!scale_is_unity(scale)) {
            JPH::ShapeSettings::ShapeResult scaledShapeResult = shape->ScaleShape({ scale.x, scale.y, scale.z });
            if (scaledShapeResult.IsValid()) {
                shape = scaledShapeResult.Get();
            } else {
                if (error) {
                    NSString *failureReason = [NSString stringWithUTF8String:scaledShapeResult.GetError().c_str()];
                    *error = [NSError errorWithDomain:SRJErrorDomain
                                                 code:-1101
                                             userInfo:@{NSLocalizedFailureReasonErrorKey : failureReason}];
                }
                return nil;
            }
        }
        return [[SRJPhysicsShape alloc] initWithShapeRef:shape];
    } else {
        if (error) {
            NSString *failureReason = [NSString stringWithUTF8String:shapeResult.GetError().c_str()];
            *error = [NSError errorWithDomain:SRJErrorDomain
                                         code:-1101
                                     userInfo:@{NSLocalizedFailureReasonErrorKey : failureReason}];
        }
        return nil;
    }
}

+ (instancetype)newConcavePolyhedronShapeWithVertices:(const simd_float3 *)vertices
                                          vertexCount:(NSInteger)vertexCount
                                              indices:(const uint32_t *)indices
                                           indexCount:(NSInteger)indexCount
                                                scale:(simd_float3)scale
{
    assert(indexCount % 3 == 0);

    auto vertexList = JPH::VertexList();
    vertexList.reserve(vertexCount);
    for (int i = 0; i < vertexCount; ++i) {
        vertexList.emplace_back(vertices[i].x, vertices[i].y, vertices[i].z);
    }
    auto triangleList = JPH::IndexedTriangleList();
    for (int i = 0; i < indexCount; i += 3) {
        triangleList.emplace_back(indices[i], indices[i + 1], indices[i + 2], /*materialIndex = */ 0, /*userData = */ 0);
    }
    auto shapeSettings = JPH::MeshShapeSettings(vertexList, triangleList);
    shapeSettings.SetEmbedded();
    JPH::ShapeSettings::ShapeResult shapeResult = shapeSettings.Create();
    JPH::ShapeRefC shape = shapeResult.Get(); // Assume success
    if (!scale_is_unity(scale)) {
        shape = shape->ScaleShape({ scale.x, scale.y, scale.z }).Get(); // Assume success
    }
    return [[SRJPhysicsShape alloc] initWithShapeRef:shape];
}

- (instancetype)initWithShapeRef:(JPH::ShapeRefC)shapeRef {
    if (self = [super init]) {
        _shapeRef = shapeRef;
    }
    return self;
}

@end

@interface SRJPhysicsBody (/*JoltInternals*/)
@property (nonatomic, assign) JPH::BodyID bodyID;
@property (nonatomic, assign) JPH::BodyInterface *bodyInterface;
- (instancetype)initWithBodyID:(JPH::BodyID)bodyID bodyInterface:(JPH::BodyInterface *)bodyInterface;
@end

@implementation SRJPhysicsBody

- (instancetype)initWithBodyID:(JPH::BodyID)bodyID bodyInterface:(JPH::BodyInterface *)bodyInterface {
    if (self = [super init]) {
        _bodyID = bodyID;
        _bodyInterface = bodyInterface;
    }
    return self;
}

- (void)dealloc {
    if (_bodyID != JPH::BodyID(JPH::BodyID::cInvalidBodyID)) {
        NSLog(@"ERROR: an SRJPhysicsBody was deallocated without first being removed from its physics world");
    }
}

- (SRJRigidBodyTransform)transform {
    JPH::RVec3 position{};
    JPH::Quat rotation{};
    (*_bodyInterface).GetPositionAndRotation(self.bodyID, position, rotation);
    return SRJRigidBodyTransform {
        simd_make_float3(position.GetX(), position.GetY(), position.GetZ()),
        simd_quaternion(rotation.GetX(), rotation.GetY(), rotation.GetZ(), rotation.GetW())
    };
}

- (void)setTransform:(SRJRigidBodyTransform)transform {
    JPH::RVec3 position {
        transform.position.x,
        transform.position.y,
        transform.position.z,
    };
    JPH::Quat rotation {
        transform.orientation.vector.x,
        transform.orientation.vector.y,
        transform.orientation.vector.z,
        transform.orientation.vector.w
    };
    // Update the transform iff it has changed significantly
    (*_bodyInterface).SetPositionAndRotationWhenChanged(self.bodyID, position, rotation,
                                                        JPH::EActivation::Activate);
}

@end

@interface SRJPhysicsWorld () {
    JPH::PhysicsSystem _physicsSystem;
    SRJBroadPhaseLayerInterface _broadphaseLayerInterface;
    SRJObjectVsBroadPhaseLayerFilter _objectVsBroadphaseLayerFilter;
    SRJObjectLayerPairFilter _objectLayerPairFilter;
    SRJBodyActivationListener _bodyActivationListener;
    SRJContactListener _contactListener;
}
@end

@implementation SRJPhysicsWorld

+ (void)initializeJoltPhysics {
    JPH::Trace = TraceImpl;
    JPH_IF_ENABLE_ASSERTS(JPH::AssertFailed = AssertFailedImpl;)

    // Initialization order matters here:
    // Register default allocator -> Instantiate global factory -> Register types -> Instantiate other globals

    JPH::RegisterDefaultAllocator();

    sFactoryInstance = std::make_unique<JPH::Factory>();
    JPH::Factory::sInstance = sFactoryInstance.get();

    JPH::RegisterTypes();

    sTempAllocator = std::make_unique<JPH::TempAllocatorImpl>(10 * 1024 * 1024);
    sJobSystem = std::make_unique<JPH::JobSystemThreadPool>(JPH::cMaxPhysicsJobs,
                                                            JPH::cMaxPhysicsBarriers,
                                                            std::thread::hardware_concurrency() - 1);
}

+ (void)deinitializeJoltPhysics {
    sJobSystem.reset();
    sTempAllocator.reset();

    JPH::UnregisterTypes();

    JPH::Factory::sInstance = nullptr;
    sFactoryInstance.reset();
}

- (instancetype)init {
    if (self = [super init]) {
        _physicsSystem.Init(cMaxBodies, cNumBodyMutexes, cMaxBodyPairs, cMaxContactConstraints,
                            _broadphaseLayerInterface, _objectVsBroadphaseLayerFilter, _objectLayerPairFilter);

        _physicsSystem.SetBodyActivationListener(&_bodyActivationListener);

        JPH::PhysicsSettings physicsSettings{};
        // Tighten default penetration slop, which is a bit too sloppy for our small objects
        physicsSettings.mPenetrationSlop = 0.005f;
        _physicsSystem.SetPhysicsSettings(physicsSettings);

        JPH::Vec3Arg gravity { 0.0f, -9.81f, 0.0f };
        _physicsSystem.SetGravity(gravity);
    }
    return self;
}

- (SRJPhysicsBody *)createAndAddPhysicsBodyWithType:(SRJBodyType)type
                                         properties:(SRJBodyProperties)bodyProperties
                                       physicsShape:(SRJPhysicsShape *)shape
                                   initialTransform:(SRJRigidBodyTransform)transform
{
    JPH::BodyInterface &bodyInterface = _physicsSystem.GetBodyInterface();

    JPH::RVec3 position {
        transform.position.x,
        transform.position.y,
        transform.position.z,
    };
    JPH::Quat rotation {
        transform.orientation.vector.x,
        transform.orientation.vector.y,
        transform.orientation.vector.z,
        transform.orientation.vector.w
    };

    JPH::EMotionType motionType;
    JPH::ObjectLayer objectLayer;
    switch (type) {
        case SRJBodyTypeStatic:
            motionType = JPH::EMotionType::Static;
            objectLayer = Layers::NON_MOVING;
            break;
        case SRJBodyTypeDynamic:
            motionType = JPH::EMotionType::Dynamic;
            objectLayer = Layers::MOVING;
            break;
        case SRJBodyTypeKinematic:
            motionType = JPH::EMotionType::Kinematic;
            objectLayer = Layers::MOVING;
            break;
    }

    JPH::BodyCreationSettings bodySettings { shape.shapeRef, position, rotation, motionType, objectLayer };
    // Allow dynamic bodies to become kinematic during, e.g., user interaction
    bodySettings.mAllowDynamicOrKinematic = (type == SRJBodyTypeDynamic);

    bodySettings.mFriction = bodyProperties.friction;
    bodySettings.mRestitution = bodyProperties.restitution;
    bodySettings.mLinearDamping = 0.05f;
    bodySettings.mAngularDamping = 0.05f;
    bodySettings.mGravityFactor = bodyProperties.isAffectedByGravity ? 1.0f : 0.0f;
    if (type != SRJBodyTypeStatic && (bodyProperties.mass != 0.0f)) {
        bodySettings.mOverrideMassProperties = JPH::EOverrideMassProperties::CalculateInertia;
        bodySettings.mMassPropertiesOverride = JPH::MassProperties{ .mMass = bodyProperties.mass };
    }
    JPH::Body *body = bodyInterface.CreateBody(bodySettings);

    auto activationFlag = (type == SRJBodyTypeStatic) ? JPH::EActivation::DontActivate : JPH::EActivation::Activate;
    bodyInterface.AddBody(body->GetID(), activationFlag);

    //_physicsSystem.OptimizeBroadPhase();

    SRJPhysicsBody *facadeBody = [[SRJPhysicsBody alloc] initWithBodyID:body->GetID() bodyInterface:&bodyInterface];
    bodyInterface.SetUserData(body->GetID(), reinterpret_cast<uint64_t>((__bridge void *)facadeBody));
    return facadeBody;
}

- (void)removePhysicsBody:(SRJPhysicsBody *)physicsBody {
    JPH::BodyInterface &bodyInterface = _physicsSystem.GetBodyInterface();
    bodyInterface.RemoveBody(physicsBody.bodyID);
    bodyInterface.DestroyBody(physicsBody.bodyID);
    physicsBody.bodyID = JPH::BodyID { JPH::BodyID::cInvalidBodyID };
}

- (void)updateWithTimestep:(NSTimeInterval)timestep {
    // TODO: Select number of collision steps to take based on optimal simulation timestep and provided timestep
    const int cCollisionSteps = 6;
    _physicsSystem.Update(timestep, cCollisionSteps, sTempAllocator.get(), sJobSystem.get());
}

- (NSArray<SRJHitTestResult *> *)hitTestWithSegmentFromPoint:(simd_float3)origin toPoint:(simd_float3)dest {
    struct HitTestResultCollector : JPH::CastRayCollector {
        std::vector<JPH::RayCastResult> hits;

        void AddHit(const JPH::RayCastResult &result) {
            hits.push_back(result);
        }
    };

    const JPH::NarrowPhaseQuery &query = _physicsSystem.GetNarrowPhaseQuery();
    JPH::Vec3 from { origin.x, origin.y, origin.z };
    JPH::Vec3 to { dest.x, dest.y, dest.z };
    JPH::Vec3 dir = to - from;
    const JPH::RRayCast ray { from, dir };
    const JPH::RayCastSettings settings {};
    HitTestResultCollector collector {};
    query.CastRay(ray, settings, collector);

    NSMutableArray *results = [NSMutableArray array];
    for (int i = 0; i < collector.hits.size(); ++i) {
        const JPH::RayCastResult &hit = collector.hits[i];
        auto bodyUserData = _physicsSystem.GetBodyInterface().GetUserData(hit.mBodyID);
        SRJPhysicsBody *body = (__bridge SRJPhysicsBody *)reinterpret_cast<void *>(bodyUserData);
        JPH::Vec3 hitPosition = ray.GetPointOnRay(hit.mFraction);
        SRJHitTestResult *result = [SRJHitTestResult new];
        result.body = body;
        result.position = simd_make_float3(hitPosition.GetX(), hitPosition.GetY(), hitPosition.GetZ());
        result.distance = simd_length(result.position - origin);
        [results addObject:result];
    }
    return [results copy];
}

@end
