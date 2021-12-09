import Dispatch

/*
 Judicious use of `firstly` *may* make chains more readable.

 Compare:

     URLSession.shared.dataTask(url: url1).then {
         URLSession.shared.dataTask(url: url2)
     }.then {
         URLSession.shared.dataTask(url: url3)
     }

 With:

     firstly {
         URLSession.shared.dataTask(url: url1)
     }.then {
         URLSession.shared.dataTask(url: url2)
     }.then {
         URLSession.shared.dataTask(url: url3)
     }

 - Note: the block you pass executes immediately on the current thread/queue.
 */

/*
    Firstly 里面, 接受的 Body, 要返回一个 Promise.
    然后返回一个 Promise.
    根据 Body 的状态改变, 来决定新产生的 Promise 的状态.
    而 Then, 是添加到这个新的 Promise 上的.
 */
public func firstly<U: Thenable>(execute body: () throws -> U) -> Promise<U.T> {
    do {
        // 新生成一个 Promise, 返回这个值.
        // 这个新生成的 Promise 的状态, 是由 Body 生成的 Promise 的状态来 Trigger 的.
        let rp = Promise<U.T>(.pending)
        try body().pipe(to: rp.box.seal)
        return rp
    } catch {
        return Promise(error: error)
    }
}

/// - See: firstly()
public func firstly<T>(execute body: () -> Guarantee<T>) -> Guarantee<T> {
    return body()
}
