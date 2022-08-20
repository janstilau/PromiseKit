import Foundation
import CoreFoundation

/**
 Runs the active run-loop until the provided promise resolves.

 This is for debug and is not a generally safe function to use in your applications. We mostly provide it for use in testing environments.

 Still if you like, study how it works (by reading the sources!) and use at your own risk.

 - Returns: The value of the resolved promise
 - Throws: An error, should the promise be rejected
 - See: `wait()`
*/
public func hang<T>(_ promise: Promise<T>) throws -> T {
    guard Thread.isMainThread else {
        // hang doesn't make sense on threads that aren't the main thread.
        // use `.wait()` on those threads.
        fatalError("Only call hang() on the main thread.")
    }
    let runLoopMode: CFRunLoopMode = CFRunLoopMode.defaultMode

    if promise.isPending {
        var context = CFRunLoopSourceContext()
        let runLoop = CFRunLoopGetCurrent()
        let runLoopSource = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(runLoop, runLoopSource, runLoopMode)

        _ = promise.ensure {
            CFRunLoopStop(runLoop)
        }
        
        // 这里就是不断的判断, 如果 promise 的值 resolver, 就不断的在这里安插一个 Runloop.
        // 这样可以保证整个应用保持原有的逻辑, 而这段代码卡住. 
        while promise.isPending {
            CFRunLoopRun()
        }
        CFRunLoopRemoveSource(runLoop, runLoopSource, runLoopMode)
    }

    switch promise.result! {
    case .rejected(let error):
        throw error
    case .fulfilled(let value):
        return value
    }
}
