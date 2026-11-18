//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import CDispatch
import _SwiftDispatchOverlayShims

// This file contains declarations that are provided by the
// importer via Dispatch.apinote when the platform has Objective-C support

public func dispatchMain() -> Never {
	CDispatch.dispatch_main()
}

// The armv7 slice is built against the C libdispatch headers, where dispatch objects are plain
// pointers and the overlay owns their reference counts. The armv7s/arm64 slices import the SDK's
// Objective-C object types, which ARC retains and releases itself: a manual dispatch_release on top
// of that over-releases every queue/group/semaphore (observed: objc_release crash in
// DispatchGroup.deinit on iOS 10). So manual counting exists only in the slice that needs it.
@inline(__always) internal func _legacyDispatchRetain(_ object: dispatch_object_t) {
#if !LEGACY_ARC_DISPATCH_OBJECTS
	_swift_dispatch_retain(object)
#endif
}
@inline(__always) internal func _legacyDispatchRelease(_ object: dispatch_object_t) {
#if !LEGACY_ARC_DISPATCH_OBJECTS
	_swift_dispatch_release(object)
#endif
}

public class DispatchObject {

	internal func wrapped() -> dispatch_object_t {
		fatalError("should be overriden in subclass")
	}

	public func setTarget(queue:DispatchQueue) {
		dispatch_set_target_queue(wrapped(), queue.__wrapped)
	}

	public func activate() {
		// dispatch_activate is iOS 10+. Before that nothing can be created inactive
		// (dispatch_queue_attr_make_initially_inactive is also iOS 10+), so activating is a no-op.
		if #available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
			dispatch_activate(wrapped())
		}
	}

	public func suspend() {
		dispatch_suspend(wrapped())
	}

	public func resume() {
		dispatch_resume(wrapped())
	}
}


public class DispatchGroup : DispatchObject {
	internal let __wrapped:dispatch_group_t;

	final internal override func wrapped() -> dispatch_object_t {
		return unsafeBitCast(__wrapped, to: dispatch_object_t.self)
	}

	public override init() {
		__wrapped = dispatch_group_create()
	}

	// Legacy bridging: wraps a handle without taking a reference (see _convertRawToDispatchGroup).
	internal init(__raw: dispatch_group_t) {
		__wrapped = __raw
	}

	deinit {
		_legacyDispatchRelease(wrapped())
	}

	public func enter() {
		dispatch_group_enter(__wrapped)
	}

	public func leave() {
		dispatch_group_leave(__wrapped)
	}
}

public class DispatchSemaphore : DispatchObject {
	internal let __wrapped: dispatch_semaphore_t;

	// Legacy bridging: wraps a handle without taking a reference (see _convertRawToDispatchSemaphore).
	internal init(__raw: dispatch_semaphore_t) {
		__wrapped = __raw
	}

	final internal override func wrapped() -> dispatch_object_t {
		return unsafeBitCast(__wrapped, to: dispatch_object_t.self)
	}

	public init(value: Int) {
		__wrapped = dispatch_semaphore_create(Int(value))
	}

	deinit {
		_legacyDispatchRelease(wrapped())
	}
}

public class DispatchIO : DispatchObject {
	internal let __wrapped:dispatch_io_t

	// Legacy bridging: wraps a handle without taking a reference (see _convertRawToDispatchIO).
	internal init(__raw: dispatch_io_t) {
		__wrapped = __raw
	}

	final internal override func wrapped() -> dispatch_object_t {
		return unsafeBitCast(__wrapped, to: dispatch_object_t.self)
	}

	internal init(__type: UInt, fd: Int32, queue: DispatchQueue,
				  handler: @escaping (_ error: Int32) -> Void) {
		__wrapped = dispatch_io_create(dispatch_io_type_t(__type), dispatch_fd_t(fd), queue.__wrapped, handler)
	}

	internal init(__type: UInt, path: UnsafePointer<Int8>, oflag: Int32,
				  mode: mode_t, queue: DispatchQueue, handler: @escaping (_ error: Int32) -> Void) {
		__wrapped = dispatch_io_create_with_path(dispatch_io_type_t(__type), path, oflag, mode, queue.__wrapped, handler)
	}

	internal init(__type: UInt, io: DispatchIO,
				  queue: DispatchQueue, handler: @escaping (_ error: Int32) -> Void) {
		__wrapped = dispatch_io_create_with_io(dispatch_io_type_t(__type), io.__wrapped, queue.__wrapped, handler)
	}

	deinit {
		_legacyDispatchRelease(wrapped())
	}

	public func barrier(execute: @escaping () -> ()) {
		dispatch_io_barrier(self.__wrapped, execute)
	}

	public var fileDescriptor: Int32 {
		return Int32(dispatch_io_get_descriptor(__wrapped))
	}

	public func setLimit(highWater: Int) {
		dispatch_io_set_high_water(__wrapped, highWater)
	}

	public func setLimit(lowWater: Int) {
		dispatch_io_set_low_water(__wrapped, lowWater)
	}
}

public class DispatchQueue : DispatchObject {
	internal let __wrapped:dispatch_queue_t;

	final internal override func wrapped() -> dispatch_object_t {
		return unsafeBitCast(__wrapped, to: dispatch_object_t.self)
	}

	internal init(__label: String, attr: dispatch_queue_attr_t?) {
		__wrapped = dispatch_queue_create(__label, attr)
	}

	internal init(__label: String, attr:  dispatch_queue_attr_t?, queue: DispatchQueue?) {
		if #available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
			__wrapped = dispatch_queue_create_with_target(__label, attr, queue?.__wrapped)
		} else {
			// Pre-iOS 10: create, then retarget (what dispatch_queue_create_with_target does atomically).
			let q = dispatch_queue_create(__label, attr)
			if let target = queue {
				dispatch_set_target_queue(unsafeBitCast(q, to: dispatch_object_t.self), target.__wrapped)
			}
			__wrapped = q
		}
	}

	internal init(queue:dispatch_queue_t) {
		__wrapped = queue
	}

	deinit {
		_legacyDispatchRelease(wrapped())
	}

	public func sync(execute workItem: ()->()) {
		dispatch_sync(self.__wrapped, workItem)
	}
}

public class DispatchSource : DispatchObject,
	DispatchSourceProtocol,	DispatchSourceRead,
	DispatchSourceSignal, DispatchSourceTimer,
	DispatchSourceUserDataAdd, DispatchSourceUserDataOr,
	DispatchSourceUserDataReplace, DispatchSourceWrite {
	internal let __wrapped:dispatch_source_t

	final internal override func wrapped() -> dispatch_object_t {
		return unsafeBitCast(__wrapped, to: dispatch_object_t.self)
	}

	internal init(source:dispatch_source_t) {
		__wrapped = source
	}

	deinit {
		_legacyDispatchRelease(wrapped())
	}
}

#if HAVE_MACH
extension DispatchSource : DispatchSourceMachSend,
	DispatchSourceMachReceive, DispatchSourceMemoryPressure {
}
#endif

#if !os(Linux) && !os(Android) && !os(Windows)
extension DispatchSource : DispatchSourceProcess,
	DispatchSourceFileSystemObject {
}
#endif

internal class __DispatchData : DispatchObject {
	internal let __wrapped:dispatch_data_t

	final internal override func wrapped() -> dispatch_object_t {
		return unsafeBitCast(__wrapped, to: dispatch_object_t.self)
	}

	internal init(data:dispatch_data_t, owned:Bool) {
		__wrapped = data
		if !owned {
			_legacyDispatchRetain(unsafeBitCast(data, to: dispatch_object_t.self))
		}
	}

	deinit {
		_legacyDispatchRelease(wrapped())
	}
}

public typealias DispatchSourceHandler = @convention(block) () -> Void

public protocol DispatchSourceProtocol {
	func setEventHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?)

	@available(macOS 10.10, iOS 8.0, *)
	func setEventHandler(handler: DispatchWorkItem)

	func setCancelHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?)

	@available(macOS 10.10, iOS 8.0, *)
	func setCancelHandler(handler: DispatchWorkItem)

	func setRegistrationHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?)

	@available(macOS 10.10, iOS 8.0, *)
	func setRegistrationHandler(handler: DispatchWorkItem)

	func cancel()

	func resume()

	func suspend()

	var handle: UInt { get }

	var mask: UInt { get }

	var data: UInt { get }

	var isCancelled: Bool { get }
}

public protocol DispatchSourceUserDataAdd : DispatchSourceProtocol {
	func add(data: UInt)
}

public protocol DispatchSourceUserDataOr : DispatchSourceProtocol {
	func or(data: UInt)
}

public protocol DispatchSourceUserDataReplace : DispatchSourceProtocol {
	func replace(data: UInt)
}

#if HAVE_MACH
public protocol DispatchSourceMachSend : DispatchSourceProtocol {
	public var handle: mach_port_t { get }

	public var data: DispatchSource.MachSendEvent { get }

	public var mask: DispatchSource.MachSendEvent { get }
}
#endif

#if HAVE_MACH
public protocol DispatchSourceMachReceive : DispatchSourceProtocol {
	var handle: mach_port_t { get }
}
#endif

#if HAVE_MACH
public protocol DispatchSourceMemoryPressure : DispatchSourceProtocol {
	public var data: DispatchSource.MemoryPressureEvent { get }

	public var mask: DispatchSource.MemoryPressureEvent { get }
}
#endif

#if !os(Linux) && !os(Android) && !os(Windows)
public protocol DispatchSourceProcess : DispatchSourceProtocol {
	var handle: pid_t { get }

	var data: DispatchSource.ProcessEvent { get }

	var mask: DispatchSource.ProcessEvent { get }
}
#endif

public protocol DispatchSourceRead : DispatchSourceProtocol {
}

public protocol DispatchSourceSignal : DispatchSourceProtocol {
}

public protocol DispatchSourceTimer : DispatchSourceProtocol {
	func scheduleOneshot(deadline: DispatchTime, leeway: DispatchTimeInterval)

	func scheduleOneshot(wallDeadline: DispatchWallTime, leeway: DispatchTimeInterval)

	func scheduleRepeating(deadline: DispatchTime, interval: DispatchTimeInterval, leeway: DispatchTimeInterval)

	func scheduleRepeating(deadline: DispatchTime, interval: Double, leeway: DispatchTimeInterval)

	func scheduleRepeating(wallDeadline: DispatchWallTime, interval: DispatchTimeInterval, leeway: DispatchTimeInterval)

	func scheduleRepeating(wallDeadline: DispatchWallTime, interval: Double, leeway: DispatchTimeInterval)
}

#if !os(Linux) && !os(Android) && !os(Windows)
public protocol DispatchSourceFileSystemObject : DispatchSourceProtocol {
	var handle: Int32 { get }

	var data: DispatchSource.FileSystemEvent { get }

	var mask: DispatchSource.FileSystemEvent { get }
}
#endif

public protocol DispatchSourceWrite : DispatchSourceProtocol {
}


internal enum _OSQoSClass : UInt32  {
	case QOS_CLASS_USER_INTERACTIVE = 0x21
	case QOS_CLASS_USER_INITIATED = 0x19
	case QOS_CLASS_DEFAULT = 0x15
	case QOS_CLASS_UTILITY = 0x11
	case QOS_CLASS_BACKGROUND = 0x09
	case QOS_CLASS_UNSPECIFIED = 0x00

	internal init?(qosClass:dispatch_qos_class_t) {
		switch qosClass {
		case 0x21: self = .QOS_CLASS_USER_INTERACTIVE
		case 0x19: self = .QOS_CLASS_USER_INITIATED
		case 0x15: self = .QOS_CLASS_DEFAULT
		case 0x11: self = .QOS_CLASS_UTILITY
		case 0x09: self = .QOS_CLASS_BACKGROUND
		case 0x00: self = .QOS_CLASS_UNSPECIFIED
		default: return nil
		}
	}
}

// Legacy toolchain bridging entry points. With -enable-legacy-ios5-runtime the compiler imports the
// SDK's dispatch_{queue,group,semaphore,source,io}_t in C and Objective-C signatures as these classes
// and calls these functions at the boundary (include/swift/ClangImporter/LegacyDispatchBridging.h).
// The raw type is this slice's: an OpaquePointer on armv7 (iOS 5 has plain C handles), the ARC-managed
// OS_dispatch_* class on armv7s/arm64.
//
// On armv7s/arm64 the raw side is typed AnyObject: the overlay sees the dispatch classes through
// corelibs' headers (OS_dispatch_queue), clients through the SDK's, which name the same classes
// DispatchQueue and so on for Swift, so a signature naming OS_dispatch_queue would not deserialize
// in a client. AnyObject is the same object pointer and keeps ARC ownership.
//
// To raw: the handle the object owns, borrowed for the call (the object outlives the call).
// From raw: a new wrapper holding its own reference (retained here on armv7, by ARC elsewhere), so
// it stays valid after the Objective-C side lets go. Wrappers are not unique per handle: compare the
// handles, not the wrappers, for identity.
#if LEGACY_ARC_DISPATCH_OBJECTS
public func _convertDispatchQueueToRaw(_ object: DispatchQueue) -> AnyObject {
	return object.__wrapped
}
public func _convertRawToDispatchQueue(_ handle: AnyObject) -> DispatchQueue {
	let raw = unsafeDowncast(handle, to: dispatch_queue_t.self)
	return DispatchQueue(queue: raw)
}
public func _convertDispatchGroupToRaw(_ object: DispatchGroup) -> AnyObject {
	return object.__wrapped
}
public func _convertRawToDispatchGroup(_ handle: AnyObject) -> DispatchGroup {
	let raw = unsafeDowncast(handle, to: dispatch_group_t.self)
	return DispatchGroup(__raw: raw)
}
public func _convertDispatchSemaphoreToRaw(_ object: DispatchSemaphore) -> AnyObject {
	return object.__wrapped
}
public func _convertRawToDispatchSemaphore(_ handle: AnyObject) -> DispatchSemaphore {
	let raw = unsafeDowncast(handle, to: dispatch_semaphore_t.self)
	return DispatchSemaphore(__raw: raw)
}
public func _convertDispatchSourceToRaw(_ object: DispatchSource) -> AnyObject {
	return object.__wrapped
}
public func _convertRawToDispatchSource(_ handle: AnyObject) -> DispatchSource {
	let raw = unsafeDowncast(handle, to: dispatch_source_t.self)
	return DispatchSource(source: raw)
}
public func _convertDispatchIOToRaw(_ object: DispatchIO) -> AnyObject {
	return object.__wrapped
}
public func _convertRawToDispatchIO(_ handle: AnyObject) -> DispatchIO {
	let raw = unsafeDowncast(handle, to: dispatch_io_t.self)
	return DispatchIO(__raw: raw)
}
#else
public func _convertDispatchQueueToRaw(_ object: DispatchQueue) -> dispatch_queue_t {
	return object.__wrapped
}
public func _convertRawToDispatchQueue(_ raw: dispatch_queue_t) -> DispatchQueue {
	let object = DispatchQueue(queue: raw)
	_legacyDispatchRetain(object.wrapped())
	return object
}
public func _convertDispatchGroupToRaw(_ object: DispatchGroup) -> dispatch_group_t {
	return object.__wrapped
}
public func _convertRawToDispatchGroup(_ raw: dispatch_group_t) -> DispatchGroup {
	let object = DispatchGroup(__raw: raw)
	_legacyDispatchRetain(object.wrapped())
	return object
}
public func _convertDispatchSemaphoreToRaw(_ object: DispatchSemaphore) -> dispatch_semaphore_t {
	return object.__wrapped
}
public func _convertRawToDispatchSemaphore(_ raw: dispatch_semaphore_t) -> DispatchSemaphore {
	let object = DispatchSemaphore(__raw: raw)
	_legacyDispatchRetain(object.wrapped())
	return object
}
public func _convertDispatchSourceToRaw(_ object: DispatchSource) -> dispatch_source_t {
	return object.__wrapped
}
public func _convertRawToDispatchSource(_ raw: dispatch_source_t) -> DispatchSource {
	let object = DispatchSource(source: raw)
	_legacyDispatchRetain(object.wrapped())
	return object
}
public func _convertDispatchIOToRaw(_ object: DispatchIO) -> dispatch_io_t {
	return object.__wrapped
}
public func _convertRawToDispatchIO(_ raw: dispatch_io_t) -> DispatchIO {
	let object = DispatchIO(__raw: raw)
	_legacyDispatchRetain(object.wrapped())
	return object
}
#endif
