
/*
    Promise 里面, 最重要的数据, 交给了 Resolver.
    Resolver 是类似于 Resolve, Reject 两个 JS 函数的封装, 它的存在, 就是为了修改 Box 里面的值的.
 */

public final class Resolver<T> {
    let box: Box<Result<T>>
    
    init(_ box: Box<Result<T>>) {
        self.box = box
    }
    
    deinit {
        if case .pending = box.inspect() {
            conf.logHandler(.pendingPromiseDeallocated)
        }
    }
}


public extension Resolver {
    /*
        所有的操作, 都是进行 Box 的状态改变.
        seal 并不是存储 T 的, 它是存储 Result T 的.
        如果, fulfilled, 那么存储的就是 T
        如果, rejected, 那么存储的就是 Error.
     */
    func fulfill(_ value: T) {
        // 这里, 直接可以写 Fulfilled, 是因为上面的 Box, 已经写明了, 存储的是 Result<T> 这种类型.
        box.seal(.fulfilled(value))
    }
    
    func reject(_ error: Error) {
        box.seal(.rejected(error))
    }
    
    // 如果, 传递过来的, 直接就是 Result, 那么就使用 Resolve 函数. 
    func resolve(_ result: Result<T>) {
        box.seal(result)
    }
    
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
    
    /// Fulfills the promise with the provided value unless the provided error is non-nil
    func resolve(_ obj: T, _ error: Error?) {
        if let error = error {
            reject(error)
        } else {
            fulfill(obj)
        }
    }
    
    /// Resolves the promise, provided for non-conventional value-error ordered completion handlers.
    func resolve(_ error: Error?, _ obj: T?) {
        resolve(obj, error)
    }
}

extension Resolver where T == Void {
    /// Fulfills the promise unless error is non-nil
    public func resolve(_ error: Error?) {
        if let error = error {
            reject(error)
        } else {
            fulfill(())
        }
    }
    /// Fulfills the promise
    /// - Note: underscore is present due to: https://github.com/mxcl/PromiseKit/issues/990
    public func fulfill_() {
        self.fulfill(())
    }
}

extension Resolver {
    /// Resolves the promise with the provided result
    public func resolve<E: Error>(_ result: Swift.Result<T, E>) {
        switch result {
        case .failure(let error): self.reject(error)
        case .success(let value): self.fulfill(value)
        }
    }
}

/*
 Resolved 状态下, 又分 fulfilled 和 rejected 两种.
 在 Fulfilled 的状态下, 才会存储 T 类型的值.
 在 Rejected 的状态下, 只会存储一个 Error.
 */
public enum Result<T> {
    case fulfilled(T)
    case rejected(Error)
}

/*
 虽然, 这就是一个状态值, 但是里面包含了关联值, 使得使用的时候, 并不是很方便.
 专门定义一个方法, 封装状态值的判断逻辑, 会让外界使用的时候, 更加的方便.
 */
public extension PromiseKit.Result {
    var isFulfilled: Bool {
        switch self {
        // 可以直接这么判断???
        case .fulfilled:
            return true
        case .rejected:
            return false
        }
    }
}
