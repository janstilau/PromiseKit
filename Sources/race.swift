import Dispatch

@inline(__always)
private func _race<U: Thenable>(_ thenables: [U]) -> Promise<U.T> {
    let rp = Promise<U.T>(.pending)
    // 这里是 Race, 也就是第一个 resolve 的就可以决定 return promise 的状态.
    // rp.box.seal 里面有锁.
    for thenable in thenables {
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
// 不定长参数, 需要时一个类型才可以.
public func race<U: Thenable>(_ thenables: U...) -> Promise<U.T> {
    return _race(thenables)
}

/**
 Waits for one promise to resolve

     race(promise1, promise2, promise3).then { winner in
         //…
     }

 - Returns: The promise that resolves first
 - Warning: If the first resolution is a rejection, the returned promise is rejected
 - Remark: If the provided array is empty the returned promise is rejected with PMKError.badInput
*/
public func race<U: Thenable>(_ thenables: [U]) -> Promise<U.T> {
    guard !thenables.isEmpty else {
        return Promise(error: PMKError.badInput)
    }
    return _race(thenables)
}

/**
 Waits for one guarantee to resolve

     race(promise1, promise2, promise3).then { winner in
         //…
     }

 - Returns: The guarantee that resolves first
*/
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
// 这里是, 只要 fulfulled 的结果, 所以要判断 result 的状态. 
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
