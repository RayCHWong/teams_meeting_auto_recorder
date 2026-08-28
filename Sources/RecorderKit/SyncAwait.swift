import Foundation

/// Runs an async operation from a synchronous context and waits for it.
///
/// Only for the command-line harness and for start-up permission prompts, where there is no
/// structured concurrency context to await in. Never called from the capture path.
public enum SyncAwait {
    public static func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}

public extension Result where Failure == Error {
    /// The throwing-async counterpart of `Result(catching:)`, which the standard library
    /// omits. Named rather than an overload: an overloaded initializer loses to the
    /// synchronous one during overload resolution.
    static func catchingAsync(_ body: () async throws -> Success) async -> Result {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}
