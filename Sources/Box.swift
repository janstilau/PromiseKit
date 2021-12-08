import Dispatch

/*
    这里, 对于类的设计过于复杂了.
 */
enum Sealant<R> {
    // 如果是在 Pending 状态, 那么 value 部分, 存储的是一个个的 Handler
    case pending(Handlers<R>)
    // 如果是在 resolved 状态, 那么 value 部分, 就是存储的 R. Result. 可能是 Fulfilled, 也可能是 Rejected.
    case resolved(R)
}

final class Handlers<R> {
    var bodies: [(R) -> Void] = []
    func append(_ item: @escaping(R) -> Void) { bodies.append(item) }
}

class Box<T> {
    func inspect() -> Sealant<T> { fatalError() }
    func inspect(_: (Sealant<T>) -> Void) { fatalError() }
    func seal(_: T) {}
}

final class SealedBox<T>: Box<T> {
    let value: T
    
    init(value: T) {
        self.value = value
    }
    
    // 特殊的 Box, 状态不会发生任何改变, 一个不可变对象.
    // 不用考虑线程问题. 
    override func inspect() -> Sealant<T> {
        return .resolved(value)
    }
}

class EmptyBox<T>: Box<T> {
    
    private var sealant = Sealant<T>.pending(.init())
    
    /*
        使用, DispatchQueue 来解决线程问题的思路就是 .
        如果是 Get 函数, 就是设置返回值, 将赋值操作, 用 sync 的执行 Block.
        如果是 Set 函数, 
     */
    private let barrier = DispatchQueue(label: "org.promisekit.barrier", attributes: .concurrent)
    
    // 当, Box 从 Pending 变为 Resolved 的时候, 要把所有的回调取出来调用一次, 并且清空回调 .
    // 然后, 将自己的状态, 变为是 .resolved 的状态.
    
    // 因为, 这是一个可变类型, 所以要考虑线程问题.
    override func seal(_ value: T) {
        var handlers: Handlers<T>!
        barrier.sync(flags: .barrier) {
            guard case .pending(let _handlers) = self.sealant else {
                return
            }
            handlers = _handlers
            self.sealant = .resolved(value)
        }
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
    
    // 因为, 这是一个可变类型, 所以要考虑到线程问题.
    // 现在的需求是, 需要 Body 的执行过程中, 保持线程独占. 这是使用的技术是, barrier queue.
    override func inspect(_ body: (Sealant<T>) -> Void) {
        var sealed = false
        /*
         When submitted to a concurrent queue, a work item with this flag acts as a barrier.
         Work items submitted prior to the barrier execute to completion, at which point the barrier work item executes.
         Once the barrier work item finishes, the queue returns to scheduling work items that were submitted after the barrier.
         
         barrier 应该更多的是和队列调度相关.
         */
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
    @inline(__always)
    func async(flags: DispatchWorkItemFlags?, _ body: @escaping() -> Void) {
        switch self {
        case .none:
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
