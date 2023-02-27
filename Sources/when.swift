import Foundation
import Dispatch

/*
 When 提供的都是, 当传入的 Promise 都完成了之后, 产出的一个 Promise<[Result]>
 */

// 没有关于 Output 的限制. 这里就是在等待, 所有的 Promise 完成之后的一个事件而已.
private func _whenAllFulfilled<U: Thenable>(_ thenables: [U]) -> Promise<Void> {
    var countdown = thenables.count
    guard countdown > 0 else {
        return .value(Void())
    }

    let rp = Promise<Void>(.pending)

    // 这里的思路, 和自己写没有太大的区别.
    // 都是在结果函数里面, 进行 count 值的比对.
    // 并且要有加锁相关的处理.
    let barrier = DispatchQueue(label: "org.promisekit.barrier.when", attributes: .concurrent)
    for promise in thenables {
        promise.pipe { result in
            // 各个 Primise 自然是自己触发各自的异步操作, 只不过汇总的时候, 需要加锁.
            barrier.sync(flags: .barrier) {
                switch result {
                case .rejected(let error):
                    if rp.isPending {
                        // 如果有一个出错了, 总的 Rp 就认为出错了.
                        // barrier 已经确定了, 一定是在锁的环境了.
                        // rp 里面的加锁, 是 rp 的机制, 这里不会有死锁的问题.
                        rp.box.seal(.rejected(error))
                    }
                case .fulfilled:
                    guard rp.isPending else { return }
                    // promise 的 result fullfil 的具体值一点意义都没有, 仅仅是接收到这个事件而已
                    countdown -= 1
                    if countdown == 0 {
                        // 当, 所有的 Promise 都有结果之后, 才进行 return promise resolve
                        rp.box.seal(.fulfilled(()))
                    }
                }
            }
        }
    }

    return rp
}

// 和上面的 Thenable 相比, Guarantee 不需要考虑 Rejected 的逻辑, 所以处理逻辑稍微简单一些.
private func __whenAllResolved<T>(_ guarantees: [Guarantee<T>]) -> Guarantee<Void> {
    var countdown = guarantees.count
    guard countdown > 0 else {
        return .value(Void())
    }

    let rg = Guarantee<Void>(.pending)
    let barrier = DispatchQueue(label: "org.promisekit.barrier.when", attributes: .concurrent)

    for guarantee in guarantees {
        guarantee.pipe { (_: T) in
            barrier.sync(flags: .barrier) {
                guard rg.isPending else { return }
                // 相比较 pormise, Guarantee 里面直接是 fulfilled 状况的判断, 没有 error 的判断.
                countdown -= 1
                if countdown == 0 {
                    rg.box.seal(())
                }
            }
        }
    }

    return rg
}

/**
 Wait for all promises in a set to fulfill.

 For example:

     when(fulfilled: promise1, promise2).then { results in
         //…
     }.catch { error in
         switch error {
         case URLError.notConnectedToInternet:
             //…
         case CLError.denied:
             //…
         }
     }

 - Note: If *any* of the provided promises reject, the returned promise is immediately rejected with that error.
 - Warning: In the event of rejection the other promises will continue to resolve and, as per any other promise, will either fulfill or reject. This is the right pattern for `getter` style asynchronous tasks, but often for `setter` tasks (eg. storing data on a server), you most likely will need to wait on all tasks and then act based on which have succeeded and which have failed, in such situations use `when(resolved:)`.
 - Parameter promises: The promises upon which to wait before the returned promise resolves.
 - Returns: A new promise that resolves when all the provided promises fulfill or one of the provided promises rejects.
 - Note: `when` provides `NSProgress`.
 - SeeAlso: `when(resolved:)`
*/
// 相比较于, 还需要在 when 内部去记录每个小的 promise 的 result 值的实现.
// 这种等待所有的 Promise 完结之后, 使用 map 来从 thenables 统一取值的方式, 会让代码更加的优雅.
// 因为 _whenAllFulfilled 这样一个类似于事件触发的机制, 会代码很强的可复用性.
// 因为, _whenAllFulfilled 触发的时候, 各个 Thenable 里面的值都是 resolve 的, 而 Promise 这种机制, 就是确定了内部状态不可能会发生变化了. 等待 allFulfill 取值是一个 get 行为, 一定不会引起内存问题.
public func when<U: Thenable>(fulfilled thenables: [U]) -> Promise<[U.T]> {
    // thenables.map 中的 map, 是 Sequence 里面的 map.
    // _when 返回的 Promise 能够 fulfilled, 就代表着 thenables 里面都有值了.
    // 这个时候, 就能够使用 value 来获取里面的值了.
    return _whenAllFulfilled(thenables).map(on: nil) { thenables.map{ $0.value! } }
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable>(fulfilled promises: U...) -> Promise<Void> where U.T == Void {
    return _whenAllFulfilled(promises)
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable>(fulfilled promises: [U]) -> Promise<Void> where U.T == Void {
    return _whenAllFulfilled(promises)
}

/*
 在这里, _whenAllFulfilled 这个表示所有的事件完成了的信号, 得到了复用.
 在 _whenAllFulfilled 发出之后, 使用 map 去取各个 thenable 的值.
 
 这种不同类型的, 都需要编写响应函数的实现, 使用编译器特性来完成调用的匹配, 这种生成的代码, 都有着相同的使用思路.
 不可能达到无限的参数的, 一般都会涉及一个上限值.
 */
/// Wait for all promises in a set to fulfill.
public func when<U: Thenable, V: Thenable>(fulfilled pu: U, _ pv: V) -> Promise<(U.T, V.T)> {
    return _whenAllFulfilled([pu.asVoid(), pv.asVoid()]).map(on: nil) { (pu.value!, pv.value!) }
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable, V: Thenable, W: Thenable>(fulfilled pu: U, _ pv: V, _ pw: W) -> Promise<(U.T, V.T, W.T)> {
    return _whenAllFulfilled([pu.asVoid(), pv.asVoid(), pw.asVoid()]).map(on: nil) { (pu.value!, pv.value!, pw.value!) }
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable, V: Thenable, W: Thenable, X: Thenable>(fulfilled pu: U, _ pv: V, _ pw: W, _ px: X) -> Promise<(U.T, V.T, W.T, X.T)> {
    return _whenAllFulfilled([pu.asVoid(), pv.asVoid(), pw.asVoid(), px.asVoid()]).map(on: nil) { (pu.value!, pv.value!, pw.value!, px.value!) }
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable, V: Thenable, W: Thenable, X: Thenable, Y: Thenable>(fulfilled pu: U, _ pv: V, _ pw: W, _ px: X, _ py: Y) -> Promise<(U.T, V.T, W.T, X.T, Y.T)> {
    return _whenAllFulfilled([pu.asVoid(), pv.asVoid(), pw.asVoid(), px.asVoid(), py.asVoid()]).map(on: nil) { (pu.value!, pv.value!, pw.value!, px.value!, py.value!) }
}








/**
 Generate promises at a limited rate and wait for all to fulfill.

 For example:
 
     func downloadFile(url: URL) -> Promise<Data> {
         // ...
     }
 
     let urls: [URL] = /*…*/
     let urlGenerator = urls.makeIterator()

 /*
  AnyIterator 中传入的闭包, 当做 next 方法的实现.
  */
 // 每次迭代的时候, 才进行 Promise 的创建.
     let generator = AnyIterator<Promise<Data>> {
         guard url = urlGenerator.next() else {
             return nil
         }
         return downloadFile(url)
     }

     when(generator, concurrently: 3).done { datas in
         // ...
     }
 
 No more than three downloads will occur simultaneously.

 - Note: The generator is called *serially* on a *background* queue.
 - Warning: Refer to the warnings on `when(fulfilled:)`
 - Parameter promiseGenerator: Generator of promises.
 - Returns: A new promise that resolves when all the provided promises fulfill or one of the provided promises rejects.
 - SeeAlso: `when(resolved:)`
 */

public func when<It: IteratorProtocol>(fulfilled promiseIterator: It,
                                       concurrently: Int) ->
Promise<[It.Element.T]> where It.Element: Thenable {

    guard concurrently > 0 else {
        return Promise(error: PMKError.badInput)
    }

    var generator = promiseIterator
    var runningCount = 0
    var promises: [It.Element] = []

    let barrier = DispatchQueue(label: "org.promisekit.barrier.when",
                                attributes: [.concurrent])

    // Swift 这种, 定义一个 Promise 对象, 然后使用 resolve 操作里面状态的做法, 让人更加容易理解.
    let root = Promise<[It.Element.T]>.pending()
    func dequeue() {
        guard root.promise.isPending else { return }  // don’t continue dequeueing if root has been rejected

        var shouldDequeue = false
        barrier.sync {
            shouldDequeue = runningCount < concurrently
        }
        guard shouldDequeue else { return }

        var _nextPromise: It.Element!

        barrier.sync(flags: .barrier) {
            guard let nextPromise = generator.next() else { return }
            _nextPromise = nextPromise
            runningCount += 1
            promises.append(nextPromise)
        }

        func testDone() {
            barrier.sync {
                if runningCount == 0 {
                    root.resolver.fulfill(promises.compactMap{ $0.value })
                }
            }
        }

        // 如果娶不到了, 就判断一下, 是不是结束了.
        guard _nextPromise != nil else {
            return testDone()
        }

        _nextPromise.pipe { resolution in
            // 状态量的变化.
            barrier.sync(flags: .barrier) {
                runningCount -= 1
            }

            switch resolution {
            case .fulfilled:
                dequeue()
                testDone()
            case .rejected(let error):
                root.resolver.reject(error)
            }
        }

        dequeue()
    }
        
    dequeue()

    return root.promise
}

/**
 Waits on all provided promises.

 `when(fulfilled:)` rejects as soon as one of the provided promises rejects. `when(resolved:)` waits on all provided promises whatever their result, and then provides an array of `Result<T>` so you can individually inspect the results. As a consequence this function returns a `Guarantee`, ie. errors are lifted from the individual promises into the results array of the returned `Guarantee`.

     when(resolved: promise1, promise2, promise3).then { results in
         for result in results where case .fulfilled(let value) {
            //…
         }
     }.catch { error in
         // invalid! Never rejects
     }

 - Returns: A new promise that resolves once all the provided promises resolve. The array is ordered the same as the input, ie. the result order is *not* resolution order.
 - Note: we do not provide tuple variants for `when(resolved:)` but will accept a pull-request
 - Remark: Doesn't take Thenable due to protocol `associatedtype` paradox
*/
public func when<T>(resolved promises: Promise<T>...) -> Guarantee<[Result<T>]> {
    return when(resolved: promises)
}

/// - See: `when(resolved: Promise<T>...)`
public func when<T>(resolved promises: [Promise<T>]) -> Guarantee<[Result<T>]> {
    guard !promises.isEmpty else {
        return .value([])
    }

    var countdown = promises.count
    let barrier = DispatchQueue(label: "org.promisekit.barrier.join", attributes: .concurrent)

    let rg = Guarantee<[Result<T>]>(.pending)
    for promise in promises {
        promise.pipe { result in
            barrier.sync(flags: .barrier) {
                countdown -= 1
            }
            barrier.sync {
                if countdown == 0 {
                    // 当这个时候之后, promises中每个promise都有 result 了, 直接取 Result 就可以了.
                    rg.box.seal(promises.map{ $0.result! })
                }
            }
        }
    }
    return rg
}

/**
Generate promises at a limited rate and wait for all to resolve.

For example:

    func downloadFile(url: URL) -> Promise<Data> {
        // ...
    }

    let urls: [URL] = /*…*/
    let urlGenerator = urls.makeIterator()

    let generator = AnyIterator<Promise<Data>> {
        guard url = urlGenerator.next() else {
            return nil
        }
        return downloadFile(url)
    }

    when(resolved: generator, concurrently: 3).done { results in
        // ...
    }

No more than three downloads will occur simultaneously. Downloads will continue if one of them fails

- Note: The generator is called *serially* on a *background* queue.
- Warning: Refer to the warnings on `when(resolved:)`
- Parameter promiseGenerator: Generator of promises.
- Returns: A new promise that resolves once all the provided promises resolve. The array is ordered the same as the input, ie. the result order is *not* resolution order.
- SeeAlso: `when(resolved:)`
*/
#if swift(>=5.3)
public func when<It: IteratorProtocol>(resolved promiseIterator: It,
                                       concurrently: Int)
    -> Guarantee<[Result<It.Element.T>]> where It.Element: Thenable {
    guard concurrently > 0 else {
        return Guarantee.value([Result.rejected(PMKError.badInput)])
    }

    var generator = promiseIterator
    let root = Guarantee<[Result<It.Element.T>]>.pending()
    var pendingPromises = 0
    var promises: [It.Element] = []

    let barrier = DispatchQueue(label: "org.promisekit.barrier.when", attributes: [.concurrent])

    func dequeue() {
        guard root.guarantee.isPending else {
            return
        }  // don’t continue dequeueing if root has been rejected

        var shouldDequeue = false
        barrier.sync {
            shouldDequeue = pendingPromises < concurrently
        }
        guard shouldDequeue else {
            return
        }

        var promise: It.Element!

        barrier.sync(flags: .barrier) {
            guard let next = generator.next() else {
                return
            }

            promise = next

            pendingPromises += 1
            promises.append(next)
        }

        func testDone() {
            barrier.sync {
                if pendingPromises == 0 {
                  #if !swift(>=3.3) || (swift(>=4) && !swift(>=4.1))
                    root.resolve(promises.flatMap { $0.result })
                  #else
                    root.resolve(promises.compactMap { $0.result })
                  #endif
                }
            }
        }

        guard promise != nil else {
            return testDone()
        }

        promise.pipe { _ in
            barrier.sync(flags: .barrier) {
                pendingPromises -= 1
            }

            dequeue()
            testDone()
        }

        dequeue()
    }

    dequeue()

    return root.guarantee
}
#endif

/// Waits on all provided Guarantees.
public func when(_ guarantees: Guarantee<Void>...) -> Guarantee<Void> {
    return when(guarantees: guarantees)
}

/// Waits on all provided Guarantees.
public func when<T>(_ guarantees: Guarantee<T>...) -> Guarantee<[T]> {
    return when(guarantees: guarantees)
}

/// Waits on all provided Guarantees.
public func when(guarantees: [Guarantee<Void>]) -> Guarantee<Void> {
    return when(fulfilled: guarantees).recover{ _ in }.asVoid()
}

/// Waits on all provided Guarantees.
public func when<T>(guarantees: [Guarantee<T>]) -> Guarantee<[T]> {
    return __whenAllResolved(guarantees).map(on: nil) { guarantees.map { $0.value! } }
}

/// Waits on all provided Guarantees.
public func when<U, V>(guarantees gu: Guarantee<U>, _ gv: Guarantee<V>) -> Guarantee<(U, V)> {
    return __whenAllResolved([gu.asVoid(), gv.asVoid()]).map(on: nil) { (gu.value!, gv.value!) }
}

/// Waits on all provided Guarantees.
public func when<U, V, W>(guarantees gu: Guarantee<U>, _ gv: Guarantee<V>, _ gw: Guarantee<W>) -> Guarantee<(U, V, W)> {
    return __whenAllResolved([gu.asVoid(), gv.asVoid(), gw.asVoid()]).map(on: nil) { (gu.value!, gv.value!, gw.value!) }
}

/// Waits on all provided Guarantees.
public func when<U, V, W, X>(guarantees gu: Guarantee<U>, _ gv: Guarantee<V>, _ gw: Guarantee<W>, _ gx: Guarantee<X>) -> Guarantee<(U, V, W, X)> {
    return __whenAllResolved([gu.asVoid(), gv.asVoid(), gw.asVoid(), gx.asVoid()]).map(on: nil) { (gu.value!, gv.value!, gw.value!, gx.value!) }
}

/// Waits on all provided Guarantees.
public func when<U, V, W, X, Y>(guarantees gu: Guarantee<U>, _ gv: Guarantee<V>, _ gw: Guarantee<W>, _ gx: Guarantee<X>, _ gy: Guarantee<Y>) -> Guarantee<(U, V, W, X, Y)> {
    return __whenAllResolved([gu.asVoid(), gv.asVoid(), gw.asVoid(), gx.asVoid(), gy.asVoid()]).map(on: nil) { (gu.value!, gv.value!, gw.value!, gx.value!, gy.value!) }
}
