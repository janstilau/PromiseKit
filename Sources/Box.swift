import Dispatch

/*
 存储 Pending, Resolved 两种状态, 这两种状态, 是带有数据的.
 在 Swift 的库里面, 充分的利用了 Enum 这种类型. 
 */
enum Sealant<R> {
    // 如果是在 Pending 状态, 那么 value 部分, 存储的是一个个的 Handler
    case pending(Handlers<R>)
    // 如果是在 resolved 状态, 那么 value 部分, 就是存储的 R. Result. 可能是 Fulfilled, 也可能是 Rejected.
    case resolved(R)
}

// 存储所有的闭包, 也就是 Promise 的 Observer
final class Handlers<R> {
    var bodies: [(R) -> Void] = []
    func append(_ item: @escaping(R) -> Void) { bodies.append(item) }
}

// Box 更多的是一个接口类型, 他所做的事, 是查看当前的数据.
// 这里设计有些复杂, coobjc 里面, 逻辑比较简单.
class Box<T> {
    func inspect() -> Sealant<T> { fatalError() }
    func inspect(_: (Sealant<T>) -> Void) { fatalError() } // 使用该方法, 一定要在 inspect() 返回 Pending 的前提下使用.
    func seal(_: T) {} // Seal, 就是将状态, 改变为 Resolved 的状态.
}

// SealedBox, 是没有办法, 进行状态的改变的.
// 对他进行 Inspect, 只会是 Resolved 的状态.
final class SealedBox<T>: Box<T> {
    let value: T
    
    init(value: T) {
        self.value = value
    }
    
    // 特殊的 Box, 状态不会发生任何改变, 一个不可变对象. 不用考虑线程问题.
    override func inspect() -> Sealant<T> {
        return .resolved(value)
    }
}

/*
 新生成的 Promise, 里面存储的是 EmptyBox 对象. 而 EmptyBox 里面, 存储的是一个 pending 状态的 Sealant 盒子.
 */
class EmptyBox<T>: Box<T> {
    
    private var sealant = Sealant<T>.pending(.init())
    
    private let barrier = DispatchQueue(label: "org.promisekit.barrier", attributes: .concurrent)
    
    // 当, Box 从 Pending 变为 Resolved 的时候, 要把所有的回调取出来调用一次, 并且清空回调 .
    // 然后, 将自己的状态, 变为是 .resolved 的状态.
    // 因为, 这是一个可变类型, 所以要考虑线程问题.
    override func seal(_ value: T) {
        
        var handlers: Handlers<T>!
        // 使用了 barrier 这种, 来进行线程环境的保护.
        barrier.sync(flags: .barrier) {
            guard case .pending(let _handlers) = self.sealant else {
                return
            }
            handlers = _handlers
            // 直接使用 Enum 进行切换. Enum 切换, 里面的各种关联对象, 也会进行释放. 这就是使用 Enum 的好处, 相关的数据伴随着类型.
            self.sealant = .resolved(value)
        }
        
        // 将之前存储的 Handler 统一进行一次触发.
        if let handlers = handlers {
            handlers.bodies.forEach{ $0(value) }
        }
    }
    
    // 因为, 这是一个可变类型, 所以在进行 Get 请求的时候, 需要考虑到线程的问题.
    override func inspect() -> Sealant<T> {
        var rv: Sealant<T>!
        barrier.sync {
            rv = self.sealant
        }
        return rv
    }
    
    /*
     body 会在线程安全的环境下进行触发.
     使用这种方式, 可以在 Body 里面, 对 Sealant 进行任意数据的修改.
     */
    override func inspect(_ body: (Sealant<T>) -> Void) {
        var sealed = false
        barrier.sync(flags: .barrier) {
            switch sealant {
            case .pending:
                // body will append to handlers, so we must stay barrier’d
                body(sealant)
            case .resolved:
                sealed = true
            }
        }
        if sealed {
            // we do this outside the barrier to prevent potential deadlocks
            // it's safe because we never transition away from this state
            body(sealant)
        }
    }
}


extension Optional where Wrapped: DispatchQueue {
    func async(flags: DispatchWorkItemFlags?,
               _ body: @escaping() -> Void) {
        switch self {
        case .none:
            // 如果, 是 nil. 那就不调度, 直接当前的线程执行. 
            body()
        case .some(let q):
            if let flags = flags {
                q.async(flags: flags, execute: body)
            } else {
                q.async(execute: body)
            }
        }
    }
}
