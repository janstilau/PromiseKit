#if swift(>=4.1)
#if canImport(Combine)
import Combine

/*
 Future 原本就是异步操作转入 Combine 的工具.
 最终的 resolve 函数, 内嵌到了 promise 的 wrapper 方法内了. 其实还是异步操作回调的概念, 不过被 PromiseKit 封装了后续逻辑. 
 */
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension Guarantee {
    func future() -> Future<T, Never> {
        .init { [weak self] promise in
            self?.done { value in
                promise(.success(value))
            }
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension Promise {
    func future() -> Future<T, Error> {
        .init { [weak self] promise in
            self?.done { value in
                promise(.success(value))
            }.catch { error in
                promise(.failure(error))
            }
        }
    }
}
#endif
#endif
