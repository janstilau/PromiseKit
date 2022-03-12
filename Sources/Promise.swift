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
    
    public static func value(_ value: T) -> Promise<T> {
        return Promise(box: SealedBox(value: .fulfilled(value)))
    }
    
    public init(error: Error) {
        box = SealedBox(value: .rejected(error))
    }
    
    public init<U: Thenable>(_ bridge: U) where U.T == T {
        box = EmptyBox()
        bridge.pipe(to: box.seal)
    }
    
    /*
     使用者提供 Body 的实现, 在里面一般会创建异步任务. Body 是 Promise 的编写者主动调用的.
     使用者使用 Body 的参数, 完成 Promise 的状态的改变. Body 的参数, 是外部的使用者主动调用的.
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
    
    public class func pending() -> (promise: Promise<T>, resolver: Resolver<T>) {
        // 非常非常烂的代码, 除了炫技有什么用.
        return { ($0, Resolver($0.box)) }(Promise<T>(.pending))
    }
    
    // 如果, 是 Pending 态, 那么就将 Handler 进行存储.
    // 如果, 是 Resolved 态, 就直接调用传递过来的 Handler.
    public func pipe(to: @escaping(Result<T>) -> Void) {
        // 这里有一个 double check 的机制.
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
