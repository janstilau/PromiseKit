import Dispatch

/*
    异步任务的抽象.
    这个异步任务, 可以添加后续操作. 而这个后续操作, 是对结果进行 Check 的基础上进行的. 要判断, 是 Fulfilled, 还是 Rejected.
    这在 JS 里面, 是分为了两个函数了. onResolved 和 onRjected. 
    可以查看当前的状态.
 */
/// Thenable represents an asynchronous operation that can be chained.
public protocol Thenable: AnyObject {
    /// The type of the wrapped value
    // T 代表的是, 这个异步操作的返回值. 是使用者最为关心的业务类型.
    associatedtype T
    
    /// `pipe` is immediately executed when this `Thenable` is resolved
    // Pipe 里面, 存储的是, 当一个 Promise 变为 Resolved 的状态之后, 应该执行的回调.
    func pipe(to: @escaping(Result<T>) -> Void)
    
    /// The resolved result or nil if pending.
    // 给与使用者, 一个权利去查看一下当前的 Result. 如果还是在 Pending, 那就是 Nil. 否则, 就是 Result<T>. 可能是 Fulfilled, 也可能是 Rejected
    var result: Result<T>? { get }
}

public extension Thenable {
    /*
     The provided closure executes when this promise is fulfilled. // 只用传递成功的值.
     
     This allows chaining promises. The promise returned by the provided closure is resolved before the promise returned by this closure resolves. // Body 生成的 Promise, 状态改变, 触发返回的 Promise 的状态改变.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that executes when this promise is fulfilled. It must return a promise.
     - Returns: A new promise that resolves when the promise returned from the provided closure resolves. For      */
    /*
        Swift 版本的 Then, 只是传递了 Fulfilled 状态下的处理回调.
        而 Rejected 状态下的回调, 是默认进行处理了.
     */
    func then<U: Thenable>(on: DispatchQueue? = conf.Q.map,
                           flags: DispatchWorkItemFlags? = nil,
                           _ body: @escaping(T) throws -> U) -> Promise<U.T> {
            
        // RP 
        let rp = Promise<U.T>(.pending)
        
        /*
            Pipe 里面, 传递的是, 当异步任务变为 Resolved 之后的后续操作.
            then 方法, 只传递了 Fulfilled 的后续操作. 所以, 是 then 方法内部, 添加了 Rejcted 状态的后续操作.
            那就是, 将 RP 变为 Rejected.
         */
        pipe {
            switch $0 {
            case .fulfilled(let value):
                // 如果, 是 fulfilled 态, 那么就开启一个新的任务.
                // 在这个新的任务上, 使用 Body 创建一个新的 Promise.
                // 并且, 将新创建 Promise 的后续, 和 Rp 的值的改变, 绑定在了一起.
                // 这样, RV 的状态, 才直接决定了 Rp 的状态.
                on.async(flags: flags) {
                    do {
                        let rv = try body(value)
                        guard rv !== rp else { throw PMKError.returnedSelf }
                        rv.pipe(to: rp.box.seal)
                    } catch {
                        rp.box.seal(.rejected(error))
                    }
                }
            case .rejected(let error):
                // 如果, 是 Rejected, 直接就把 rp 的值, 改变为 rejected 了.
                // Body 根本就不会调用. 
                rp.box.seal(.rejected(error))
            }
        }
        
        // RP 提前返回, 后面继续调用 then, 在 Rp 上添加 Handler.
        // 而 Rp 的状态, 是在当前的 Promise Resolved 之后才会决定的.
        return rp
    }
    
    /*
     The provided closure is executed when this promise is fulfilled.
     
     This is like `then` but it requires the closure to return a non-promise.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter transform: The closure that is executed when this Promise is fulfilled. It must return a non-promise.
     - Returns: A new promise that is fulfilled with the value returned from the provided closure or rejected if the provided closure throws. For example:
     }
     */
    // Map 中, Body 不再是返回一个 Promise, 而是根据上一个异步操作的结果生成一个新的值.
    // 而这个新生成的值, 会是 Rp 的结果, 然后传递到 RP 的 Handler 里面去.
    // 这是一个经常会使用的函数, 因为, 并不是中间每一个步骤, 都要开启一个异步任务的.
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
                rp.box.seal(.rejected(error))
            }
        }
        
        return rp
    }
    
    /**
     The provided closure is executed when this promise is fulfilled.
     
     In your closure return an `Optional`, if you return `nil` the resulting promise is rejected with `PMKError.compactMap`, otherwise the promise is fulfilled with the unwrapped value.
     
     firstly {
     URLSession.shared.dataTask(.promise, with: url)
     }.compactMap {
     try JSONSerialization.jsonObject(with: $0.data) as? [String: String]
     }.done { dictionary in
     //…
     }.catch {
     // either `PMKError.compactMap` or a `JSONError`
     }
     */
    func compactMap<U>(on: DispatchQueue? = conf.Q.map,
                       flags: DispatchWorkItemFlags? = nil,
                       _ transform: @escaping(T) throws -> U?) -> Promise<U> {
        let rp = Promise<U>(.pending)
        
        pipe {
            switch $0 {
            case .fulfilled(let value):
                on.async(flags: flags) {
                    do {
                        if let rv = try transform(value) {
                            rp.box.seal(.fulfilled(rv))
                        } else {
                            throw PMKError.compactMap(value, U.self)
                        }
                    } catch {
                        rp.box.seal(.rejected(error))
                    }
                }
            case .rejected(let error):
                rp.box.seal(.rejected(error))
            }
        }
        
        return rp
    }
    
    /**
     The provided closure is executed when this promise is fulfilled.
     
     Equivalent to `map { x -> Void in`, but since we force the `Void` return Swift
     is happier and gives you less hassle about your closure’s qualification.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that is executed when this Promise is fulfilled.
     - Returns: A new promise fulfilled as `Void` or rejected if the provided closure throws.
     }
     */
    func done(on: DispatchQueue? = conf.Q.return,
              flags: DispatchWorkItemFlags? = nil, _ body: @escaping(T) throws -> Void) -> Promise<Void> {
        // 固定下来了, Result 的类型.
        let rp = Promise<Void>(.pending)
        
        pipe {
            switch $0 {
            case .fulfilled(let value):
                on.async(flags: flags) {
                    do {
                        try body(value)
                        rp.box.seal(.fulfilled(()))
                    } catch {
                        rp.box.seal(.rejected(error))
                    }
                }
            case .rejected(let error):
                rp.box.seal(.rejected(error))
            }
        }
        
        return rp
    }
    
    /*
     The provided closure is executed when this promise is fulfilled.
     
     This is like `done` but it returns the same value that the handler is fed.
     `get` immutably accesses the fulfilled value; the returned Promise maintains that value.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that is executed when this Promise is fulfilled.
     - Returns: A new promise that is fulfilled with the value that the handler is fed or rejected if the provided closure throws. For example:
     */
    
    /*
        这里, 有点函数式编程的味道.
        所有的, 都是建立在 Pipe 的基础上, Pipe, 是给 Primise 变为 RESOLVED 态度添加回调.
        Map, 是在 fulfilled 的基础上, 增加对于 Result 的处理.
        而, get, 则是利用了 map. 返回的还是原始值, 仅仅在其中, 增加了一个自定义的执行的闭包.
        这里其实还是符合 Map 的定义, T->T, 只不过, 这里是 identify 的 Map.
     */
    func get(on: DispatchQueue? = conf.Q.return,
             flags: DispatchWorkItemFlags? = nil,
             _ body: @escaping (T) throws -> Void) -> Promise<T> {
        
        return map(on: on, flags: flags) {
            try body($0)
            return $0
        }
    }
    
    /*
     The provided closure is executed with promise result.
     
     This is like `get` but provides the Result<T> of the Promise so you can inspect the value of the chain at this point without causing any side effects.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that is executed with Result of Promise.
     - Returns: A new promise that is resolved with the result that the handler is fed. For example:
     
     promise.tap{ print($0) }.then{ /*…*/ }
     */
    func tap(on: DispatchQueue? = conf.Q.map,
             flags: DispatchWorkItemFlags? = nil,
             _ body: @escaping(Result<T>) -> Void) -> Promise<T> {
        /*
            新生成的 Promise 的 Executor 就是, 在当前的 Promise 上, 增加一个 Handler.
            执行 Body 函数, 然后, 根据当前 Promise 的状态, 来决定新生成的 Primose 的状态.
         */
        return Promise { seal in
            pipe { result in
                on.async(flags: flags) {
                    body(result)
                    seal.resolve(result)
                }
            }
        }
    }
    
    /// - Returns: a new promise chained off this promise but with its value discarded.
    func asVoid() -> Promise<Void> {
        return map(on: nil) { _ in }
    }
}

public extension Thenable {
    /**
     - Returns: The error with which this promise was rejected; `nil` if this promise is not rejected.
     */
    var error: Error? {
        switch result {
        case .none:
            return nil
        case .some(.fulfilled):
            return nil
        case .some(.rejected(let error)):
            return error
        }
    }
    
    /**
     - Returns: `true` if the promise has not yet resolved.
     */
    var isPending: Bool {
        return result == nil
    }
    
    /**
     - Returns: `true` if the promise has resolved.
     */
    var isResolved: Bool {
        return !isPending
    }
    
    /**
     - Returns: `true` if the promise was fulfilled.
     */
    var isFulfilled: Bool {
        return value != nil
    }
    
    /**
     - Returns: `true` if the promise was rejected.
     */
    var isRejected: Bool {
        return error != nil
    }
    
    /**
     - Returns: The value with which this promise was fulfilled or `nil` if this promise is pending or rejected.
     */
    var value: T? {
        switch result {
        case .none:
            return nil
        case .some(.fulfilled(let value)):
            return value
        case .some(.rejected):
            return nil
        }
    }
}

public extension Thenable where T: Sequence {
    /**
     `Promise<[T]>` => `T` -> `U` => `Promise<[U]>`
     
     firstly {
     .value([1,2,3])
     }.mapValues { integer in
     integer * 2
     }.done {
     // $0 => [2,4,6]
     }
     */
    func mapValues<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U]> {
        return map(on: on, flags: flags){ try $0.map(transform) }
    }
    
#if swift(>=4) && !swift(>=5.2)
    /**
     `Promise<[T]>` => `KeyPath<T, U>` => `Promise<[U]>`
     
     firstly {
     .value([Person(name: "Max"), Person(name: "Roman"), Person(name: "John")])
     }.mapValues(\.name).done {
     // $0 => ["Max", "Roman", "John"]
     }
     */
    func mapValues<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, U>) -> Promise<[U]> {
        return map(on: on, flags: flags){ $0.map { $0[keyPath: keyPath] } }
    }
#endif
    
    /**
     `Promise<[T]>` => `T` -> `[U]` => `Promise<[U]>`
     
     firstly {
     .value([1,2,3])
     }.flatMapValues { integer in
     [integer, integer]
     }.done {
     // $0 => [1,1,2,2,3,3]
     }
     */
    func flatMapValues<U: Sequence>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.Iterator.Element]> {
        return map(on: on, flags: flags){ (foo: T) in
            try foo.flatMap{ try transform($0) }
        }
    }
    
    /**
     `Promise<[T]>` => `T` -> `U?` => `Promise<[U]>`
     
     firstly {
     .value(["1","2","a","3"])
     }.compactMapValues {
     Int($0)
     }.done {
     // $0 => [1,2,3]
     }
     */
    func compactMapValues<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U?) -> Promise<[U]> {
        return map(on: on, flags: flags) { foo -> [U] in
#if !swift(>=3.3) || (swift(>=4) && !swift(>=4.1))
            return try foo.flatMap(transform)
#else
            return try foo.compactMap(transform)
#endif
        }
    }
    
#if swift(>=4) && !swift(>=5.2)
    /**
     `Promise<[T]>` => `KeyPath<T, U?>` => `Promise<[U]>`
     
     firstly {
     .value([Person(name: "Max"), Person(name: "Roman", age: 26), Person(name: "John", age: 23)])
     }.compactMapValues(\.age).done {
     // $0 => [26, 23]
     }
     */
    func compactMapValues<U>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, U?>) -> Promise<[U]> {
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
     `Promise<[T]>` => `T` -> `Promise<U>` => `Promise<[U]>`
     
     firstly {
     .value([1,2,3])
     }.thenMap { integer in
     .value(integer * 2)
     }.done {
     // $0 => [2,4,6]
     }
     */
    func thenMap<U: Thenable>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.T]> {
        return then(on: on, flags: flags) {
            when(fulfilled: try $0.map(transform))
        }
    }
    
    /**
     `Promise<[T]>` => `T` -> `Promise<[U]>` => `Promise<[U]>`
     
     firstly {
     .value([1,2,3])
     }.thenFlatMap { integer in
     .value([integer, integer])
     }.done {
     // $0 => [1,1,2,2,3,3]
     }
     */
    func thenFlatMap<U: Thenable>(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.T.Iterator.Element]> where U.T: Sequence {
        return then(on: on, flags: flags) {
            when(fulfilled: try $0.map(transform))
        }.map(on: nil) {
            $0.flatMap{ $0 }
        }
    }
    
    /**
     `Promise<[T]>` => `T` -> Bool => `Promise<[T]>`
     
     firstly {
     .value([1,2,3])
     }.filterValues {
     $0 > 1
     }.done {
     // $0 => [2,3]
     }
     */
    func filterValues(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ isIncluded: @escaping (T.Iterator.Element) -> Bool) -> Promise<[T.Iterator.Element]> {
        return map(on: on, flags: flags) {
            $0.filter(isIncluded)
        }
    }
    
#if swift(>=4) && !swift(>=5.2)
    /**
     `Promise<[T]>` => `KeyPath<T, Bool>` => `Promise<[T]>`
     
     firstly {
     .value([Person(name: "Max"), Person(name: "Roman", age: 26, isStudent: false), Person(name: "John", age: 23, isStudent: true)])
     }.filterValues(\.isStudent).done {
     // $0 => [Person(name: "John", age: 23, isStudent: true)]
     }
     */
    func filterValues(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, Bool>) -> Promise<[T.Iterator.Element]> {
        return map(on: on, flags: flags) {
            $0.filter { $0[keyPath: keyPath] }
        }
    }
#endif
}

public extension Thenable where T: Collection {
    /// - Returns: a promise fulfilled with the first value of this `Collection` or, if empty, a promise rejected with PMKError.emptySequence.
    var firstValue: Promise<T.Iterator.Element> {
        return map(on: nil) { aa in
            if let a1 = aa.first {
                return a1
            } else {
                throw PMKError.emptySequence
            }
        }
    }
    
    func firstValue(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil, where test: @escaping (T.Iterator.Element) -> Bool) -> Promise<T.Iterator.Element> {
        return map(on: on, flags: flags) {
            for x in $0 where test(x) {
                return x
            }
            throw PMKError.emptySequence
        }
    }
    
    /// - Returns: a promise fulfilled with the last value of this `Collection` or, if empty, a promise rejected with PMKError.emptySequence.
    var lastValue: Promise<T.Iterator.Element> {
        return map(on: nil) { aa in
            if aa.isEmpty {
                throw PMKError.emptySequence
            } else {
                let i = aa.index(aa.endIndex, offsetBy: -1)
                return aa[i]
            }
        }
    }
}

public extension Thenable where T: Sequence, T.Iterator.Element: Comparable {
    /// - Returns: a promise fulfilled with the sorted values of this `Sequence`.
    func sortedValues(on: DispatchQueue? = conf.Q.map, flags: DispatchWorkItemFlags? = nil) -> Promise<[T.Iterator.Element]> {
        return map(on: on, flags: flags){ $0.sorted() }
    }
}
