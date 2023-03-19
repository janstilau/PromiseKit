#if swift(>=4.1)
#if canImport(Combine)
import Combine

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension Guarantee {
    // Guarantee 代表着不会发生错误, 所以 Future<T, Never> 中的错误类型是 Never.
    func future() -> Future<T, Never> {
        .init { [weak self] promise in
            // Done 代表着, 就是相应的最后一环, 内部会将下个节点收到的数据变为 Void.
            self?.done { value in
                promise(.success(value))
            }
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension Promise {
    func future() -> Future<T, Error> {
        Future.init { [weak self] promise in
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
