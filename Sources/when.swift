import Foundation
import Dispatch

/*
 When 提供的都是, 当传入的 Promise 都完成了之后, 产出的一个 Promise<[Result]>
 */

// 没有关于 Output 的限制. 这里就是在等待, 所有的 Promise 完成之后的一个事件而已.
private func _when<U: Thenable>(_ thenables: [U]) -> Promise<Void> {
    var countdown = thenables.count
    guard countdown > 0 else {
        return .value(Void())
    }

    let rp = Promise<Void>(.pending)

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
                    countdown -= 1
                    if countdown == 0 {
                        rp.box.seal(.fulfilled(()))
                    }
                }
            }
        }
    }

    return rp
}

private func __when<T>(_ guarantees: [Guarantee<T>]) -> Guarantee<Void> {
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
// AllPromise 的实现.
public func when<U: Thenable>(fulfilled thenables: [U]) -> Promise<[U.T]> {
    return _when(thenables).map(on: nil) { thenables.map{ $0.value! } }
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable>(fulfilled promises: U...) -> Promise<Void> where U.T == Void {
    return _when(promises)
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable>(fulfilled promises: [U]) -> Promise<Void> where U.T == Void {
    return _when(promises)
}

/*
 When 只是达到了, 所有的都完成了这一事件的监听.
 想要获取到里面的值, 还需要专门的进行一次抽取.
 */

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable, V: Thenable>(fulfilled pu: U, _ pv: V) -> Promise<(U.T, V.T)> {
    return _when([pu.asVoid(), pv.asVoid()]).map(on: nil) { (pu.value!, pv.value!) }
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable, V: Thenable, W: Thenable>(fulfilled pu: U, _ pv: V, _ pw: W) -> Promise<(U.T, V.T, W.T)> {
    return _when([pu.asVoid(), pv.asVoid(), pw.asVoid()]).map(on: nil) { (pu.value!, pv.value!, pw.value!) }
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable, V: Thenable, W: Thenable, X: Thenable>(fulfilled pu: U, _ pv: V, _ pw: W, _ px: X) -> Promise<(U.T, V.T, W.T, X.T)> {
    return _when([pu.asVoid(), pv.asVoid(), pw.asVoid(), px.asVoid()]).map(on: nil) { (pu.value!, pv.value!, pw.value!, px.value!) }
}

/// Wait for all promises in a set to fulfill.
public func when<U: Thenable, V: Thenable, W: Thenable, X: Thenable, Y: Thenable>(fulfilled pu: U, _ pv: V, _ pw: W, _ px: X, _ py: Y) -> Promise<(U.T, V.T, W.T, X.T, Y.T)> {
    return _when([pu.asVoid(), pv.asVoid(), pw.asVoid(), px.asVoid(), py.asVoid()]).map(on: nil) { (pu.value!, pv.value!, pw.value!, px.value!, py.value!) }
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
    return __when(guarantees).map(on: nil) { guarantees.map { $0.value! } }
}

/// Waits on all provided Guarantees.
public func when<U, V>(guarantees gu: Guarantee<U>, _ gv: Guarantee<V>) -> Guarantee<(U, V)> {
    return __when([gu.asVoid(), gv.asVoid()]).map(on: nil) { (gu.value!, gv.value!) }
}

/// Waits on all provided Guarantees.
public func when<U, V, W>(guarantees gu: Guarantee<U>, _ gv: Guarantee<V>, _ gw: Guarantee<W>) -> Guarantee<(U, V, W)> {
    return __when([gu.asVoid(), gv.asVoid(), gw.asVoid()]).map(on: nil) { (gu.value!, gv.value!, gw.value!) }
}

/// Waits on all provided Guarantees.
public func when<U, V, W, X>(guarantees gu: Guarantee<U>, _ gv: Guarantee<V>, _ gw: Guarantee<W>, _ gx: Guarantee<X>) -> Guarantee<(U, V, W, X)> {
    return __when([gu.asVoid(), gv.asVoid(), gw.asVoid(), gx.asVoid()]).map(on: nil) { (gu.value!, gv.value!, gw.value!, gx.value!) }
}

/// Waits on all provided Guarantees.
public func when<U, V, W, X, Y>(guarantees gu: Guarantee<U>, _ gv: Guarantee<V>, _ gw: Guarantee<W>, _ gx: Guarantee<X>, _ gy: Guarantee<Y>) -> Guarantee<(U, V, W, X, Y)> {
    return __when([gu.asVoid(), gv.asVoid(), gw.asVoid(), gx.asVoid(), gy.asVoid()]).map(on: nil) { (gu.value!, gv.value!, gw.value!, gx.value!, gy.value!) }
}
