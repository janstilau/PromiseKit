import Dispatch

// 必须是一个 引用类型.
public protocol Thenable: AnyObject {
    
    // T 代表的是, 这个异步操作的返回值. 是使用者最为关心的业务类型.
    associatedtype T
    
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
     */
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
    
    /*
        The provided closure is executed when this promise is fulfilled.
        This is like `then` but it requires the closure to return a non-promise.
     */
    /*
     Swift 的强类型, 将 JS 中 Then 进行了分离.
     如果 Transform 返回的不是一个 Thenable, 那么直接在上一个 Promise Fullfill 之后, 直接进行 transform, 然后触发下一个 Promise 的状态改变.
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
                // 只要是错误, 就无缝传递, 这样最后的一个 catch 才能进行统一处理.
                rp.box.seal(.rejected(error))
            }
        }
        
        return rp
    }
    
    /*
     The provided closure is executed when this promise is fulfilled.
     
     In your closure return an `Optional`, if you return `nil` the resulting promise is rejected with `PMKError.compactMap`, otherwise the promise is fulfilled with the unwrapped value.
     
     firstly {
     URLSession.shared.dataTask(.promise, with: url)
     }.compactMap {
     // 从这里看, 这个 compactMap 是专门为 Swift 这种, 会有 Optianl 特殊的 Enum 而设计的函数.
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
                // 还是, 上游的错误直接传递.
                rp.box.seal(.rejected(error))
            }
        }
        
        return rp
    }
    
    /*
     The provided closure is executed when this promise is fulfilled.
     
     Equivalent to `map { x -> Void in`, but since we force the `Void` return Swift
     is happier and gives you less hassle about your closure’s qualification.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that is executed when this Promise is fulfilled.
     - Returns: A new promise fulfilled as `Void` or rejected if the provided closure throws.
     }
     */
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
        
        // 这还是, 返回一个 Promise. 所以后面还是可以加 Catch 的.
        // 只不过, RP 如果在 Fulfilled 的情况下, Result 是 Void 的了. 失去了数据队列的意义了.
        return rp
    }
    
    /*
        The provided closure is executed when this promise is fulfilled.
        This is like `done` but it returns the same value that the handler is fed.
        `get` immutably accesses the fulfilled value; the returned Promise maintains that value.
     */
    /*
        map 就是, 得到上一个 Promise 的结果值, 然后进行 transfrom, 将 transfrom 的值给与下一个 Promise 值.
        这里是利用了 Map 的副作用, 得到上一个 Promise 的值, 调用 body 函数, 然后直接返回上一个 Promise 的值.
        get 的 Body 不会影响到原有的异步执行链条.
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
        return Promise { seal in
            pipe { result in
                on.async(flags: flags) {
                    body(result)
                    // 新生成的 Promise, 还是使用 result 的值.
                    // Body 没有副作用.
                    seal.resolve(result)
                }
            }
        }
    }
    
    /// - Returns: a new promise chained off this promise but with its value discarded.
    func asVoid() -> Promise<Void> {
        // 这里增加了一个中间节点, 将自己的 Result 值 transfrom 为 Void
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
