
/*
    Promise 里面, 最重要的数据, 交给了 Resolver.
    Resolver 是类似于 Resolve, Reject 两个 JS 函数的封装, 它的存在, 就是为了修改 Box 里面的值的.
 */

public final class Resolver<T> {
    let box: Box<Result<T>>
    
    init(_ box: Box<Result<T>>) {
        self.box = box
    }
}

/*
 在 JS 里面, 是 FullFill, Reject 两个函数进行状态值的改变, 只不过这里专门定义了一个类型来做这件事.
 */
public extension Resolver {
    /*
        所有的操作, 都是进行 Box 的状态改变.
     */
    func fulfill(_ value: T) {
        box.seal(.fulfilled(value))
    }
    
    func reject(_ error: Error) {
        box.seal(.rejected(error))
    }
    
    func resolve(_ result: Result<T>) {
        box.seal(result)
    }
    
    
    // 下面的几个方法, 主要是方便直接传递给 Cocoa 的各种 Api 中.
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
 在 Resolved 的状态下, 会有以下的两种数据, 这在 Swift 环境下, 使用 Enum 的总和类型进行存储.
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
        case .fulfilled:
            return true
        case .rejected:
            return false
        }
    }
}
