import Dispatch

// 必须是一个 引用类型.
public protocol Thenable: AnyObject {
    
    // T 代表的是, 这个异步操作的返回值. 是使用者最为关心的业务类型.
    associatedtype T
    
    // 当, 从 Pending 到 Resolved 之后, 应该触发的回调.
    func pipe(to: @escaping(Result<T>) -> Void)
    
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
        
        /*
         Pipe 是向当前的 Promise 添加, 当前的 Promise 从 Pennding 到 Resolved 的时候, 应该触发的回调.
         */
        pipe {
            switch $0 {
            case .fulfilled(let value):
                // 和 JS 的 Promise 一样, 这里会有一个异步调度.
                on.async(flags: flags) {
                    // 如果, Body 的调用过程中, 触发了异常, RP 直接变为 Rejected 的状态.
                    do {
                        let rv = try body(value)
                        guard rv !== rp else { throw PMKError.returnedSelf }
                        // Rv 的 Promise 的状态, 决定了 Return Promise 的状态.
                        // 这就是 Promise 节点可以按照顺序串行的原因所在.
                        // 上一个节点 Resolved 之后, 触发下一个节点的异步行为发生, 而异步行为的结果导致当前节点的状态改变, 才会触发下下节点的异步行为发生.
                        // 所以响应链条刚开始创建的时候, 各个节点都是 Pending 状态, 一个个节点的异步行为结束后, 才会改变自己节点的状态.
                        // 这和我们使用 Block 的串行逻辑是一样的.
                        rv.pipe(to: rp.box.seal)
                    } catch {
                        rp.box.seal(.rejected(error))
                    }
                }
            case .rejected(let error): // 上游节点的错误直接Forward.
                // 如果, 是 Rejected, 直接就把 rp 的值, 改变为 rejected 了.
                // Body 根本就不会调用.
                // Error 这种 Forward 的行为, 是 Catch 虽然在最后添加, 但是可以作为所有中间节点的错误处理的原因所在.
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
     不过有一点没有变, 就是上一个节点的 Resolved 状态, 触发下一个节点的异步行为, 然后异步行为结果, 导致当前节点的状态改变.
     */
    func map<U>(on: DispatchQueue? = conf.Q.map,
                flags: DispatchWorkItemFlags? = nil,
                _ transform: @escaping(T) throws -> U) -> Promise<U> {
        let rp = Promise<U>(.pending)
        
        pipe {
            switch $0 {
            case .fulfilled(let value):
                // 在 Promise 里面,
                on.async(flags: flags) {
                    do {
                        // 使用 transform 来操作上游节点的状态值, 将 map 节点的状态值, 使用 transfrom 结果的值进行 seal
                        rp.box.seal(.fulfilled(try transform(value)))
                    } catch {
                        rp.box.seal(.rejected(error))
                    }
                }
            case .rejected(let error): // 上游节点的错误直接Forward.
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
            case .rejected(let error): // 上游节点的错误直接Forward.
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
    // 将 Ele 的类型, 转换成为了 (). 其实还是一个 Promise, 只不过下游节点无法获取有效的数据了.
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
                        // 当前的节点, 直接使用 () 进行 seal.
                        rp.box.seal(.fulfilled(()))
                    } catch {
                        rp.box.seal(.rejected(error))
                    }
                }
            case .rejected(let error): // 上游节点的错误直接Forward.
                rp.box.seal(.rejected(error))
            }
        }
        
        // 这还是, 返回一个 Promise. 所以后面还是可以加 Catch 的.
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
     Get 中传入的 Body, 没有任何副作用, 仅仅是获取到上游节点的状态值, 然后调用. 不会影响到下游节点的流转.
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
    // 和 Get 功能差不多, 但是 Get 中使用的是 Map, 而 Map 只会在上游节点 Fulfilled 的时候才会调用.
    // Tap 则是使用的 Pipe, 直接获取到上游节点的 Result 值, 调用 body 仅仅是使用了这个值, 不会影响到后续的节点.
    func tap(on: DispatchQueue? = conf.Q.map,
             flags: DispatchWorkItemFlags? = nil,
             _ body: @escaping(Result<T>) -> Void) -> Promise<T> {
        return Promise { seal in
            pipe { result in
                on.async(flags: flags) {
                    // 直接使用了 Result<T> 类型的值.
                    body(result)
                    // 直接使用上游节点的状态, 来决定当前节点的状态.
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
    // 一个 Get 函数, 只有在 rejected 下才会返回.
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
    // 只有在 fulfilled 的情况下, 才会返回.
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
