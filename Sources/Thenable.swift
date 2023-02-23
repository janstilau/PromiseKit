import Dispatch
/*
 Promise 里面的代码少, 就是因为都放到了 Thenable 里面实现了.
 从实现的角度来说, Thenable 应该算作是 Promise 的抽象基类.
 */
/*
 Thenable
 1. 可以添加一个回调, 这个回调是当我状态确定的时候一定会执行, 参数是我当前的状态值.
 2. 可以确定我当前的状态.
 
 如果.
 给我添加了一个回调, 这个回调里面我将自身 Result 产生了另外一个值, 然后将这个值赋值给了另外一个 Promise 的状态, 那么另外一个 Promise 就确定状态了. 他就能够触发自己存储的回调了.
 这就是 Map.
 
 如果.
 给我添加了一个回调, 这个回调里面我将自身的 Result 产生了另外的一个 Promise 的值, 这个 Promise 添加了一个回调, 这个回调会确定 return primise 的状态.
 这就是 Promise 实现异步连接的原理.
 
 以上的这些, 都被 Thenable 封装到了 Map, Then 的实现里面, 所以 Promise 里面的逻辑很少.
 */

/// Thenable represents an asynchronous operation that can be chained.
public protocol Thenable: AnyObject {
    /// The type of the wrapped value
    associatedtype T

    /// `pipe` is immediately executed when this `Thenable` is resolved
    /*
     Pipe to 的参数, 就是当 Promise Resolved 的时候, 会调用回调. 
     */
    func pipe(to: @escaping(Result<T>) -> Void)

    /// The resolved result or nil if pending.
    // Optional + Result 表示了: 没有值, 有值错误, 有值正确三种状态. 
    var result: Result<T>? { get }
}


// 从上面的分析可以看出, 各种功能, 其实都建立在 Pipe 这个能力之上的.
// Pipe 提供的是一个闭包, 所以有着无限的自定义的可能.
public extension Thenable {
    /*
     The provided closure executes when this promise is fulfilled.
     
     // 非常重要的概念.
     This allows chaining promises. The promise returned by the provided closure is resolved before the promise returned by this closure resolves.
     
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
    func then<U: Thenable>(on: DispatchQueue? = shareConf.defaultQueue.map,
                           flags: DispatchWorkItemFlags? = nil,
                           _ body: @escaping(T) throws -> U)
    -> Promise<U.T> {
        let rp = Promise<U.T>(.pending)
        // 自定义了 Pipe 传递的 Block 值.
        // 在这个 Block 里面, 完成了几个 Promise 之间链路挂钩的过程.
        pipe {
            // $0 是当前的 Promise 的 Result 值.
            // 因为 Promise 一定是 Result 确定了之后, 才调用自己的 callback 的, 所以一定是有值.
            switch $0 {
            case .fulfilled(let value):
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
                // 如果上一个 Promise 已经发生了错误, 直接透传到下一个 Promise.
                rp.box.seal(.rejected(error))
            }
        }
        return rp
    }

    /**
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
    // Map 就没有中间的 Promise 生成了, 在 Swift 实现里面, 将 then 里面返回 Promise 和返回一个确定的类型分开了.
    func map<U>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T) throws -> U) -> Promise<U> {
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

    /*
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
    func compactMap<U>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T) throws -> U?) -> Promise<U> {
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
     
           firstly {
               URLSession.shared.dataTask(.promise, with: url)
           }.done { response in
               print(response.data)
           }
     */
    // Donw 返回的是 Promise<Void>, 是一个特殊的类型.
    //
    func done(on: DispatchQueue? = shareConf.defaultQueue.return, flags: DispatchWorkItemFlags? = nil, _ body: @escaping(T) throws -> Void) -> Promise<Void> {
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

    /**
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
    func get(on: DispatchQueue? = shareConf.defaultQueue.return, flags: DispatchWorkItemFlags? = nil, _ body: @escaping (T) throws -> Void) -> Promise<T> {
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
    func tap(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ body: @escaping(Result<T>) -> Void) -> Promise<T> {
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
    func mapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U]> {
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
    func mapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, U>) -> Promise<[U]> {
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
    func flatMapValues<U: Sequence>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.Iterator.Element]> {
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
    func compactMapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U?) -> Promise<[U]> {
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
    func compactMapValues<U>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, U?>) -> Promise<[U]> {
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
    func thenMap<U: Thenable>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.T]> {
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
    func thenFlatMap<U: Thenable>(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ transform: @escaping(T.Iterator.Element) throws -> U) -> Promise<[U.T.Iterator.Element]> where U.T: Sequence {
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
    func filterValues(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ isIncluded: @escaping (T.Iterator.Element) -> Bool) -> Promise<[T.Iterator.Element]> {
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
    func filterValues(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, _ keyPath: KeyPath<T.Iterator.Element, Bool>) -> Promise<[T.Iterator.Element]> {
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

    func firstValue(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil, where test: @escaping (T.Iterator.Element) -> Bool) -> Promise<T.Iterator.Element> {
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
    func sortedValues(on: DispatchQueue? = shareConf.defaultQueue.map, flags: DispatchWorkItemFlags? = nil) -> Promise<[T.Iterator.Element]> {
        return map(on: on, flags: flags){ $0.sorted() }
    }
}
