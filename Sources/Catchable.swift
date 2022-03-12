import Dispatch

/// Provides `catch` and `recover` to your object that conforms to `Thenable`
public protocol CatchMixin: Thenable {}

public extension CatchMixin {
    
    /*
     The provided closure executes when this promise rejects.
     
     Rejecting a promise cascades: rejecting all subsequent promises (unless
     recover is invoked) thus you will typically place your catch at the end
     of a chain. Often utility promises will not have a catch, instead
     delegating the error handling to the caller.
     */
    /*
     因为 Promise 响应链, Error 是传递的, 所以可以在最终进行错误的处理.
     返回值不再是 Promise, 而是 PMKFinalizer, 所以只能进行 finnal 的添加了.
     */
    @discardableResult
    func `catch`(on: DispatchQueue? = conf.Q.return,
                 flags: DispatchWorkItemFlags? = nil,
                 policy: CatchPolicy = conf.catchPolicy,
                 _ body: @escaping(Error) -> Void) -> PMKFinalizer {
        
        // 返回了一个特殊的类型, 这个特殊类型, 只能调用 finnally
        let finalizer = PMKFinalizer()
        
        pipe {
            switch $0 {
            case .rejected(let error):
                guard policy == .allErrors || !error.isCancelled else {
                    fallthrough
                }
                // 只会在 Rejected 的状态下, 才会触发 Body.
                // 触发了之后, finalizer 内管理的状态, 也就固定下来了.
                on.async(flags: flags) {
                    // body 不会直接影响到 finalizer
                    // 仅仅是进行调用.
                    body(error)
                    finalizer.pending.resolve(())
                }
            case .fulfilled:
                // 之前的响应链没有错误.
                finalizer.pending.resolve(())
            }
        }
        
        return finalizer
    }
}

// 这是一个新的类型, 只能调用 finnally 函数了.
public class PMKFinalizer {
    
    let pending = Guarantee<Void>.pending()
    
    /// `finally` is the same as `ensure`, but it is not chainable
    public func finally(on: DispatchQueue? = conf.Q.return,
                        flags: DispatchWorkItemFlags? = nil,
                        _ body: @escaping () -> Void) {
        // 就是在 pending 里面增加一个回调.
        // 在 catch 里面, 立定会触发 body 的调用.
        pending.guarantee.done(on: on, flags: flags) {
            body()
        }
    }
}


public extension CatchMixin {
    
    /*
     The provided closure executes when this promise rejects.
     
     Unlike `catch`, `recover` continues the chain.
     Use `recover` in circumstances where recovering the chain from certain errors is a possibility. For example:
     
     firstly {
     CLLocationManager.requestLocation()
     }.recover { error in
     guard error == CLError.unknownLocation else { throw error }
     return .value(CLLocation.chicago)
     }
     */
    func recover<U: Thenable>(on: DispatchQueue? = conf.Q.map,
                              flags: DispatchWorkItemFlags? = nil,
                              policy: CatchPolicy = conf.catchPolicy,
                              _ body: @escaping(Error) throws -> U) -> Promise<T> where U.T == T {
        let rp = Promise<U.T>(.pending)
        
        pipe {
            switch $0 {
            case .fulfilled(let value):
                rp.box.seal(.fulfilled(value))
            case .rejected(let error):
                if policy == .allErrors || !error.isCancelled {
                    on.async(flags: flags) {
                        do {
                            // 如果, 发生了问题, 就使用 Body 开启一个新的异步任务. 有这个异步任务的状态, 来决定后续的状态.
                            let rv = try body(error)
                            guard rv !== rp else { throw PMKError.returnedSelf }
                            rv.pipe(to: rp.box.seal)
                        } catch {
                            rp.box.seal(.rejected(error))
                        }
                    }
                } else {
                    rp.box.seal(.rejected(error))
                }
            }
        }
        
        return rp
    }
    
    /*
     The provided closure executes when this promise rejects.
     This variant of `recover` requires the handler to return a Guarantee, thus it returns a Guarantee itself and your closure cannot `throw`.
     - Note it is logically impossible for this to take a `catchPolicy`, thus `allErrors` are handled.
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The handler to execute if this promise is rejected.
     - SeeAlso: [Cancellation](https://github.com/mxcl/PromiseKit/blob/master/Documentation/CommonPatterns.md#cancellation)
     */
    @discardableResult
    func recover(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ body: @escaping(Error) -> Guarantee<T>) -> Guarantee<T> {
        let rg = Guarantee<T>(.pending)
        pipe {
            switch $0 {
            case .fulfilled(let value):
                rg.box.seal(value)
            case .rejected(let error):
                on.async(flags: flags) {
                    body(error).pipe(to: rg.box.seal)
                }
            }
        }
        return rg
    }
    
    /**
     The provided closure executes when this promise resolves, whether it rejects or not.
     
     firstly {
     UIApplication.shared.networkActivityIndicatorVisible = true
     }.done {
     //…
     }.ensure {
     UIApplication.shared.networkActivityIndicatorVisible = false
     }.catch {
     //…
     }
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that executes when this promise resolves.
     - Returns: A new promise, resolved with this promise’s resolution.
     */
    /*
     ensure, 就是不管结果如何, 都执行 Body 里面的操作.
     然后, 将 Rp 的状态, 变为 Result 的值 .
     */
    func ensure(on: DispatchQueue? = conf.Q.return, flags: DispatchWorkItemFlags? = nil, _ body: @escaping () -> Void) -> Promise<T> {
        let rp = Promise<T>(.pending)
        pipe { result in
            on.async(flags: flags) {
                // 和 Get 没有太大的区别感觉. 只是 body 不需要上游节点的状态值.
                body()
                rp.box.seal(result)
            }
        }
        return rp
    }
    
    /*
     The provided closure executes when this promise resolves, whether it rejects or not.
     The chain waits on the returned `Guarantee<Void>`.
     
     firstly {
     setup()
     }.done {
     //…
     }.ensureThen {
     teardown()  // -> Guarante<Void>
     }.catch {
     //…
     }
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that executes when this promise resolves.
     - Returns: A new promise, resolved with this promise’s resolution.
     */
    func ensureThen(on: DispatchQueue? = conf.Q.return, flags: DispatchWorkItemFlags? = nil, _ body: @escaping () -> Guarantee<Void>) -> Promise<T> {
        let rp = Promise<T>(.pending)
        pipe { result in
            on.async(flags: flags) {
                // body 调用完毕只有, 继续触发 rp 的逻辑.
                // 这里的 Body 是一个异步操作, 返回一个中间节点, 这个中间节点改变之后, 才会进行后续的操作.
                // 后续节点, 还是使用 body 之前的数据, Body 完全是一个中间插入的节点.
                body().done {
                    rp.box.seal(result)
                }
            }
        }
        return rp
    }
    
    
    
    /**
     Consumes the Swift unused-result warning.
     - Note: You should `catch`, but in situations where you know you don’t need a `catch`, `cauterize` makes your intentions clear.
     */
    @discardableResult
    func cauterize() -> PMKFinalizer {
        return self.catch {
            conf.logHandler(.cauterized($0))
        }
    }
}


public extension CatchMixin where T == Void {
    
    /*
     The provided closure executes when this promise rejects.
     
     This variant of `recover` is specialized for `Void` promises and de-errors your chain returning a `Guarantee`, thus you cannot `throw` and you must handle all errors including cancellation.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The handler to execute if this promise is rejected.
     - SeeAlso: [Cancellation](https://github.com/mxcl/PromiseKit/blob/master/Documentation/CommonPatterns.md#cancellation)
     */
    @discardableResult
    func recover(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ body: @escaping(Error) -> Void) -> Guarantee<Void> {
        let rg = Guarantee<Void>(.pending)
        pipe {
            switch $0 {
            case .fulfilled:
                rg.box.seal(())
            case .rejected(let error):
                on.async(flags: flags) {
                    body(error)
                    rg.box.seal(())
                }
            }
        }
        return rg
    }
    
    /*
     The provided closure executes when this promise rejects.
     
     This variant of `recover` ensures that no error is thrown from the handler and allows specifying a catch policy.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The handler to execute if this promise is rejected.
     - SeeAlso: [Cancellation](https://github.com/mxcl/PromiseKit/blob/master/Documentation/CommonPatterns.md#cancellation)
     */
    func recover(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, policy: CatchPolicy = conf.catchPolicy, _ body: @escaping(Error) throws -> Void) -> Promise<Void> {
        let rg = Promise<Void>(.pending)
        pipe {
            switch $0 {
            case .fulfilled:
                rg.box.seal(.fulfilled(()))
            case .rejected(let error):
                if policy == .allErrors || !error.isCancelled {
                    on.async(flags: flags) {
                        do {
                            rg.box.seal(.fulfilled(try body(error)))
                        } catch {
                            rg.box.seal(.rejected(error))
                        }
                    }
                } else {
                    rg.box.seal(.rejected(error))
                }
            }
        }
        return rg
    }
}
