//
//  Store.swift
//  ReSwift
//
//  Created by Benjamin Encz on 11/11/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

/**
 This class is the default implementation of the `StoreType` protocol. You will use this store in most
 of your applications. You shouldn't need to implement your own store.
 You initialize the store with a reducer and an initial application state. If your app has multiple
 reducers you can combine them by initializing a `MainReducer` with all of your reducers as an
 argument.
 */

open class Store<State>: StoreType {

    typealias SubscriptionType = SubscriptionBox<State>

    fileprivate var _state: State!
    private(set) public var state: State! {
        set {
            os_unfair_lock_lock(stateMutex)
            _state = newValue
            stateGeneration += 1
            os_unfair_lock_unlock(stateMutex)
        }
        get {
            os_unfair_lock_lock(stateMutex)
            let copy = _state
            os_unfair_lock_unlock(stateMutex)
            return copy
        }
    }

    public lazy var dispatchFunction: DispatchFunction! = createDispatchFunction()

    private var reducer: Reducer<State>

    var subscriptions: Set<SubscriptionType> = []

    private var previouslyNotifiedState: State?
    private(set) public var stateGeneration: UInt = 0
    private(set) public var notifiedGeneration: UInt = 0

    #if DEBUG
    private var notifying = false
    #endif

    fileprivate let stateMutex = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    fileprivate let reduceMutex = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    /// Indicates if new subscriptions attempt to apply `skipRepeats` 
    /// by default.
    fileprivate let subscriptionsAutomaticallySkipRepeats: Bool

    public var middleware: [Middleware<State>] {
        didSet {
            dispatchFunction = createDispatchFunction()
        }
    }

    /// Initializes the store with a reducer, an initial state and a list of middleware.
    ///
    /// Middleware is applied in the order in which it is passed into this constructor.
    ///
    /// - parameter reducer: Main reducer that processes incoming actions.
    /// - parameter state: Initial state, if any. Can be `nil` and will be 
    ///   provided by the reducer in that case.
    /// - parameter middleware: Ordered list of action pre-processors, acting 
    ///   before the root reducer.
    /// - parameter automaticallySkipsRepeats: If `true`, the store will attempt 
    ///   to skip idempotent state updates when a subscriber's state type 
    ///   implements `Equatable`. Defaults to `true`.
    public required init(
        reducer: @escaping Reducer<State>,
        state: State?,
        middleware: [Middleware<State>] = [],
        automaticallySkipsRepeats: Bool = true
    ) {
        self.subscriptionsAutomaticallySkipRepeats = automaticallySkipsRepeats
        self.reducer = reducer
        self.middleware = middleware
        self.stateMutex.initialize(to: .init())
        self.reduceMutex.initialize(to: .init())

        if let state = state {
            self._state = state
        } else {
            dispatch(ReSwiftInit())
        }
    }

    deinit {
        stateMutex.deallocate()
        reduceMutex.deallocate()
    }

    private func notifySubscribers() {
        if Thread.isMainThread {
            mainThreadOnlyNotifySubscribers()
        } else {
            DispatchQueue.main.async {
                self.mainThreadOnlyNotifySubscribers()
            }
        }
    }

    // Should be called only from the main thread
    private func mainThreadOnlyNotifySubscribers() {
        os_unfair_lock_lock(stateMutex)
        let state = self._state!
        let stateGeneration = self.stateGeneration
        os_unfair_lock_unlock(stateMutex)

        guard self.notifiedGeneration < stateGeneration else { return }

        let previous = self.previouslyNotifiedState
        self.previouslyNotifiedState = state
        self.notifiedGeneration = stateGeneration

        #if DEBUG
        notifying = true
        #endif
        subscriptions.forEach {
            if $0.subscriber == nil {
                subscriptions.remove($0)
            } else {
                $0.newValues(oldState: previous, newState: state)
            }
        }
        #if DEBUG
        notifying = false
        #endif
    }

    private func createDispatchFunction() -> DispatchFunction! {
        // Wrap the dispatch function with all middlewares
        return middleware
            .reversed()
            .reduce(
                { [unowned self] action in
                    self._defaultDispatch(action: action) },
                { dispatchFunction, middleware in
                    // If the store get's deinitialized before the middleware is complete; drop
                    // the action without dispatching.
                    let dispatch: (Action) -> Void = { [weak self] in self?.dispatch($0) }
                    let getState: () -> State? = { [weak self] in self?.state }
                    return middleware(dispatch, getState)(dispatchFunction)
            })
    }

    fileprivate func _subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S, originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<SelectedState>?)
        where S.StoreSubscriberStateType == SelectedState
    {
        let subscriptionBox = self.subscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )

        subscriptions.update(with: subscriptionBox)

        if let state = self.state {
            originalSubscription.newValues(oldState: nil, newState: state)
        }
    }

    open func subscribe<S: StoreSubscriber>(_ subscriber: S)
        where S.StoreSubscriberStateType == State {
            subscribe(subscriber, transform: nil)
    }

    open func subscribe<SelectedState, S: StoreSubscriber>(
        _ subscriber: S, transform: ((Subscription<State>) -> Subscription<SelectedState>)?
    ) where S.StoreSubscriberStateType == SelectedState
    {
        // Create a subscription for the new subscriber.
        let originalSubscription = Subscription<State>()
        // Call the optional transformation closure. This allows callers to modify
        // the subscription, e.g. in order to subselect parts of the store's state.
        let transformedSubscription = transform?(originalSubscription)

        _subscribe(subscriber, originalSubscription: originalSubscription,
                   transformedSubscription: transformedSubscription)
    }

    func subscriptionBox<T>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<T>?,
        subscriber: AnyStoreSubscriber
        ) -> SubscriptionBox<State> {

        return SubscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )
    }

    open func unsubscribe(_ subscriber: AnyStoreSubscriber) {
        #if swift(>=5.0)
        if let index = subscriptions.firstIndex(where: { return $0.subscriber === subscriber }) {
            subscriptions.remove(at: index)
        }
        #else
        if let index = subscriptions.index(where: { return $0.subscriber === subscriber }) {
            subscriptions.remove(at: index)
        }
        #endif
    }

    // swiftlint:disable:next identifier_name
    open func _defaultDispatch(action: Action) {
        #if DEBUG
        if Thread.isMainThread && notifying {
            print("[redux] Dispatching in response to a subscription update is an error: \(action)")
        }
        #endif
        os_unfair_lock_lock(reduceMutex)
        state = reducer(action, state)
        os_unfair_lock_unlock(reduceMutex)
        notifySubscribers()
    }

    open func dispatch(_ action: Action) {
        dispatchFunction(action)
    }

    public typealias DispatchCallback = (State) -> Void
}

// MARK: Skip Repeats for Equatable States

extension Store {
    open func subscribe<SelectedState: Equatable, S: StoreSubscriber>(
        _ subscriber: S, transform: ((Subscription<State>) -> Subscription<SelectedState>)?
        ) where S.StoreSubscriberStateType == SelectedState
    {
        let originalSubscription = Subscription<State>()

        var transformedSubscription = transform?(originalSubscription)
        if subscriptionsAutomaticallySkipRepeats {
            transformedSubscription = transformedSubscription?.skipRepeats()
        }
        _subscribe(subscriber, originalSubscription: originalSubscription,
                   transformedSubscription: transformedSubscription)
    }
}

extension Store where State: Equatable {
    open func subscribe<S: StoreSubscriber>(_ subscriber: S)
        where S.StoreSubscriberStateType == State {
            guard subscriptionsAutomaticallySkipRepeats else {
                subscribe(subscriber, transform: nil)
                return
            }
            subscribe(subscriber, transform: { $0.skipRepeats() })
    }
}
