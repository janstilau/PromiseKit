import Dispatch

/*
 异步任务的抽象.
 1.   这个异步任务, 可以添加后续操作. 而这个后续操作, 是对结果进行 Check 的基础上进行的.
 要判断, 是 Fulfilled, 还是 Rejected.
 这在 JS 里面, 是 Then 里面, 添加两个函数. onResolved, onRejected 两个函数.
 2.  可以查看当前的状态.
 */

public protocol Thenable: AnyObject {
    /// The type of the wrapped value
    // T 代表的是, 这个异步操作的返回值. 是使用者最为关心的业务类型.
    associatedtype T
    
    /// `pipe` is immediately executed when this `Thenable` is resolved
    /*
     这是最原始, 添加闭包回调的方式, 并不要求返回一个 Promise 回来.
     但是, 它的处理的值, 是一个 Result 的值, 而不是一个业务的 T 的值.
     所以, pipe 后的逻辑, 是根据当前 Promise 的 Resolved 的 Fulfilled 和 Rejected 两种状态值, 进行不同的操作.
     */
    
    /*
     这是一个, 自由度非常非常大的函数.
     各种操作, 基本上是通过, 自定义回调函数的方式实现的.
     Pipe 的操作, 是判断状态, 存储回调函数的机制 .
     而回调函数的不同, 导致了后面不同的操作.
     */
    func pipe(to: @escaping(Result<T>) -> Void)
    
    /// The resolved result or nil if pending.
    // 给与使用者, 一个权利去查看一下当前的 Result. 如果还是在 Pending, 那就是 Nil.
    // 如果, 是 Resolved 的, 那么返回的是一个 Result.
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
    /*
     和 JS 的 Then 不同, 这里的 Then, 传递的仅仅是 Fulfilled 状态下, 应该触发的异步操作.
     因为, 在 Then 的内部, 自动处理了其他情况.
     */
    func then<U: Thenable>(on: DispatchQueue? = conf.Q.map,
                           flags: DispatchWorkItemFlags? = nil,
                           _ body: @escaping(T) throws -> U) -> Promise<U.T> {
        
        // RP
        let rp = Promise<U.T>(.pending)
        
        /*
         Pipe 里面, 是 Pending -> Resoled 状态时, 应该触发的操作.
         而 Resolved 下, 是一个 Result, Result 会有两种状态.
         then 方法, 只传递了 Fulfilled 的后续操作. 在 then 方法内部, 添加了默认的 Rejected 状态下的处理方法.
         那就是, 将 RP 变为 Rejected.
         */
        pipe {
            switch $0 {
            case .fulfilled(let value):
                // 如果, 是 fulfilled 态, 那么就开启一个新的任务.
                // 在这个新的任务上, 使用 Body 创建一个新的 Promise.
                // 新创建的 Promise 的回调, 是改变 Return 的 RP 的状态.
                // 这样, RV 的状态变化, 就可以触发 RP 添加的各种回调了.
                on.async(flags: flags) {
                    // 这种, 异步触发的方式, 是和 JS 一致的.
                    // 如果, Body 的调用过程中, 触发了异常, RP 直接变为 Rejected 的状态. 
                    do {
                        let rv = try body(value)
                        guard rv !== rp else { throw PMKError.returnedSelf }
                        // RV 的状态变化的回调, 是触发 RP 的状态变化.
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
    /*
        这在 RXSwift 里面, 也是经常使用的一个方法. Map 的含义就是映射, 添加这样的一个中间步骤, 并不添加任何的异步操作, 仅仅是值的变化. 
     */
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
                        // 如果, Transform 能够返回值, 就讲 Rp 的值, 变为返回的 U 类型的值.
                        // 不然, 就讲 Rp 的值, 变为 Rejected. PMKError.compactMap(value, U.self)
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
        // 就是使用, 上一个 Promise 的值, 做一个动作. 不同将值在继续往后传递了.
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
        以上, 所有的方法, 都是在 Fulfilled 的状态下, 做的操作.
        在 Reject 状态下, 只是做 Error 的传递.
     
        这里, 利用了 Map 的处理机制. 在获取到上一个 Promise 的值后, 做了一件事情, 然后这个值, 原封不动的, 继续向后传递.
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
            Get 是拿到上一个 Promise 的 Fulfill 的值之后, 进行操作.
            Tap 是拿到上一个 Primise 的 Result 的值之后, 进行操作.
         
            新生成一个 Promise, 它的值, 知道当前的 Promise 得到结果之后, 才会决定.
            这种, 通过传递一个 executor 来生成 Promise 的操作, 和 JS 里面就非常像了. 
         */
        
//
//        let rp = Promise<T>(.pending)
//
//        pipe { result in
//            on.async(flags: flags) {
//                body(result)
//                rp.box.seal(result)
//            }
//        }
//
//        return rp
        
        // 应该, 用上面的写法, 也能实现效果.
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
    /*
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
