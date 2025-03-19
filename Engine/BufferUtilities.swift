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
import ModelIO

// A buffer view is a simple abstraction over a Metal buffer that
// holds a strong reference to its buffer and an optional offset.
class BufferView {
    let buffer: MTLBuffer
    let offset: Int

    init(buffer: MTLBuffer, offset: Int = 0) {
        self.buffer = buffer
        self.offset = offset
    }
}

// A ring buffer is a fixed-size buffer that can be used for small
// temporary allocations. When the allocation offset of the buffer
// exceeds its size, it "wraps" around to zero. Allocating an object
// larger than the buffer itself is an error. Since this type does
// not do any lifetime management, any objects copied into it should
// be POD.
class RingBuffer {
    let buffer: MTLBuffer
    let bufferLength: Int
    let minimumAlignment: Int

    private var nextOffset = 0

    init(device: MTLDevice, 
         length: Int,
         options: MTLResourceOptions = .storageModeShared,
         label: String? = nil) throws
    {
        guard let buffer = device.makeBuffer(length: length, options: options) else {
            throw ResourceError.allocationFailure
        }
        buffer.label = label
        self.buffer = buffer
        self.bufferLength = length
        self.minimumAlignment = device.minimumConstantBufferOffsetAlignment
    }

    func alloc(length: Int, alignment: Int) -> (UnsafeMutableRawPointer, Int) {
        precondition(length <= bufferLength)
        let effectiveAlignment = max(minimumAlignment, alignment)
        var offset = alignUp(nextOffset, alignment: effectiveAlignment)
        if offset + length >= bufferLength {
            offset = 0
        }
        nextOffset = offset + length
        return (buffer.contents().advanced(by: offset), offset)
    }

    func copy<T>(_ value: UnsafeMutablePointer<T>) -> Int {
        precondition(_isPOD(T.self))
        let layout = MemoryLayout<T>.self
        let (ptr, offset) = alloc(length: layout.size, alignment: layout.alignment)
        ptr.copyMemory(from: value, byteCount: layout.size)
        return offset
    }

    func copy<T>(_ array: [T]) -> Int {
        precondition(_isPOD(T.self))
        if array.count == 0 { return 0 }
        let layout = MemoryLayout<T>.self
        let regionLength = ((array.count - 1) * layout.stride) + layout.size
        let (ptr, offset) = alloc(length: regionLength, alignment: layout.alignment)
        array.withUnsafeBytes { elementsPtr in
            guard let elementPtr = elementsPtr.baseAddress else { return }
            ptr.copyMemory(from: elementPtr, byteCount: regionLength)
        }
        return offset
    }
}

// A strided view is a sequence type that affords random access to an underlying
// data buffer containing homogeneous elements that may be strided (i.e. not contiguous
// in memory). It is the responsibility of a view's creator to ensure that the
// underlying buffer lives at least as long as any views created on it.
struct StridedView<Element> : Sequence {
    struct Iterator : Swift.IteratorProtocol {
        private let storage: StridedView<Element>
        private var currentIndex = 0

        init(_ storage: StridedView<Element>) {
            self.storage = storage
        }

        mutating func next() -> Element? {
            if currentIndex < storage.count {
                let index = currentIndex
                currentIndex += 1
                return storage[index]
            } else {
                return nil
            }
        }
    }

    let basePointer: UnsafeRawPointer
    let offset: Int
    let stride: Int
    let count: Int

    init(_ basePointer: UnsafeRawPointer, offset: Int, stride: Int, count: Int) {
        precondition(_isPOD(Element.self))
        self.basePointer = basePointer
        self.offset = offset
        self.stride = stride
        self.count = count
    }

    var underestimatedCount: Int {
        return count
    }

    func makeIterator() -> Iterator {
        return Iterator(self)
    }

    func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R? {
        if stride == MemoryLayout<Element>.stride {
            let elementPtr = basePointer.advanced(by: offset).assumingMemoryBound(to: Element.self)
            let elementBufferPtr = UnsafeBufferPointer(start: elementPtr, count: count)
            return try body(elementBufferPtr)
        }
        return nil
    }

    subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count)
            let elementPtr = basePointer.advanced(by: offset + stride * index).assumingMemoryBound(to: Element.self)
            return elementPtr.pointee
        }
    }
}

// A small utility for determining the minimum alignment of offsets
// of buffers bound with a command encoder.
extension MTLDevice {
    var minimumConstantBufferOffsetAlignment: Int {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif

        if supportsFamily(.apple2) && !isSimulator {
            // A8 and later (and Apple Silicon) support 4 byte alignment
            return 4
        }  else if supportsFamily(.mac2) && !isSimulator {
            // Recent Macs support 32 byte alignment
            return 32
        } else {
            // Worst-case scenario for simulator, old Nvidia Macs, etc.
            return 256
        }
    }
}
