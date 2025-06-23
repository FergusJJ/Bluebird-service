import Foundation
import Supabase

public final class EphemeralAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var _inMemoryStorage = [String: Data]() // Renamed internal variable

    // Optional: If you want to inspect it during debugging from outside (not strictly needed)
    // public var currentStorageSnapshot: [String: Data] {
    //     lock.lock()
    //     defer { lock.unlock() }
    //     return _inMemoryStorage
    // }

    public init() {} // Make initializer public

    public func store(key: String, value: Data) throws {
        lock.lock()
        _inMemoryStorage[key] = value
        lock.unlock()
        print("[EphemeralAuthStorage] Stored data for key: \(key)")
    }

    public func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let data = _inMemoryStorage[key]
        if data != nil {
            print("[EphemeralAuthStorage] Retrieved data for key: \(key)")
        } else {
            print("[EphemeralAuthStorage] No data found for key: \(key)")
        }
        return data
    }

    public func remove(key: String) throws {
        lock.lock()
        _inMemoryStorage[key] = nil
        lock.unlock()
        print("[EphemeralAuthStorage] Removed data for key: \(key)")
    }
}
