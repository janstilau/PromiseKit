import class Foundation.Thread
import Dispatch

/*
 A `Guarantee` is a functional abstraction around an asynchronous operation that cannot error.
 - See: `Thenable`
*/

// 这是一个和 Promise 同级的类.
/*
 它也是 Thenable. 所以可以调用 Thenable Extension 中的各个方法.
 Guarantee 的值向后传递, 中间节点可能出现错误, 所以调用 Thenable Extension 的各个方法还是返回 Promise.
 在下面, 如果能够确定中间节点不会出错, 返回值就能变为 Guarantee
 */
public final class Guarantee<T>: Thenable {
    // Box 里面, 装的是 T, 不是 ResultT.
    let box: PromiseKit.Box<T>

    fileprivate init(box: SealedBox<T>) {
        self.box = box
    }

    /// Returns a `Guarantee` sealed with the provided value.
    public static func value(_ value: T) -> Guarantee<T> {
        return .init(box: SealedBox(value: value))
    }

    /// Returns a pending `Guarantee` that can be resolved with the provided closure’s parameter.
    public init(resolver body: (@escaping(T) -> Void) -> Void) {
        box = Box()
        body(box.seal)
    }

    /// - See: `Thenable.pipe`
    public func pipe(to: @escaping(Result<T>) -> Void) {
        pipe{
            to(.fulfilled($0))
        }
    }

    func pipe(to: @escaping(T) -> Void) {
        // 这里面的逻辑, 和 Promise 是完全一致的.
        // 不同的是, Promise 里面存储的是 Result<T>, Guarantee 里面则是 T.
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
                PromiseKit.shareConf.logHandler(.pendingGuaranteeDeallocated)
            case .resolved:
                break
            }
        }
    }

    init(_: PMKUnambiguousInitializer) {
        box = Box()
    }

    /// Returns a tuple of a pending `Guarantee` and a function that resolves it.
    public class func pending() -> (guarantee: Guarantee<T>, resolve: (T) -> Void) {
        let value = Guarantee<T>(.pending)
        return (value, value.box.seal)
    }
}

public extension Guarantee {
    // Get 不会触发 error, 所以可以确定返回的是 Guarantee
    // Guarantee 和 Thenable 同时定义了这 get 方法, 不同的是 Thenable 中有 throw. 当传入的闭包会 throw 的时候, 返回 Promise, 不然返回 Guarantee
    // 编译器很强大.
    func get(on: DispatchQueue? = shareConf.defaultQueue.end,
             flags: DispatchWorkItemFlags? = nil,
             _ body: @escaping (T) -> Void)
    -> Guarantee<T> {
        return map(on: on, flags: flags) {
            body($0)
            return $0
        }
    }

    // 这里的 Map 也是, throws body 进行了返回值的区分.
    func map<U>(on: DispatchQueue? = shareConf.defaultQueue.processing,
                flags: DispatchWorkItemFlags? = nil,
                _ body: @escaping(T) -> U)
    -> Guarantee<U> {
        let rg = Guarantee<U>(.pending)
        pipe { value in
            on.async(flags: flags) {
                rg.box.seal(body(value))
            }
        }
        return rg
    }

    // Done 也根据返回值的不同进行了区分.
    @discardableResult
    func done(on: DispatchQueue? = shareConf.defaultQueue.end,
              flags: DispatchWorkItemFlags? = nil,
              _ body: @escaping(T) -> Void)
    -> Guarantee<Void> {
        let rg = Guarantee<Void>(.pending)
        pipe { (value: T) in
            on.async(flags: flags) {
                body(value)
                rg.box.seal(())
            }
        }
        return rg
    }
    
    // 根据传入的 Body 返回值不同, 返回 Promise 还是 Guarantee
    @discardableResult
    func then<U>(on: DispatchQueue? = shareConf.defaultQueue.processing,
                 flags: DispatchWorkItemFlags? = nil,
                 _ body: @escaping(T) -> Guarantee<U>)
    -> Guarantee<U> {
        let rg = Guarantee<U>(.pending)
        pipe { value in
            // 这里就没有错误的判断了. 
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
            shareConf.logHandler(.waitOnMainThread)
        }

        var result = value

        // 将异步操作, 变为了同步获取的办法. 和信号量的获取没有区别. 只不过这里使用了 group 的方式.
        // Promise 初始化的时候, 就应该触发了异步操作, 等到异步操作结束之后, 触发这里添加的回调, 才能让 Group 解锁.
        if result == nil {
            let group = DispatchGroup()
            group.enter()
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
    func mapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> U) -> Guarantee<[U]> {
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
    func mapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, U>) -> Guarantee<[U]> {
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
    func flatMapValues<U: Sequence>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> U) -> Guarantee<[U.Iterator.Element]> {
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
    func compactMapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> U?) -> Guarantee<[U]> {
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
    func compactMapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, U?>) -> Guarantee<[U]> {
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
    func thenMap<U>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> Guarantee<U>) -> Guarantee<[U]> {
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
    func thenFlatMap<U: Thenable>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) -> U) -> Guarantee<[U.T.Iterator.Element]> where U.T: Sequence {
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
    func filterValues(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ isIncluded: @escaping(T.Iterator.Element) -> Bool) -> Guarantee<[T.Iterator.Element]> {
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
    func filterValues(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, Bool>) -> Guarantee<[T.Iterator.Element]> {
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
    func sortedValues(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ areInIncreasingOrder: @escaping(T.Iterator.Element, T.Iterator.Element) -> Bool) -> Guarantee<[T.Iterator.Element]> {
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
    func sortedValues(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil) -> Guarantee<[T.Iterator.Element]> {
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
