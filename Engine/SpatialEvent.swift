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

import SwiftUI
import Spatial

public enum Event {
    case worldAnchor(WorldAnchor, AnchorEvent)
    case meshAnchor(MeshAnchor, AnchorEvent)
    case planeAnchor(PlaneAnchor, AnchorEvent)
    case handAnchor(HandAnchor, AnchorEvent)
    case environmentLightAnchor(EnvironmentLightAnchor, AnchorEvent)
    case spatialInput(SpatialInputEvent)
}

public struct SpatialInputEvent : Identifiable, Hashable, Sendable {
	public typealias ID = UUID

	public var id: ID

	public enum Kind : Hashable, Sendable {
		case touch
		case directPinch
		case indirectPinch
		case pointer
	}

	public enum Phase : Hashable, Sendable {
		case active
		case ended
		case cancelled
	}

	public struct InputDevicePose : Hashable, Sendable {
		public var altitude: Angle2D
		public var azimuth: Angle2D
		public var pose3D: Pose3D
	}

	public var timestamp: TimeInterval
	public var kind: SpatialInputEvent.Kind
	public var location: CGPoint
	public var phase: SpatialInputEvent.Phase
	public var inputDevicePose: SpatialInputEvent.InputDevicePose?
	public var location3D: Point3D
	public var selectionRay: Ray3D?
	public var handedness: Handedness
}

extension SpatialInputEvent {
	init(_ event: SpatialEventCollection.Event) {
		self.id = UUID()
		self.timestamp = event.timestamp
		self.kind = switch event.kind {
			case .touch: .touch
			case .directPinch: .directPinch
			case .indirectPinch: .indirectPinch
			case .pointer: .pointer
			@unknown default: fatalError()
		}
		self.location = event.location
		self.phase = switch event.phase {
			case .active: .active
			case .ended: .ended
			case .cancelled: .cancelled
			@unknown default: fatalError()
		}
		#if os(visionOS)
		if let pose = event.inputDevicePose {
			self.inputDevicePose = InputDevicePose(altitude: Angle2D(radians: pose.altitude.radians),
												   azimuth: Angle2D(radians: pose.azimuth.radians),
												   pose3D: pose.pose3D)
		}
		self.location3D = event.location3D
		self.selectionRay = event.selectionRay
		self.handedness = switch event.chirality {
			case .left: .left
			case .right: .right
			case .none: .none
		}
		#else
		self.location3D = .zero
		self.handedness = .none
		#endif
	}
}
