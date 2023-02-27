/// An object for resolving promises
///
// 专门定义了一个类, 来完成 Promise 内部的状态改变.
// 状态改变, 已经被封装到了 Box 类的内部了.
// 所以, 这个 Resolver 可以看做是 box 的工具类.
public final class Resolver<T> {
    let box: Box<Result<T>>
    
    init(_ box: Box<Result<T>>) {
        self.box = box
    }
    
    deinit {
        if case .pending = box.inspect() {
            shareConf.logHandler(.pendingPromiseDeallocated)
        }
    }
}

// 提供了更加方便的方法, 去调用 box 的 seal 方法.
// 以下的各个方法, 之所以设计出来, 还是想要将原本的通过闭包的方式完成的代码, 直接使用 Resolve 完成转换. 
public extension Resolver {
    /// Fulfills the promise with the provided value
    func fulfill(_ value: T) {
        box.seal(.fulfilled(value))
    }
    
    /// Rejects the promise with the provided error
    func reject(_ error: Error) {
        box.seal(.rejected(error))
    }
    
    /// Resolves the promise with the provided result
    func resolve(_ result: Result<T>) {
        box.seal(result)
    }
    
    // 下面的这几个方法, 都是为了适配原有的 Completion 异步操作的. 
    /// Resolves the promise with the provided value or error
    func resolve(_ obj: T?, _ error: Error?) {
        if let error = error {
            reject(error)
        } else if let obj = obj {
            fulfill(obj)
        } else {
            reject(PMKError.invalidCallingConvention)
        }
    }
    
    /// Resolves the promise, provided for non-conventional value-error ordered completion handlers.
    func resolve(_ error: Error?, _ obj: T?) {
        resolve(obj, error)
    }
    
    /// Fulfills the promise with the provided value unless the provided error is non-nil
    func resolve(_ obj: T, _ error: Error?) {
        if let error = error {
            reject(error)
        } else {
            fulfill(obj)
        }
    }
}

#if swift(>=3.1)
extension Resolver where T == Void {
    /// Fulfills the promise unless error is non-nil
    public func resolve(_ error: Error?) {
        if let error = error {
            reject(error)
        } else {
            fulfill(())
        }
    }
#if false
    // disabled ∵ https://github.com/mxcl/PromiseKit/issues/990
    
    /// Fulfills the promise
    public func fulfill() {
        self.fulfill(())
    }
#else
    /// Fulfills the promise
    /// - Note: underscore is present due to: https://github.com/mxcl/PromiseKit/issues/990
    public func fulfill_() {
        self.fulfill(())
    }
#endif
}
#endif

#if swift(>=5.0)
extension Resolver {
    /// Resolves the promise with the provided result
    public func resolve<E: Error>(_ result: Swift.Result<T, E>) {
        switch result {
        case .failure(let error): self.reject(error)
        case .success(let value): self.fulfill(value)
        }
    }
}
#endif

// 这个 Result, 和 Swfit 是完全不一样的.
//  enum Result<Success, Failure> where Failure : Error 这是 Swift 的 Result 的定义, 可以看到还是明显不同的.
public enum Result<T> {
    case fulfilled(T)
    // 和 Swfit 的 Result 不同, PromiseKit 里面的 Result 没有对于 Error 的限制.
    // 这也就意味着, Promise 里面, Catch 面对的是一个 Void* 的 Error 类型.
    case rejected(Error)
}

// 这是合理的定义方式, Enum 要伴随着大量的计算属性, 根据自身的状态来返回合理的业务值.
public extension PromiseKit.Result {
    var isFulfilled: Bool {
        switch self {
        case .fulfilled:
            return true
        case .rejected:
            return false
        }
    }
}
