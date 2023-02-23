import Dispatch
/*
 Promise 里面的代码少, 就是因为都放到了 Thenable 里面实现了.
 从实现的角度来说, Thenable 应该算作是 Promise 的抽象基类.
 */
/*
 Thenable
 1. 可以添加一个回调, 这个回调是当我状态确定的时候一定会执行, 参数是我当前的状态值.
 2. 可以返回我当前的状态.
 
 如果.
 给我添加了一个回调, 这个回调里面我将自身 Result 产生了另外一个值, 这个值用来决定另外的一个 Promise 的状态.
 这个 Promise 的状态确定后, 可以触发自己存储的回调.
 这就是 Map 的实现方式.
 Map 的这种实现方式, 就是按照节点顺序将值进行操作, 然后传递给后续节点中. 没有触发新的节点的生成.
 
 如果.
 给我添加了一个回调, 这个回调里面我将自身的 Result 产生了另外的一个中间节点 Promise.
 给这个中间节点添加一个回调. 当中间节点的状态 Resolved 之后, 会触发这个添加的回调.
 这个添加的回调里面, 来决定返回 Promise 的状态, 这个时候返回 Promise 的回调才会触发.
 这就是 Promise 实现异步连接的原理.
 在原本生成的 Promise 链条里面, 后一个节点的状态, 需要等到中间节点的 Resule 结果来确定, 而这个中间节点一般会伴随着异步操作.
 这样就达到了 Promise 进行一步操作链接的效果了.
 
 以上的这些, 都被 Thenable 封装到了 Map, Then 的实现里面, 所以 Promise 里面的逻辑很少.
 
 其实, JS 里面的 Promise 也是这样的一个抽象.
 给自己的 Resolved 的时刻, 增加接受 Result 的回调.
 */

/// Thenable represents an asynchronous operation that can be chained.
public protocol Thenable: AnyObject {
    /// The type of the wrapped value
    associatedtype T
    
    /// `pipe` is immediately executed when this `Thenable` is resolved
    // 给自己添加, Resolved 的时候, 触发的回调.
    // 如果自己已经 Resolved 了, 那么直接触发回调.
    func pipe(to: @escaping(Result<T>) -> Void)
    
    /// The resolved result or nil if pending.
    // 表达当前的状态值.
    var result: Result<T>? { get }
}


// 从上面的分析可以看出, 各种功能, 其实都建立在 Pipe 这个能力之上的.
// 提供闭包, 闭包有着无限的可配置性.

// 本来 func pipe(to: @escaping(Result<T>) -> Void) 只是添加 Resolved 回调.
// 经过下面 wrapper 方法的各种加工,
public extension Thenable {
    /*
     The provided closure executes when this promise is fulfilled.
     
     This allows chaining promises.
     // 中间生成的 Promise 先 resolve, return 的 Promise 后 resolve.
     The promise returned by the provided closure is resolved before the promise returned by this closure resolves.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that executes when this promise is fulfilled. It must return a promise.
     
     // 这里说的很明确, 两个 Promise 之间的关系.
     - Returns: A new promise that resolves when the promise returned from the provided closure resolves. For example:
      
     firstly {
     URLSession.shared.dataTask(.promise, with: url1)
     }.then { response in
     transform(data: response.data)
     }.done { transformation in
     //…
     }
     */
    // 这里的实现逻辑, 其实和 JS 版本没有什么不同.
    // 实际上, 连接异步操作的行为, 是直接定义在了 Thenable 的内部了.
    func then<U: Thenable>(on: DispatchQueue? = shareConf.defaultQueue.processing,
                           flags: DispatchWorkItemFlags? = nil,
                           _ body: @escaping(T) throws -> U)
    -> Promise<U.T> {
        let rp = Promise<U.T>(.pending)
        // 这个 Pipe 是 Self 调用的, 所以 Pipe 后面的闭包, 是当 Self Promise Resolved 的时候, 应该触发什么回调.
        // 被返回的 RP 的状态, 就在这个回调里面被 Resolved.
        pipe {
            // $0 是当前的 Promise 的 Result 值.
            switch $0 {
            case .fulfilled(let value):
                on.async(flags: flags) {
                    do {
                        let rv = try body(value)
                        guard rv !== rp else { throw PMKError.returnedSelf }
                        // 将两个 Promise 状态进行了触发关联.
                        rv.pipe(to: rp.box.seal)
                    } catch {
                        rp.box.seal(.rejected(error))
                    }
                }
            case .rejected(let error):
                // 如果上一个 Promise 已经发生了错误, 直接透传到下一个 Promise.
                rp.box.seal(.rejected(error))
            }
        }
        // 返回的 rp 可以继续 then, 添加自己的回调函数.
        // rp 可以调用 pipeto, 不过这个函数更多的应该是在框架内部进行调用.
        // 框架的使用者, 就调用 then, done, catch 这些方法就好了.
        return rp
    }
    
    /*
     The provided closure is executed when this promise is fulfilled.
     
     This is like `then` but it requires the closure to return a non-promise.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter transform: The closure that is executed when this Promise is fulfilled. It must return a non-promise.
     - Returns: A new promise that is fulfilled with the value returned from the provided closure or rejected if the provided closure throws. For example:
     
     firstly {
     URLSession.shared.dataTask(.promise, with: url1)
     }.map { response in
     response.data.length
     }.done { length in
     //…
     }
     */
    func map<U>(on: DispatchQueue? = shareConf.defaultQueue.processing,
                flags: DispatchWorkItemFlags? = nil,
                _ transform: @escaping(T) throws -> U)
    -> Promise<U> {
        let rp = Promise<U>(.pending)
        pipe {
            switch $0 {
            case .fulfilled(let value):
                // Js 里面, 是由类型判断完成的, 在 Swift 则是由特定的方法有着更加显式地表示.
                on.async(flags: flags) {
                    do {
                        // map 的含义, 其实就是 transform.
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
    
    /*
     The provided closure is executed when this promise is fulfilled.
     
     In your closure return an `Optional`,
     if you return `nil` the resulting promise is rejected with `PMKError.compactMap`, otherwise the promise is fulfilled with the unwrapped value.
     
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
    func compactMap<U>(on: DispatchQueue? = shareConf.defaultQueue.processing,
                       flags: DispatchWorkItemFlags? = nil,
                       _ transform: @escaping(T) throws -> U?)
    -> Promise<U> {
        let rp = Promise<U>(.pending)
        pipe {
            switch $0 {
            case .fulfilled(let value):
                on.async(flags: flags) {
                    do {
                        // 如果无法获取到值, 直接就当错误处理了, 由下方的 catch 进行处理.
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
    
    /*
     The provided closure is executed when this promise is fulfilled.
     
     Equivalent to `map { x -> Void in`, but since we force the `Void` return
     Swift is happier and gives you less hassle about your closure’s qualification.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that is executed when this Promise is fulfilled.
     - Returns: A new promise fulfilled as `Void` or rejected if the provided closure throws.
     
     firstly {
     URLSession.shared.dataTask(.promise, with: url)
     }.done { response in
     print(response.data)
     }
     */
    // Done 返回的是 Promise<Void>, 是一个特殊的类型.
    // 从业务逻辑上来讲, Void 的 Output 就不应该有后续的 Promise 了, 因为 Void 无法给后续任务带来输入.
    func done(on: DispatchQueue? = shareConf.defaultQueue.end,
              flags: DispatchWorkItemFlags? = nil,
              _ body: @escaping(T) throws -> Void)
    -> Promise<Void> {
        // 这是一种很特殊的初始化方式. 专门用来进行特定领域的初始化的.
        // 利用编译器的特性, 来固话 init.
        let rp = Promise<Void>(.pending)
        pipe {
            switch $0 {
            case .fulfilled(let value):
                on.async(flags: flags) {
                    do {
                        // 直接进行 body 的调用, 后续的节点, 只会获取到 Void Output.
                        // 不过这还是
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
     
     firstly {
     .value(1)
     }.get { foo in
     print(foo, " is 1")
     }.done { foo in
     print(foo, " is 1")
     }.done { foo in
     print(foo, " is Void")
     }
     */
    // 在中间安插一个操作, 但是不影响整个数据流转流程.
    // 还是有中间节点, 不过中间节点不做数据的处理, 透传了上游的数据.
    func get(on: DispatchQueue? = shareConf.defaultQueue.end,
             flags: DispatchWorkItemFlags? = nil,
             _ body: @escaping (T) throws -> Void) -> Promise<T> {
        return map(on: on, flags: flags) {
            try body($0)
            return $0
        }
    }
    
    /**
     The provided closure is executed with promise result.
     
     This is like `get` but provides the Result<T> of the Promise so you can inspect the value of the chain at this point without causing any side effects.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that is executed with Result of Promise.
     - Returns: A new promise that is resolved with the result that the handler is fed. For example:
     
     promise.tap{ print($0) }.then{ /*…*/ }
     */
    func tap(on: DispatchQueue? = shareConf.defaultQueue.processing,
             flags: DispatchWorkItemFlags? = nil,
             _ body: @escaping(Result<T>) -> Void)
    -> Promise<T> {
        // 这里的实现和 JS 是一致的, Promise 的构造函数是同步执行的.
        // 所以 return Promise init 的同时, 将 resolve return Promise 的逻辑, pipe 到了当前的 Promise 回调里面了.
        // tap 并不限制 Result 的状态. 所以失败了也会触发.
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

// 便利的 Get 属性的定义.
public extension Thenable {
    /*
     - Returns: The error with which this promise was rejected; `nil` if this promise is not rejected.
     */
    // 抽取 rejected 这种情况下的 Error .
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
    // 抽取 fulfilled 下的 value 值. 
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
    func mapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U]> {
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
    func flatMapValues<U: Sequence>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.Iterator.Element]> {
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
    func compactMapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U?) -> Promise<[U]> {
        return map(on: on, flags: flags) { foo -> [U] in
            return try foo.compactMap(transform)
        }
    }
    
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
    func thenMap<U: Thenable>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.T]> {
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
    func thenFlatMap<U: Thenable>(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.T.Iterator.Element]> where U.T: Sequence {
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
    func filterValues(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, _ isIncluded: @escaping (T.Iterator.Element) -> Bool) -> Promise<[T.Iterator.Element]> {
        return map(on: on, flags: flags) {
            $0.filter(isIncluded)
        }
    }
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
    
    func firstValue(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil, where test: @escaping (T.Iterator.Element) -> Bool) -> Promise<T.Iterator.Element> {
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
    func sortedValues(on: DispatchQueue? = shareConf.defaultQueue.processing, flags: DispatchWorkItemFlags? = nil) -> Promise<[T.Iterator.Element]> {
        return map(on: on, flags: flags){ $0.sorted() }
    }
}
