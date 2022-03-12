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
        return .init(box: SealedBox(value: value))
    }
    
    //    let box: Box<Result<T>>
    // 上面的是 Promise 的 box 的类型, 是 Result T 类型的. 所以 Box 里面可能会有 pending, fulfilled, rejected 的三种状态.
    
    //  而 Guarantee 里面的, 仅仅是 T 状态, 所以只会有 pending, fulfilled 两种状态.
    // 而这就是为什么 Box 也是泛型类的原因, 在 Resolved 的状态下, 是否成功, 是根据 类型参数决定的. 对于 Guarantee 来说, 只会存储 T 类型本身的值.
    let box: PromiseKit.Box<T>
    
    fileprivate init(box: SealedBox<T>) {
        self.box = box
    }
    
    /// Returns a pending `Guarantee` that can be resolved with the provided closure’s parameter.
    /*
     这是一个非常重要的函数. 类比 Observable.Create
     body 是一个闭包, 外界提供的. Guarantee 要在内部调用这个闭包.
     这个闭包的参数, 也是一个闭包. 这是 Guarantee 内部传递出去的, 外界使用这个闭包, 来触发 Guarantee 的内部逻辑.
     
     这个 Init 理解为.
     外界传递一个 body 进来, body 的参数, 是一个闭包
     body 会在 Guarantee.init 中调用, 是 Guarantee 主动调用外部的逻辑.
     一般来说, 这个逻辑是创建一个异步操作.
     body 参数是一个闭包, body 的内部, 要在合适的时机调用这个闭包, 这个闭包的会改变 Guarantee 的内部状态.
     */
    public init(resolver body: (@escaping(T) -> Void) -> Void) {
        box = Box()
        body(box.seal)
    }
    
    /// - See: `Thenable.pipe`
    public func pipe(to: @escaping(Result<T>) -> Void) {
        pipe {
            to(.fulfilled($0))
        }
    }
    
    /*
     Promise 的实现:
     public func pipe(to: @escaping(Result<T>) -> Void) {
     // 这里有一个 double check 的机制.
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
     */
    // 这里, Guarantee 的实现和 Promise 是一致的
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
    
    /*
     func done(on: DispatchQueue? = conf.Q.return,
     flags: DispatchWorkItemFlags? = nil,
     // 这是最终点了, 并且,
     _ body: @escaping(T) throws -> Void) -> Promise<Void> {
     
     // 固定下来了, Result 的类型.
     // 就是使用, 上一个 Promise 的值, 做一个动作. 不会将这个值, 向后传递了.
     let rp = Promise<Void>(.pending)
     
     pipe {
     switch $0 {
     case .fulfilled(let value):
     on.async(flags: flags) {
     do {
     // 仅仅是进行了 Body 的调用, 不会使用返回值.
     try body(value)
     // 然后 return promise 使用 Void 进行 seal
     rp.box.seal(.fulfilled(()))
     } catch {
     rp.box.seal(.rejected(error))
     }
     }
     case .rejected(let error):
     rp.box.seal(.rejected(error))
     }
     }
     */
    // 同 Promise 的版本相比, 不需要判断上游节点的 reject 状态. body 还是直接调用, 然后给 return gurantee seal 一个 Void 的值.
    @discardableResult
    func done(on: DispatchQueue? = conf.Q.return,
              flags: DispatchWorkItemFlags? = nil,
              _ body: @escaping(T) -> Void) -> Guarantee<Void> {
        let rg = Guarantee<Void>(.pending)
        
        pipe { (value: T) in
            on.async(flags: flags) {
                // 使用 body, 触发回调.
                body(value)
                // 对返回的 return guarantee 进行状态改变.
                rg.box.seal(())
            }
        }
        
        // Done 返回的还是一个 Promise, 所以还能进行后续的 Promise 相关函数的调用.
        // 但是里面的 Element 的类型是 Void, 所以后续的节点, 其实是拿不到数据的, 只会拿到事件发生的这个信号.
        return rg
    }
    
    // 这里和 Promise 没有太多区别.
    func get(on: DispatchQueue? = conf.Q.return,
             flags: DispatchWorkItemFlags? = nil,
             _ body: @escaping (T) -> Void) -> Guarantee<T> {
        return map(on: on, flags: flags) {
            body($0)
            return $0
        }
    }
    
    /*
     func map<U>(on: DispatchQueue? = conf.Q.map,
     flags: DispatchWorkItemFlags? = nil,
     _ transform: @escaping(T) throws -> U) -> Promise<U> {
     let rp = Promise<U>(.pending)
     
     pipe {
     switch $0 {
     case .fulfilled(let value):
     on.async(flags: flags) {
     do {
     rp.box.seal(.fulfilled(try transform(value)))
     } catch {
     rp.box.seal(.rejected(error))
     }
     }
     case .rejected(let error):
     // 只要是错误, 就无缝传递, 这样最后的一个 catch 才能进行统一处理.
     rp.box.seal(.rejected(error))
     }
     }
     
     return rp
     }
     */
    // 同 Promise 的版本相比, 少了对于 reject 的判断.
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
    
    
    /*
     func then<U: Thenable>(on: DispatchQueue? = conf.Q.map,
     flags: DispatchWorkItemFlags? = nil,
     // Body 的含义是, 根据当前 Resolved 的值, 他可以生成一个新的 Thenable 对象.
     _ body: @escaping(T) throws -> U) -> Promise<U.T> {
     // 生成一个 Result Promise.
     let rp = Promise<U.T>(.pending)
     
     pipe {
     // Pipe 传递过来的 Handler, 一定会是在 Resolved 的状态下才会调用.
     switch $0 {
     case .fulfilled(let value):
     on.async(flags: flags) {
     // 如果, Body 的调用过程中, 触发了异常, RP 直接变为 Rejected 的状态.
     do {
     let rv = try body(value)
     guard rv !== rp else { throw PMKError.returnedSelf }
     // body 创建出来的 Promise 的状态, 直接决定了 return promise 的状态.
     rv.pipe(to: rp.box.seal)
     } catch {
     rp.box.seal(.rejected(error))
     }
     }
     case .rejected(let error):
     // 如果, 是 Rejected, 直接就把 rp 的值, 改变为 rejected 了.
     // Body 根本就不会调用.
     // 这个 Error 完全不会进行修改, 从第一个出错的 Promise 的地方, 无任何修改的, 传递到了后面.
     rp.box.seal(.rejected(error))
     }
     }
     
     // RP 提前返回, 后面继续调用 then, 在 Rp 上添加 Handler.
     // 而 Rp 的状态, 是在当前的 Promise Resolved 之后才会决定的.
     return rp
     }
     */
    /*
     Guarantee 里面的 then 方法
     1. 没有 switch 的判断, 因为 Gurantee 保证了, 一定会有值.
     2. 返回值一定还是 Guarantee 类型的, 不过绑定的类型参数, 变为了 U .
     */
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
