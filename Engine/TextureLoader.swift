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
import CoreGraphics
import Metal
import ModelIO

class TextureLoader {
    enum Option {
        case sRGB
        case flipVertically
        case generateMipmaps
        case storageMode
        case usageMode
    }

    let context: MetalContext

    init(context: MetalContext) {
        self.context = context
    }

    func makeTexture(mdlTexture: MDLTexture, options: [Option: Any]?) throws -> MTLTexture {
        let device = context.device

        let bytesPerPixel = 4
        var pixelFormat = MTLPixelFormat.rgba8Unorm

        if let srgbOption = options?[.sRGB] as? NSNumber {
            if srgbOption.boolValue {
                pixelFormat = MTLPixelFormat.rgba8Unorm_srgb
            }
        }

        var storageMode = MTLStorageMode.shared
        #if os(macOS)
        if !device.hasUnifiedMemory {
            storageMode = MTLStorageMode.managed
        }
        #endif
        if let storageModeOption = options?[.storageMode] as? NSNumber {
            if let preferredStorageMode = MTLStorageMode(rawValue: storageModeOption.uintValue) {
                storageMode = preferredStorageMode
            }
        }

        var usageMode = MTLTextureUsage.shaderRead
        if let usageModeOption = options?[.usageMode] as? NSNumber {
            let preferredUsageMode = MTLTextureUsage(rawValue: usageModeOption.uintValue)
            usageMode = preferredUsageMode
        }

        var wantsMipmaps = false
        if let mipmapOption = options?[.generateMipmaps] as? NSNumber {
            wantsMipmaps = mipmapOption.boolValue
        }

        var flipVertically = false
        if let flipOption = options?[.flipVertically] as? NSNumber {
            flipVertically = flipOption.boolValue
        }

        let getImageData: () -> Data? = {
            if flipVertically {
                return mdlTexture.texelDataWithBottomLeftOrigin(atMipLevel: 0, create: true)
            } else {
                return mdlTexture.texelDataWithTopLeftOrigin(atMipLevel: 0, create: true)
            }
        }

        guard let data = getImageData() else {
            throw ResourceError.imageLoadFailure
        }

        let width = Int(mdlTexture.dimensions.x)
        let height = Int(mdlTexture.dimensions.y)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                                                                         width: width,
                                                                         height: height,
                                                                         mipmapped: wantsMipmaps)
        textureDescriptor.usage = usageMode
        textureDescriptor.storageMode = storageMode

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw ResourceError.allocationFailure
        }

        let bytesPerRow = width * bytesPerPixel

        let region = MTLRegionMake2D(0, 0, width, height)
        data.withUnsafeBytes { imageBytes in
            texture.replace(region: region, mipmapLevel: 0, withBytes: imageBytes.baseAddress!, bytesPerRow: bytesPerRow)
        }

        if wantsMipmaps {
            let commandQueue = context.commandQueue
            if let commandBuffer = commandQueue.makeCommandBuffer() {
                if let mipmapEncoder = commandBuffer.makeBlitCommandEncoder() {
                    mipmapEncoder.generateMipmaps(for: texture)
                    mipmapEncoder.endEncoding()
                }
                commandBuffer.commit()
            }
        }

        return texture
    }
}
