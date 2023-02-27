import Foundation
import CoreFoundation

/*
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
        // 只能在主工程里面使用, 猜测是因为其他的线程, 没有默认开启运行循环的原因.
        fatalError("Only call hang() on the main thread.")
    }
    
    let runLoopMode: CFRunLoopMode = CFRunLoopMode.defaultMode
    
    // 使用 runLoop 卡住了当前运行逻辑. 直到能够获取到结果.
    if promise.isPending {
        var context = CFRunLoopSourceContext()
        let runLoop = CFRunLoopGetCurrent()
        let runLoopSource = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(runLoop, runLoopSource, runLoopMode)

        _ = promise.ensure {
            CFRunLoopStop(runLoop)
        }

        // 手动使用 runloop 卡住代码逻辑向下进行运转, 直到 Promise 完成之后, 才中断卡住逻辑.
        while promise.isPending {
            CFRunLoopRun()
        }
        CFRunLoopRemoveSource(runLoop, runLoopSource, runLoopMode)
    }

    // 使用这种方式, 能够到达这一步, 一定是 Promise 已经 resolved 了, 所以当前的 Promise 一定有值.
    switch promise.result! {
    case .rejected(let error):
        throw error
    case .fulfilled(let value):
        return value
    }
}
