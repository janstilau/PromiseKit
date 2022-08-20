import Dispatch

/// Thenable represents an asynchronous operation that can be chained.
public protocol Thenable: AnyObject {
    /// The type of the wrapped value
    associatedtype T

    /// `pipe` is immediately executed when this `Thenable` is resolved
    // pipe(to) 的含义是, 当 Thenable 的状态 Resolve 之后, 应该触发什么样的操作.
    // 听起来很像是 Then, 但是它更多的像是一个基本函数, 用来组建复杂的功能的.
    func pipe(to: @escaping(Result<T>) -> Void)

    /// The resolved result or nil if pending.
    // 返回当前的状态.
    var result: Result<T>? { get }
}

public extension Thenable {
    /*
     The provided closure executes when this promise is fulfilled.
     
     This allows chaining promises.
     // 理解这一点, 是非常非常重要的, 就是 Body 生成的 Promise 先 Resolve, 它的结果, 来 Resolve 函数返回值的 Promise.
     The promise returned by the provided closure is resolved before the promise returned by this closure resolves.
     
     - Parameter on: The queue to which the provided closure dispatches.
     - Parameter body: The closure that executes when this promise is fulfilled. It must return a promise.
     - Returns: A new promise that resolves when the promise returned from the provided closure resolves. For example:

           firstly {
               URLSession.shared.dataTask(.promise, with: url1)
           }.then { response in
               transform(data: response.data)
           }.done { transformation in
               //…
           }
     */
    // 根据, body 中的生成的 Thenable 对象的类型, 来确定最终返回的 Promise 对象中, 类型参数的类型.
    func then<U: Thenable>(
        queue: DispatchQueue? = conf.Q.map,
        flags: DispatchWorkItemFlags? = nil,
        _ body: @escaping(T) throws -> U)
    -> Promise<U.T> {
        let rp = Promise<U.T>(.pending)
        pipe {
            switch $0 {
            case .fulfilled(let value):
                // 这里应该是保持了和 JS 的代码风格, 添加异步回调的方式.
                queue.async(flags: flags) {
                    do {
                        // 为什么要有这样的一个判断呢???
                        let rv = try body(value)
                        guard rv !== rp else { throw PMKError.returnedSelf }
                        rv.pipe(to: rp.box.seal)
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
    // 在 PromiseKit 里面, 把上一个 Promise 的结果触发的, 非 Promise 这种行为, 专门的使用 map 这个函数进行了隔离.
    // 利用 Swift 的泛型编程, 让代码更加的清晰.
    func map<U>(
        on: DispatchQueue? = conf.Q.map,
        flags: DispatchWorkItemFlags? = nil,
        _ transform: @escaping(T) throws -> U)
    -> Promise<U> {
        let rp = Promise<U>(.pending)
        pipe {
            switch $0 {
            case .fulfilled(let value):
                on.async(flags: flags) {
                    // 生成的 rp 的值, 直接使用 transform 函数就来决定返回 Promise 的结果.
                    do {
                        rp.box.seal(.fulfilled(try transform(value)))
                    } catch {
                        // Promise 链条的所有节点, 当发生了错误的时候, 都是透传 Error 的值.
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
    func compactMap<U>(
        on: DispatchQueue? = conf.Q.map,
        flags: DispatchWorkItemFlags? = nil,
        _ transform: @escaping(T) throws -> U?)
    -> Promise<U> {
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

    /*
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
    // 返回的 Promise, 是 Void 类型, 所以 Then 后参数也是 Void 类型. 也就是没有办法传值了.
    func done(
        on: DispatchQueue? = conf.Q.return,
        flags: DispatchWorkItemFlags? = nil,
        _ body: @escaping(T) throws -> Void)
    -> Promise<Void> {
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
    // 类似于 Do, HandleEvent 节点, 使用上游界定
    func get(
        on: DispatchQueue? = conf.Q.return,
        flags: DispatchWorkItemFlags? = nil,
        _ body: @escaping (T) throws -> Void)
    -> Promise<T> {
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
    func tap(
        on: DispatchQueue? = conf.Q.map,
        flags: DispatchWorkItemFlags? = nil,
        _ body: @escaping(Result<T>) -> Void)
    -> Promise<T> {
        return Promise { seal in
            pipe { result in
                on.async(flags: flags) {
                    // 同 Map 不同的是, 这里没有对于 Resule 的解析的过程.
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

// 作为类型的设计者, 进行更好的 API 的设计, 是非常有必要的.
// 这也能够体现, Protocol 作为一个抽象数据类型, 来进行设计的好处.
// 使用 Primitivie Method, 可以构建出复杂的抽象数据类型, 这样使用者在进行使用的时候, 可以快速的进行功能的集合. 
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
        return then(queue: on, flags: flags) {
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
        return then(queue: on, flags: flags) {
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
