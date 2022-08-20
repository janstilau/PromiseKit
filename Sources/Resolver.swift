
// 泛型, 将类型进行了绑定, 提供能加友好的操纵. 
/// An object for resolving promises
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

// 这个类, 本质上是封装了对于 Box 状态改变操作.
// 但是用户直接使用的, 是下面提供的各种快捷的操作.
// 由于泛型的缘故, 用户其实是不会直接接触到 Box 层的. 
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

// 这不是 Swfit 的, 而是自己定义的 Result. 
public enum Result<T> {
    case fulfilled(T)
    case rejected(Error)
}

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
