import struct Foundation.TimeInterval
import Dispatch

/**
     after(seconds: 1.5).then {
         //…
     }

- Returns: A guarantee that resolves after the specified duration.
*/

// 一切都建立在, 存储想要完成的异步动作, 到一个内存对象的回调列表中, 完成的各种操作.
// after 就是创建了一个中间节点, 然后在特定的时间之后, 对这个中间节点进行 resolve.
//
public func after(seconds: TimeInterval) -> Guarantee<Void> {
    // 为什么会出现 pending() 这个函数在这里体现出来了.
    // 快速的定义一个 Thenable, 提供 seal 接口进行状态的封存.
    /*
     当然, 使用 Future 这样的构造函数提供 fulfill, reject 两个闭包参数的方式
     然后将 after 的逻辑, 写在 Resolve 函数的内部.
     不过, 使用这种 seal 可以单独调用的方式, 更加的能够显示, 当 Promise 的值发生了变化之后, 会触发给他添加的各种回调调用 这个概念. 
     */
    let (rg, seal) = Guarantee<Void>.pending()
    let when = DispatchTime.now() + seconds
    theQueue.asyncAfter(deadline: when) { seal(()) }
    return rg
}

/**
     after(.seconds(2)).then {
         //…
     }

 - Returns: A guarantee that resolves after the specified duration.
*/
public func after(_ interval: DispatchTimeInterval) -> Guarantee<Void> {
    let (rg, seal) = Guarantee<Void>.pending()
    let when = DispatchTime.now() + interval
//    theQueue.asyncAfter(deadline: when, execute: seal)
    return rg
}

private var theQueue: DispatchQueue {
    if #available(macOS 10.10, iOS 8.0, tvOS 9.0, watchOS 2.0, *) {
        return DispatchQueue.global(qos: .default)
    } else {
        return DispatchQueue.global(priority: .default)
    }
}
