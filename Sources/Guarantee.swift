import class Foundation.Thread
import Dispatch

/*
    A `Guarantee` is a functional abstraction around an asynchronous operation that cannot error.
 */

/*
 这个 Thenable, 不会产生错误, 一定会产生 T 类型的值.
 
 Guarantee 里面, T 是业务数据类型, 而不是 Result 的类型.
 所以, 它的 Resolved 状态, 里面存的就是 T 类型的值, 没有用 Result 在去包装一层.
 */
public final class Guarantee<T>: Thenable {
    
    public static func value(_ value: T) -> Guarantee<T> {
        // .init 还能这样使用.
        return .init(box: SealedBox(value: value))
    }
    
    // 状态值.
    let box: PromiseKit.Box<T>
    
    fileprivate init(box: SealedBox<T>) {
        // 使用了 Sealed 状态的 Box.
        // 也就是上来就是 Resolved 状态的 Box.
        self.box = box
    }
    
    /// Returns a pending `Guarantee` that can be resolved with the provided closure’s parameter.
    public init(resolver body: (@escaping(T) -> Void) -> Void) {
        box = Box()
        // 这种写法, 会把 Box 进行捕获.
        body(box.seal)
    }
    
    /// - See: `Thenable.pipe`
    public func pipe(to: @escaping(Result<T>) -> Void) {
        pipe{
            // 直接, 就是 Fulfilled 的状态. 没有 rejected 的状态.
            to(.fulfilled($0))
        }
    }
    
    func pipe(to: @escaping(T) -> Void) {
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
        case .resolved(let value):
            return .fulfilled(value)
        }
    }
    
    final private class Box<T>: EmptyBox<T> {
        deinit {
            switch inspect() {
            case .pending:
                PromiseKit.conf.logHandler(.pendingGuaranteeDeallocated)
            case .resolved:
                break
            }
        }
    }
    
    init(_: PMKUnambiguousInitializer) {
        box = Box()
    }
    
    /// Returns a tuple of a pending `Guarantee` and a function that resolves it.
    // 垃圾写法
    public class func pending() -> (guarantee: Guarantee<T>,
                                    resolve: (T) -> Void) {
        return { ($0, $0.box.seal) }(Guarantee<T>(.pending))
    }
}

public extension Guarantee {
    
    @discardableResult
    func done(on: DispatchQueue? = conf.Q.return,
              flags: DispatchWorkItemFlags? = nil,
              _ body: @escaping(T) -> Void) -> Guarantee<Void> {
        let rg = Guarantee<Void>(.pending)
        
        pipe { (value: T) in
            on.async(flags: flags) {
                body(value)
                rg.box.seal(())
            }
        }
        
        return rg
    }
    
    func get(on: DispatchQueue? = conf.Q.return,
             flags: DispatchWorkItemFlags? = nil,
             _ body: @escaping (T) -> Void) -> Guarantee<T> {
        return map(on: on, flags: flags) {
            body($0)
            return $0
        }
    }
    
    func map<U>(on: DispatchQueue? = conf.Q.map,
                flags: DispatchWorkItemFlags? = nil,
                _ body: @escaping(T) -> U) -> Guarantee<U> {
        let rg = Guarantee<U>(.pending)
        pipe { value in
            on.async(flags: flags) {
                rg.box.seal(body(value))
            }
        }
        return rg
    }
    
    @discardableResult
    func then<U>(on: DispatchQueue? = conf.Q.map,
                 flags: DispatchWorkItemFlags? = nil,
                 _ body: @escaping(T) -> Guarantee<U>) -> Guarantee<U> {
        let rg = Guarantee<U>(.pending)
        pipe { value in
            on.async(flags: flags) {
                body(value).pipe(to: rg.box.seal)
            }
        }
        return rg
    }
    
    func asVoid() -> Guarantee<Void> {
        return map(on: nil) { _ in }
    }
    
    /**
     Blocks this thread, so you know, don’t call this on a serial thread that
     any part of your chain may use. Like the main thread for example.
     */
    func wait() -> T {
        
        if Thread.isMainThread {
            conf.logHandler(.waitOnMainThread)
        }
        
        var result = value
        
        if result == nil {
            let group = DispatchGroup()
            group.enter()
            // 将, 回调进行注册, 别的线程的状态变化, 触发回调, 这里 wait 才可以继续向后进行.
            pipe { (foo: T) in result = foo; group.leave() }
            group.wait()
        }
        
        return result!
    }
}

public extension Guarantee where T: Sequence {
    /**
     `Guarantee<[T]>` => `T` -> `U` => `Guarantee<[U]>`
     
     Guarantee.value([1,2,3])
     .mapValues { integer in integer * 2 }
     .done {
     // $0 => [2,4,6]
     }
     */
    func mapValues<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> U) -> Guarantee<[U]> {
        return map(on: on, flags: flags) { $0.map(transform) }
    }
    
#if swift(>=4) && !swift(>=5.2)
    /**
     `Guarantee<[T]>` => `KeyPath<T, U>` => `Guarantee<[U]>`
     
     Guarantee.value([Person(name: "Max"), Person(name: "Roman"), Person(name: "John")])
     .mapValues(\.name)
     .done {
     // $0 => ["Max", "Roman", "John"]
     }
     */
    func mapValues<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, U>) -> Guarantee<[U]> {
        return map(on: on, flags: flags) { $0.map { $0[keyPath: keyPath] } }
    }
#endif
    
    /**
     `Guarantee<[T]>` => `T` -> `[U]` => `Guarantee<[U]>`
     
     Guarantee.value([1,2,3])
     .flatMapValues { integer in [integer, integer] }
     .done {
     // $0 => [1,1,2,2,3,3]
     }
     */
    func flatMapValues<U: Sequence>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> U) -> Guarantee<[U.Iterator.Element]> {
        return map(on: on, flags: flags) { (foo: T) in
            foo.flatMap { transform($0) }
        }
    }
    
    /**
     `Guarantee<[T]>` => `T` -> `U?` => `Guarantee<[U]>`
     
     Guarantee.value(["1","2","a","3"])
     .compactMapValues { Int($0) }
     .done {
     // $0 => [1,2,3]
     }
     */
    func compactMapValues<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> U?) -> Guarantee<[U]> {
        return map(on: on, flags: flags) { foo -> [U] in
#if !swift(>=3.3) || (swift(>=4) && !swift(>=4.1))
            return foo.flatMap(transform)
#else
            return foo.compactMap(transform)
#endif
        }
    }
    
#if swift(>=4) && !swift(>=5.2)
    /**
     `Guarantee<[T]>` => `KeyPath<T, U?>` => `Guarantee<[U]>`
     
     Guarantee.value([Person(name: "Max"), Person(name: "Roman", age: 26), Person(name: "John", age: 23)])
     .compactMapValues(\.age)
     .done {
     // $0 => [26, 23]
     }
     */
    func compactMapValues<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, U?>) -> Guarantee<[U]> {
        return map(on: on, flags: flags) { foo -> [U] in
#if !swift(>=4.1)
            return foo.flatMap { $0[keyPath: keyPath] }
#else
            return foo.compactMap { $0[keyPath: keyPath] }
#endif
        }
    }
#endif
    
    /**
     `Guarantee<[T]>` => `T` -> `Guarantee<U>` => `Guaranetee<[U]>`
     
     Guarantee.value([1,2,3])
     .thenMap { .value($0 * 2) }
     .done {
     // $0 => [2,4,6]
     }
     */
    func thenMap<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> Guarantee<U>) -> Guarantee<[U]> {
        return then(on: on, flags: flags) {
            when(fulfilled: $0.map(transform))
        }.recover {
            // if happens then is bug inside PromiseKit
            fatalError(String(describing: $0))
        }
    }
    
    /**
     `Guarantee<[T]>` => `T` -> `Guarantee<[U]>` => `Guarantee<[U]>`
     
     Guarantee.value([1,2,3])
     .thenFlatMap { integer in .value([integer, integer]) }
     .done {
     // $0 => [1,1,2,2,3,3]
     }
     */
    func thenFlatMap<U: Thenable>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> U) -> Guarantee<[U.T.Iterator.Element]> where U.T: Sequence {
        return then(on: on, flags: flags) {
            when(fulfilled: $0.map(transform))
        }.map(on: nil) {
            $0.flatMap { $0 }
        }.recover {
            // if happens then is bug inside PromiseKit
            fatalError(String(describing: $0))
        }
    }
    
    /**
     `Guarantee<[T]>` => `T` -> Bool => `Guarantee<[T]>`
     
     Guarantee.value([1,2,3])
     .filterValues { $0 > 1 }
     .done {
     // $0 => [2,3]
     }
     */
    func filterValues(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ isIncluded: @escaping(T.Iterator.Element) -> Bool) -> Guarantee<[T.Iterator.Element]> {
        return map(on: on, flags: flags) {
            $0.filter(isIncluded)
        }
    }
    
#if swift(>=4) && !swift(>=5.2)
    /**
     `Guarantee<[T]>` => `KeyPath<T, Bool>` => `Guarantee<[T]>`
     
     Guarantee.value([Person(name: "Max"), Person(name: "Roman", age: 26, isStudent: false), Person(name: "John", age: 23, isStudent: true)])
     .filterValues(\.isStudent)
     .done {
     // $0 => [Person(name: "John", age: 23, isStudent: true)]
     }
     */
    func filterValues(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, Bool>) -> Guarantee<[T.Iterator.Element]> {
        return map(on: on, flags: flags) {
            $0.filter { $0[keyPath: keyPath] }
        }
    }
#endif
    
    /**
     `Guarantee<[T]>` => (`T`, `T`) -> Bool => `Guarantee<[T]>`
     
     Guarantee.value([5,2,3,4,1])
     .sortedValues { $0 > $1 }
     .done {
     // $0 => [5,4,3,2,1]
     }
     */
    func sortedValues(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ areInIncreasingOrder: @escaping(T.Iterator.Element, T.Iterator.Element) -> Bool) -> Guarantee<[T.Iterator.Element]> {
        return map(on: on, flags: flags) {
            $0.sorted(by: areInIncreasingOrder)
        }
    }
}

public extension Guarantee where T: Sequence, T.Iterator.Element: Comparable {
    /**
     `Guarantee<[T]>` => `Guarantee<[T]>`
     
     Guarantee.value([5,2,3,4,1])
     .sortedValues()
     .done {
     // $0 => [1,2,3,4,5]
     }
     */
    func sortedValues(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil) -> Guarantee<[T.Iterator.Element]> {
        return map(on: on, flags: flags) { $0.sorted() }
    }
}

#if swift(>=3.1)
public extension Guarantee where T == Void {
    convenience init() {
        self.init(box: SealedBox(value: Void()))
    }
    
    static var value: Guarantee<Void> {
        return .value(Void())
    }
}
#endif


public extension DispatchQueue {
    /**
     Asynchronously executes the provided closure on a dispatch queue.
     
     DispatchQueue.global().async(.promise) {
     md5(input)
     }.done { md5 in
     //…
     }
     
     - Parameter body: The closure that resolves this promise.
     - Returns: A new `Guarantee` resolved by the result of the provided closure.
     - Note: There is no Promise/Thenable version of this due to Swift compiler ambiguity issues.
     */
    @available(macOS 10.10, iOS 2.0, tvOS 10.0, watchOS 2.0, *)
    final func async<T>(_: PMKNamespacer, group: DispatchGroup? = nil, qos: DispatchQoS = .default, flags: DispatchWorkItemFlags = [], execute body: @escaping () -> T) -> Guarantee<T> {
        let rg = Guarantee<T>(.pending)
        async(group: group, qos: qos, flags: flags) {
            rg.box.seal(body())
        }
        return rg
    }
}


#if os(Linux)
import func CoreFoundation._CFIsMainThread

extension Thread {
    // `isMainThread` is not implemented yet in swift-corelibs-foundation.
    static var isMainThread: Bool {
        return _CFIsMainThread()
    }
}
#endif
