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
import Darwin

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
		CDispatch.dispatch_set_target_queue(wrapped(), queue.__wrapped)
	}

	public func activate() {
		// dispatch_activate is iOS 10+. Before that nothing can be created inactive
		// (dispatch_queue_attr_make_initially_inactive is also iOS 10+), so activating is a no-op.
		if #available(macOS 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
			CDispatch.dispatch_activate(wrapped())
		}
	}

	public func suspend() {
		CDispatch.dispatch_suspend(wrapped())
	}

	public func resume() {
		CDispatch.dispatch_resume(wrapped())
	}
}


public class DispatchGroup : DispatchObject {
	internal let __wrapped:dispatch_group_t;

	final internal override func wrapped() -> dispatch_object_t {
		return unsafeBitCast(__wrapped, to: dispatch_object_t.self)
	}

	public override init() {
		__wrapped = CDispatch.dispatch_group_create()
	}

	// Legacy bridging: wraps a handle without taking a reference (see _convertRawToDispatchGroup).
	internal init(__raw: dispatch_group_t) {
		__wrapped = __raw
	}

	deinit {
		_legacyDispatchRelease(wrapped())
	}

	public func enter() {
		CDispatch.dispatch_group_enter(__wrapped)
	}

	public func leave() {
		CDispatch.dispatch_group_leave(__wrapped)
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
		__wrapped = CDispatch.dispatch_semaphore_create(Int(value))
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
				CDispatch.dispatch_set_target_queue(unsafeBitCast(q, to: dispatch_object_t.self), target.__wrapped)
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
		CDispatch.dispatch_sync(self.__wrapped, workItem)
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
// it stays valid after the Objective-C side lets go.
//
// Identity: one wrapper per handle while any wrapper for it is alive (_LegacyDispatchWrappers), so,
// as in stock Swift where the wrapper is the dispatch object itself, a queue read back from
// Objective-C is === the DispatchQueue that was stored, and DispatchQueue.main === DispatchQueue.main.

/// Live wrapper per libdispatch handle (weakly held). Entries for wrappers that have gone are
/// dropped lazily; a handle's address can only be reused once every wrapper owning it is gone.
internal final class _LegacyDispatchWrappers {
	private final class Entry {
		weak var object: DispatchObject?
		init(_ object: DispatchObject) { self.object = object }
	}
	private let lock: UnsafeMutablePointer<pthread_mutex_t>
	private var entries: [UnsafeRawPointer: Entry] = [:]
	private var purgeAt = 64

	static let shared = _LegacyDispatchWrappers()

	private init() {
		lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
		pthread_mutex_init(lock, nil)
	}

	static func key<Handle>(_ handle: Handle) -> UnsafeRawPointer {
		return unsafeBitCast(handle, to: UnsafeRawPointer.self)
	}

	/// The live wrapper for the handle, or `make()`'s new one, recorded.
	func unique<Wrapper: DispatchObject>(_ key: UnsafeRawPointer, _ make: () -> Wrapper) -> Wrapper {
		pthread_mutex_lock(lock)
		defer { pthread_mutex_unlock(lock) }
		// A live wrapper for this handle is of the handle's class (handles are not shared between
		// classes, and an address is reused only after every wrapper owning it is gone).
		if let existing = entries[key]?.object { return unsafeDowncast(existing, to: Wrapper.self) }
		let object = make()
		record(key, object)
		return object
	}

	/// Records a wrapper the overlay created (DispatchQueue(label:) and so on) as the handle's.
	func register(_ key: UnsafeRawPointer, _ object: DispatchObject) {
		pthread_mutex_lock(lock)
		defer { pthread_mutex_unlock(lock) }
		if entries[key]?.object == nil { record(key, object) }
	}

	private func record(_ key: UnsafeRawPointer, _ object: DispatchObject) {
		entries[key] = Entry(object)
		if entries.count >= purgeAt {
			entries = entries.filter { $0.value.object != nil }
			purgeAt = Swift.max(64, entries.count * 2)
		}
	}
}


#if LEGACY_ARC_DISPATCH_OBJECTS
public func _convertDispatchQueueToRaw(_ object: DispatchQueue) -> AnyObject {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchQueue(_ handle: AnyObject) -> DispatchQueue {
	let raw = unsafeDowncast(handle, to: dispatch_queue_t.self)
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) { DispatchQueue(queue: raw) }
}
public func _convertDispatchGroupToRaw(_ object: DispatchGroup) -> AnyObject {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchGroup(_ handle: AnyObject) -> DispatchGroup {
	let raw = unsafeDowncast(handle, to: dispatch_group_t.self)
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) { DispatchGroup(__raw: raw) }
}
public func _convertDispatchSemaphoreToRaw(_ object: DispatchSemaphore) -> AnyObject {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchSemaphore(_ handle: AnyObject) -> DispatchSemaphore {
	let raw = unsafeDowncast(handle, to: dispatch_semaphore_t.self)
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) { DispatchSemaphore(__raw: raw) }
}
public func _convertDispatchSourceToRaw(_ object: DispatchSource) -> AnyObject {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchSource(_ handle: AnyObject) -> DispatchSource {
	let raw = unsafeDowncast(handle, to: dispatch_source_t.self)
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) { DispatchSource(source: raw) }
}
public func _convertDispatchIOToRaw(_ object: DispatchIO) -> AnyObject {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchIO(_ handle: AnyObject) -> DispatchIO {
	let raw = unsafeDowncast(handle, to: dispatch_io_t.self)
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) { DispatchIO(__raw: raw) }
}
#else
public func _convertDispatchQueueToRaw(_ object: DispatchQueue) -> dispatch_queue_t {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchQueue(_ raw: dispatch_queue_t) -> DispatchQueue {
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) {
		let object = DispatchQueue(queue: raw)
		_legacyDispatchRetain(object.wrapped())
		return object
	}
}
public func _convertDispatchGroupToRaw(_ object: DispatchGroup) -> dispatch_group_t {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchGroup(_ raw: dispatch_group_t) -> DispatchGroup {
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) {
		let object = DispatchGroup(__raw: raw)
		_legacyDispatchRetain(object.wrapped())
		return object
	}
}
public func _convertDispatchSemaphoreToRaw(_ object: DispatchSemaphore) -> dispatch_semaphore_t {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchSemaphore(_ raw: dispatch_semaphore_t) -> DispatchSemaphore {
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) {
		let object = DispatchSemaphore(__raw: raw)
		_legacyDispatchRetain(object.wrapped())
		return object
	}
}
public func _convertDispatchSourceToRaw(_ object: DispatchSource) -> dispatch_source_t {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchSource(_ raw: dispatch_source_t) -> DispatchSource {
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) {
		let object = DispatchSource(source: raw)
		_legacyDispatchRetain(object.wrapped())
		return object
	}
}
public func _convertDispatchIOToRaw(_ object: DispatchIO) -> dispatch_io_t {
	_LegacyDispatchWrappers.shared.register(_LegacyDispatchWrappers.key(object.__wrapped), object)
	return object.__wrapped
}
public func _convertRawToDispatchIO(_ raw: dispatch_io_t) -> DispatchIO {
	return _LegacyDispatchWrappers.shared.unique(_LegacyDispatchWrappers.key(raw)) {
		let object = DispatchIO(__raw: raw)
		_legacyDispatchRetain(object.wrapped())
		return object
	}
}
#endif

// Stock Swift's dispatch objects are NSObjects: Equatable and Hashable by identity. With one wrapper
// per handle, identity here is the handle's.
extension DispatchObject: Hashable {
	public static func == (lhs: DispatchObject, rhs: DispatchObject) -> Bool {
		return lhs === rhs
	}
	public func hash(into hasher: inout Hasher) {
		hasher.combine(ObjectIdentifier(self))
	}
}
