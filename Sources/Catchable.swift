import Dispatch

/// Provides `catch` and `recover` to your object that conforms to `Thenable`
public protocol CatchMixin: Thenable {}

// 之所以将 Catch 进行了抽离, 是因为 Guarantee 是没有 Catch 的能力的.
// 将两个抽象类进行分离, 让代码的更加分离. 
public extension CatchMixin {
    
    /*
     The provided closure executes when this promise rejects.
     
     Rejecting a promise cascades: rejecting all subsequent promises (unless
     recover is invoked) thus you will typically place your catch at the end
     of a chain.
     
     // 这里说明了一下, API 设计的原则, 工具行的 Promise 返回值, 不会真正的进行错误处理.
     // 应该是由业务方, 进行错误处理.
     Often utility promises will not have a catch, instead delegating the error handling to the caller.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter policy: The default policy does not execute your handler for cancellation errors.
     - Parameter execute: The handler to execute if this promise is rejected.
     - Returns: A promise finalizer.
     - SeeAlso: [Cancellation](https://github.com/mxcl/PromiseKit/blob/master/Documentation/CommonPatterns.md#cancellation)
     */
    // 如果不想添加 finally, 那么 catch 就当做最后一步了, 所以可以不进行 return value 的处理.
    @discardableResult
    func `catch`(on: DispatchQueue? = shareConf.defaultQueue.end,
                 flags: DispatchWorkItemFlags? = nil,
                 policy: CatchPolicy = shareConf.catchPolicy,
                 _ body: @escaping(Error) -> Void) -> PMKFinalizer {
        // catch 中, 生成 PMKFinalizer 一定会进行 resolved.
        let finalizer = PMKFinalizer()
        pipe {
            switch $0 {
            case .rejected(let error):
                guard policy == .allErrors || !error.isCancelled else {
                    fallthrough
                }
                // 如果 error 了, 触发 body, 然后触发 PMKFinalizer 的 resolve, 进行 finally 中添加的回调触发.
                on.async(flags: flags) {
                    body(error)
                    finalizer.pending.resolve(())
                }
            case .fulfilled:
                // 如果 fulfilled 了, 直接触发 PMKFinalizer 的 resolve, 进行 finally 中添加的回调触发.
                finalizer.pending.resolve(())
            }
        }
        return finalizer
    }
}

// 这个类, 只能在 Catch 中生成. 所以 finally 只能在 Catch 函数后面调用.
public class PMKFinalizer {
    let pending = Guarantee<Void>.pending()

    /// `finally` is the same as `ensure`, but it is not chainable
    public func finally(on: DispatchQueue? = shareConf.defaultQueue.end,
                        flags: DispatchWorkItemFlags? = nil,
                        _ body: @escaping () -> Void) {
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
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The handler to execute if this promise is rejected.
     - SeeAlso: [Cancellation](https://github.com/mxcl/PromiseKit/blob/master/Documentation/CommonPatterns.md#cancellation)
     */
    // Promise 的 recover 如果返回的是 U, 那么返回的就是一个 Promise.
    func recover<U: Thenable>(on: DispatchQueue? = shareConf.defaultQueue.processing,
                              flags: DispatchWorkItemFlags? = nil,
                              policy: CatchPolicy = shareConf.catchPolicy,
                              _ body: @escaping(Error) throws -> U)
    -> Promise<T> where U.T == T {
        // 这里, Body 返回的 T 要和原来的一样.
        let rp = Promise<U.T>(.pending)
        pipe {
            switch $0 {
            case .fulfilled(let value):
                rp.box.seal(.fulfilled(value))
            case .rejected(let error):
                if policy == .allErrors || !error.isCancelled {
                    on.async(flags: flags) {
                        do {
                            // 和 Combine 的逻辑很相似, 当发生了错误之后, 创建一个新的异步信号节点, 通过该节点, 来完成后续节点状态的确定.
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

    /**
     The provided closure executes when this promise rejects.
     This variant of `recover` requires the handler to return a Guarantee, thus it returns a Guarantee itself and your closure cannot `throw`.
     - Note it is logically impossible for this to take a `catchPolicy`, thus `allErrors` are handled.
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The handler to execute if this promise is rejected.
     - SeeAlso: [Cancellation](https://github.com/mxcl/PromiseKit/blob/master/Documentation/CommonPatterns.md#cancellation)
     */
    // Promise 的 recover(on 如果返回一个 Guarantee<T>, 那么后续就是 Guarantee<T>.
    @discardableResult
    func recover(on: DispatchQueue? = shareConf.defaultQueue.processing,
                 flags: DispatchWorkItemFlags? = nil,
                 _ body: @escaping(Error) -> Guarantee<T>)
    -> Guarantee<T> {
        // 当 body 返回的是 Guarantee 的时候, return 类型可以变为 Guarantee
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

    /*
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
    // then, catch 都是在特定的数据 enum 下才触发, ensure 则是不管数据如何, 触发自己的 Body 逻辑, 然后透传状态.
    // 可以看到, 里面 body 是 () -> Void. 所以 ensure 里面执行的, 应该就是和数据无关的一些逻辑.
    // 相比较于 tap, ensure 其实并不需要参数. 可以认为是事件流之外的一些逻辑.
    func ensure(on: DispatchQueue? = shareConf.defaultQueue.end,
                flags: DispatchWorkItemFlags? = nil,
                _ body: @escaping () -> Void)
    -> Promise<T> {
        let rp = Promise<T>(.pending)
        // 在 then, catch 里面, 是对 result 进行了判断, 在 fulfill 的时候, 执行 then 传入的逻辑. 在 rejected 的时候, 执行 catch 传入的逻辑.
        // ensure 里面, 不管 result 的实际值如何, 执行 body, 然后透传 result 到下一个节点. 
        pipe { result in
            on.async(flags: flags) {
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
    func ensureThen(on: DispatchQueue? = shareConf.defaultQueue.end,
                    flags: DispatchWorkItemFlags? = nil,
                    _ body: @escaping () -> Guarantee<Void>)
    -> Promise<T> {
        let rp = Promise<T>(.pending)
        pipe { result in
            on.async(flags: flags) {
                // 原本, ensure 就是拿到 Reuslt 做一些操做.
                // 但是如果想要 ensure 之后, 添加一些新的操作, 那么就将 rp 的 resolve 事件延后, 等到 ensure 返回的异步操作 resolve 之后, rp 才进行 resolve.
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
            shareConf.logHandler(.cauterized($0))
        }
    }
}

// 只有原本的 Promise 都是 Voide 的时候, 才能调用. 
public extension CatchMixin where T == Void {
    
    /**
     The provided closure executes when this promise rejects.
     
     This variant of `recover` is specialized for `Void` promises and de-errors your chain returning a `Guarantee`, thus you cannot `throw` and you must handle all errors including cancellation.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The handler to execute if this promise is rejected.
     - SeeAlso: [Cancellation](https://github.com/mxcl/PromiseKit/blob/master/Documentation/CommonPatterns.md#cancellation)
     */
    @discardableResult
    func recover(on: DispatchQueue? = shareConf.defaultQueue.processing,
                 flags: DispatchWorkItemFlags? = nil,
                 _ body: @escaping(Error) -> Void)
    -> Guarantee<Void> {
        
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

    /**
     The provided closure executes when this promise rejects.
     
     This variant of `recover` ensures that no error is thrown from the handler and allows specifying a catch policy.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The handler to execute if this promise is rejected.
     - SeeAlso: [Cancellation](https://github.com/mxcl/PromiseKit/blob/master/Documentation/CommonPatterns.md#cancellation)
     */
    func recover(on: DispatchQueue? = shareConf.defaultQueue.processing,
                 flags: DispatchWorkItemFlags? = nil,
                 policy: CatchPolicy = shareConf.catchPolicy,
                 _ body: @escaping(Error) throws -> Void)
    -> Promise<Void> {
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
