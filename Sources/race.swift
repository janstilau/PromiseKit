import Dispatch

@inline(__always)
private func _race<U: Thenable>(_ thenables: [U]) -> Promise<U.T> {
    let rp = Promise<U.T>(.pending)
    // rp.box.seal 里面, 会有锁. 从这里可以看出, 为什么将类型的业务代码, 和存储对象责任分离会有好处.
    // 存储对象里面加锁, 业务代码里面就不用考虑这回事了.
    // 这也就是, 为什么在别的平台, 会有 atomic Int 各种带锁属性的原因所在了.
    for thenable in thenables {
        // 每个 thenable, 都增加了 rp.box.seal 的回调.
        // rp.box.seal 的内部, 进行了线程运行环境的确定.
        // 没有必要在 rp resolved 之后, 专门组织之前添加的回调删除或者停止调用.
        // 如果 box 里面没有相关的设计, 那么还是需要考虑这些的.
        thenable.pipe(to: rp.box.seal)
    }
    return rp
}

/*
 Waits for one promise to resolve
 
 race(promise1, promise2, promise3).then { winner in
 //…
 }
 
 - Returns: The promise that resolves first
 - Warning: If the first resolution is a rejection, the returned promise is rejected
 */
// 不定长参数, 最终会变为数组.
// 这种有一个条件, 就是 race 参数里面, 所有的值, 都应该是同样的一个类型才可以.
public func race<U: Thenable>(_ thenables: U...) -> Promise<U.T> {
    return _race(thenables)
}

/*
 Waits for one promise to resolve
 
 race(promise1, promise2, promise3).then { winner in
 //…
 }
 
 - Returns: The promise that resolves first
 - Warning: If the first resolution is a rejection, the returned promise is rejected
 - Remark: If the provided array is empty the returned promise is rejected with PMKError.badInput
 */
// 这个和上面不定长参数相比, 出现了可能数组为空的情况.
public func race<U: Thenable>(_ thenables: [U]) -> Promise<U.T> {
    guard !thenables.isEmpty else {
        return Promise(error: PMKError.badInput)
    }
    return _race(thenables)
}

/*
 Waits for one guarantee to resolve
 
 race(promise1, promise2, promise3).then { winner in
 //…
 }
 
 - Returns: The guarantee that resolves first
 */
// 和 thenable 没有任何的区别.
public func race<T>(_ guarantees: Guarantee<T>...) -> Guarantee<T> {
    let rg = Guarantee<T>(.pending)
    for guarantee in guarantees {
        guarantee.pipe(to: rg.box.seal)
    }
    return rg
}






/*
 Waits for one promise to fulfill
 
 race(fulfilled: [promise1, promise2, promise3]).then { winner in
 //…
 }
 
 - Returns: The promise that was fulfilled first.
 - Warning: Skips all rejected promises.
 - Remark: If the provided array is empty, the returned promise is rejected with `PMKError.badInput`. If there are no fulfilled promises, the returned promise is rejected with `PMKError.noWinner`.
 */
/*
 原本只是需要 Resolved 就可以, 现在增加了, Resolved 之后, 必须是 fulfilled 这样的限制.
 所以, 需要一些状态进行管理, 也就出现了一个 DispatchQueue 主动地进行加锁控制.
 */
public func race<U: Thenable>(fulfilled thenables: [U]) -> Promise<U.T> {
    var countdown = thenables.count
    guard countdown > 0 else {
        return Promise(error: PMKError.badInput)
    }
    
    let rp = Promise<U.T>(.pending)
    
    let barrier = DispatchQueue(label: "org.promisekit.barrier.race", attributes: .concurrent)
    
    for promise in thenables {
        promise.pipe { result in
            barrier.sync(flags: .barrier) {
                switch result {
                case .rejected:
                    guard rp.isPending else { return }
                    countdown -= 1
                    if countdown == 0 {
                        rp.box.seal(.rejected(PMKError.noWinner))
                    }
                case .fulfilled(let value):
                    guard rp.isPending else { return }
                    countdown = 0
                    rp.box.seal(.fulfilled(value))
                }
            }
        }
    }
    
    return rp
}
