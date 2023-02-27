import class Foundation.Thread
import Dispatch

/*
 A `Promise` is a functional abstraction around a failable asynchronous operation.
 - See: `Thenable`
 */
public final class Promise<T>: CatchMixin {
    // 使用抽象数据类型, 真正的 box 会是 EmptyBox 和 SealedBox 两种.
    let box: Box<Result<T>>
    
    fileprivate init(box: SealedBox<Result<T>>) {
        self.box = box
    }
    
    /// Initialize a new rejected promise.
    public init(error: Error) {
        box = SealedBox(value: .rejected(error))
    }
    
    /// Initialize a new promise bound to the provided `Thenable`.
    public init<U: Thenable>(_ bridge: U) where U.T == T {
        box = EmptyBox()
        bridge.pipe(to: box.seal)
    }
    
    /// Initialize a new promise that can be resolved with the provided `Resolver`.
    public init(resolver body: (Resolver<T>) throws -> Void) {
        box = EmptyBox()
        let resolver = Resolver(box)
        do {
            try body(resolver)
        } catch {
            resolver.reject(error)
        }
    }
    
    
    init(_: PMKUnambiguousInitializer) {
        box = EmptyBox()
    }
}

extension Promise: Thenable {
    /// - See: `Thenable.pipe`
    public func pipe(to: @escaping(Result<T>) -> Void) {
        /*
         这里是 DoubleCheck.
         如果只有一个 Check, 那么如果是 resolved 的状态, 执行 to 的逻辑就在锁的环境了.
         double check 之后, 如果还是 resolved, 就是中间出现了状态变化, 这种时候指定 to 概率极低了.
         */
        switch box.inspect() {
        case .pending:
            box.inspect {
                switch $0 {
                case .pending(let handlers): // handler 是一个引用类型, 所以这里取值出来没有问题. 并且这是在加锁的状态, 修改引用类型里面的数据, 是线程安全的.
                    handlers.append(to)
                case .resolved(let value):
                    to(value)
                }
            }
        case .resolved(let value):
            to(value)
        }
    }
    
    /// - See: `Thenable.result`
    public var result: Result<T>? {
        switch box.inspect() {
        case .pending:
            return nil
        case .resolved(let result):
            return result
        }
    }
}

extension Promise {
    /*
     Initialize a new fulfilled promise.
     
     We do not provide `init(value:)` because Swift is “greedy”
     and would pick that initializer in cases where it should pick
     one of the other more specific options leading to Promises with
     `T` that is eg: `Error` or worse `(T->Void,Error->Void)` for
     uses of our PMK < 4 pending initializer due to Swift trailing
     closure syntax (nothing good comes without pain!).
     
     Though often easy to detect, sometimes these issues would be
     hidden by other type inference leading to some nasty bugs in
     production.
     
     In PMK5 we tried to work around this by making the pending
     initializer take the form `Promise(.pending)` but this led to
     bad migration errors for PMK4 users. Hence instead we quickly
     released PMK6 and now only provide this initializer for making
     sealed & fulfilled promises.
     
     Usage is still (usually) good:
     
     guard foo else {
     return .value(bar)
     }
     */
    public static func value(_ value: T) -> Promise<T> {
        return Promise(box: SealedBox(value: .fulfilled(value)))
    }
    
    /// - Returns: a tuple of a new pending promise and its `Resolver`.
    public class func pending() -> (promise: Promise<T>,
                                    resolver: Resolver<T>) {
        let promise = Promise<T>(.pending)
        return (promise, Resolver(promise.box))
    }
}

public extension Promise {
    /**
     Blocks this thread, so—you know—don’t call this on a serial thread that
     any part of your chain may use. Like the main thread for example.
     */
    func wait() throws -> T {
        
        if Thread.isMainThread {
            shareConf.logHandler(LogEvent.waitOnMainThread)
        }
        
        var result = self.result
        
        if result == nil {
            let group = DispatchGroup()
            group.enter()
            // 当, Box 进行 Resolved 之后, 才会放开 group 的限制.
            pipe { result = $0; group.leave() }
            group.wait()
        }
        
        switch result! {
        case .rejected(let error):
            throw error
        case .fulfilled(let value):
            return value
        }
    }
}

extension Promise where T == Void {
    /// Initializes a new promise fulfilled with `Void`
    public convenience init() {
        self.init(box: SealedBox(value: .fulfilled(Void())))
    }
    
    /// Returns a new promise fulfilled with `Void`
    public static var value: Promise<Void> {
        return .value(Void())
    }
}


public extension DispatchQueue {
    /**
     Asynchronously executes the provided closure on a dispatch queue.
     
     DispatchQueue.global().async(.promise) {
     try md5(input)
     }.done { md5 in
     //…
     }
     
     - Parameter body: The closure that resolves this promise.
     - Returns: A new `Promise` resolved by the result of the provided closure.
     - Note: There is no Promise/Thenable version of this due to Swift compiler ambiguity issues.
     */
    final func async<T>(_: PMKNamespacer,
                        group: DispatchGroup? = nil,
                        qos: DispatchQoS = .default,
                        flags: DispatchWorkItemFlags = [],
                        execute body: @escaping () throws -> T)
    -> Promise<T> {
        let promise = Promise<T>(.pending)
        async(group: group, qos: qos, flags: flags) {
            do {
                promise.box.seal(.fulfilled(try body()))
            } catch {
                promise.box.seal(.rejected(error))
            }
        }
        return promise
    }
}


/// used by our extensions to provide unambiguous functions with the same name as the original function
public enum PMKNamespacer {
    case promise
}

// 一个特殊的类型, 用作 trait.
// Promise<T>(.pending) 就是调用的这里.
enum PMKUnambiguousInitializer {
    case pending
}
