import Dispatch

/**
 // 明智的；头脑精明的；判断正确的
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

// 这样的写法, 会让代码更加的清晰.
// 使用一个中间的 Promise 对象, 将所有的操作, 串联在一起了. 
public func firstly<U: Thenable>(execute body: () throws -> U) -> Promise<U.T> {
    do {
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
