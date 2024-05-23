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

enum ResourceError : Error {
    case allocationFailure
    case imageLoadFailure
    case invalidImageFormat
    case invalidState
}

class MetalContext : @unchecked Sendable {
    nonisolated(unsafe) static var shared = MetalContext()

    #if os(visionOS)
    let preferredColorPixelFormat = MTLPixelFormat.rgba16Float
    #else
    let preferredColorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
    #endif

    let preferredDepthPixelFormat = MTLPixelFormat.depth32Float
    let preferredRasterSampleCount: Int

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let defaultLibrary: MTLLibrary?

    init(device: MTLDevice? = nil, commandQueue: MTLCommandQueue? = nil) {
        guard let metalDevice = device ?? MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported")
        }
        guard let metalCommandQueue = commandQueue ?? metalDevice.makeCommandQueue() else {
            fatalError()
        }
        assert(metalCommandQueue.device.isEqual(metalDevice))

        self.device = metalDevice
        self.commandQueue = metalCommandQueue
        self.defaultLibrary = metalDevice.makeDefaultLibrary()

        #if targetEnvironment(simulator)
        // The Metal API validation layer on Vision Pro simulator claims not to be able
        // to resolve Depth32 MSAA targets (it lies), so force MSAA off there.
        let candidateSampleCounts = [1]
        #else
        let candidateSampleCounts = [16, 8, 5, 4, 2, 1]
        #endif
        let supportedSampleCounts = candidateSampleCounts.filter { metalDevice.supportsTextureSampleCount($0) }
        preferredRasterSampleCount = supportedSampleCounts.first ?? 1
        print("Supported raster sample counts: \(supportedSampleCounts). Selected \(preferredRasterSampleCount).")
    }
}
