import class Foundation.Thread
import Dispatch

/*
 Promise, 仅仅绑定的是业务的 T 类型.
 因为在 Box 里面, 自动绑定了 Result.
 */
public final class Promise<T>: Thenable, CatchMixin {
    
    let box: Box<Result<T>>
    
    fileprivate init(box: SealedBox<Result<T>>) {
        self.box = box
    }
    
    /**
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
    
    /*
     使用, 一个 Error 进行初始化, 就是将状态, 变为 Resolved, 里面的 Result 是 Rejected.
     */
    public init(error: Error) {
        box = SealedBox(value: .rejected(error))
    }
    
    /// Initialize a new promise bound to the provided `Thenable`.
    public init<U: Thenable>(_ bridge: U) where U.T == T {
        box = EmptyBox()
        bridge.pipe(to: box.seal)
    }
    
    /// Initialize a new promise that can be resolved with the provided `Resolver`.
    // 可以类似于, JS 里面的 executor 的用法.
    // Resolver, 里面包装的就是 resolve, reject 函数.
    
    /*
     新生成的 Promise, 它的 Box 的状态改变, 只能通过 Resolver 来进行.
     Body 闭包, 应该在适当的时机, 来调用 Resolver 的方法, 来使得 Promise 的状态发生改变.
     */
    public init(resolver body: (Resolver<T>) throws -> Void) {
        box = EmptyBox()
        
        let resolver = Resolver(box) // 生成, 可以改变 Primise 的一个对象.
        do {
            try body(resolver)
        } catch {
            resolver.reject(error)
        }
    }
    
    // 这个 Pending 的写法, 是类库里面的, 固定的命名规则.
    public class func pending() -> (promise: Promise<T>, resolver: Resolver<T>) {
        return { ($0, Resolver($0.box)) }(Promise<T>(.pending))
    }
    
    // 如果, 是 Pending 态, 那么就讲 Handler 进行存储.
    
    public func pipe(to: @escaping(Result<T>) -> Void) {
        // box.inspect() get 操作, 里面有线程控制.
        switch box.inspect() {
        case .pending:
            box.inspect {
                switch $0 {
                case .pending(let handlers):
                    handlers.append(to)
                case .resolved(let value):
                    to(value)
                }
            }
            // 如果, 已经是完成态了, 那么直接把存储的值给闭包执行.
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
    
    // 一种, 特殊的构造函数.
    // 将 Box 置为 Pending 状态.
    init(_: PMKUnambiguousInitializer) {
        box = EmptyBox()
    }
}

public extension Promise {
    /**
     Blocks this thread, so—you know—don’t call this on a serial thread that
     any part of your chain may use. Like the main thread for example.
     */
    func wait() throws -> T {
        
        if Thread.isMainThread {
            conf.logHandler(LogEvent.waitOnMainThread)
        }
        
        var result = self.result
        
        if result == nil {
            let group = DispatchGroup()
            group.enter()
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

#if swift(>=3.1)
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
#endif


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
    @available(macOS 10.10, iOS 8.0, tvOS 9.0, watchOS 2.0, *)
    final func async<T>(_: PMKNamespacer, group: DispatchGroup? = nil, qos: DispatchQoS = .default, flags: DispatchWorkItemFlags = [], execute body: @escaping () throws -> T) -> Promise<T> {
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

enum PMKUnambiguousInitializer {
    case pending
}
