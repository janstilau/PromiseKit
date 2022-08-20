import Dispatch

enum Sealant<R> {
    case pending(ActionContainer<R>)
    case resolved(R)
}

// 这是一个引用类型, 这是非常重要的. 引用类型在枚举中进行存储, 读取之后做数据修改, 枚举不用重新赋值.
final class ActionContainer<R> {
    var bodies: [(R) -> Void] = []
    func append(_ item: @escaping(R) -> Void) { bodies.append(item) }
}

/// - Remark: not protocol ∵ http://www.russbishop.net/swift-associated-types-cont
class Box<T> {
    func inspect() -> Sealant<T> { fatalError() }
    func inspect(_: (Sealant<T>) -> Void) { fatalError() }
    func seal(_: T) {}
}

/*
 封箱状态.
 */
final class SealedBox<T>: Box<T> {
    let value: T
    
    init(value: T) {
        self.value = value
    }
    
    override func inspect() -> Sealant<T> {
        return .resolved(value)
    }
}

/*
 未封箱状态. 可变为封箱状态.
 */
class EmptyBox<T>: Box<T> {
    // 这种, .init 的写法, 在自己的代码里面很少写.
    private var sealant = Sealant<T>.pending(.init())
    // 这里没太明白, barrier 在使用的时候, 都是使用的 sync.
    private let barrier = DispatchQueue(label: "org.promisekit.barrier", attributes: .concurrent)
    
    override func seal(_ value: T) {
        var handlers: ActionContainer<T>!
        barrier.sync(flags: .barrier) {
            guard case .pending(let _handlers) = self.sealant else {
                return  // already fulfilled!
            }
            handlers = _handlers
            // Enum 的替换, 直接让里面的数据也整体进行了替换.
            self.sealant = .resolved(value)
        }
        if let handlers = handlers {
            handlers.bodies.forEach{ $0(value) }
        }
    }
    
    override func inspect() -> Sealant<T> {
        var rv: Sealant<T>!
        barrier.sync {
            rv = self.sealant
        }
        return rv
    }
    
    override func inspect(_ body: (Sealant<T>) -> Void) {
        var sealed = false
        barrier.sync(flags: .barrier) {
            switch sealant {
            case .pending:
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
