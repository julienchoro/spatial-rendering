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
import simd

struct HitTestResult {
    let entity: Entity?
    let worldPosition: simd_float3
}

protocol PhysicsBridge {
    func addEntity(_ entity: Entity)
    func removeEntity(_ entity: Entity)
    func update(entities: [Entity], timestep: TimeInterval)
    func hitTestWithSegment(from: simd_float3, to: simd_float3) -> [HitTestResult]
}
