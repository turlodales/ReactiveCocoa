import Result

/// A SignalProducer creates Signals that can produce values of type `T` and/or
/// error out with errors of type `E`. If no errors should be possible, NoError
/// can be specified for `E`.
///
/// SignalProducers can be used to represent operations or tasks, like network
/// requests, where each invocation of start() will create a new underlying
/// operation. This ensures that consumers will receive the results, versus a
/// plain Signal, where the results might be sent before any observers are
/// attached.
///
/// Because of the behavior of start(), different Signals created from the
/// producer may see a different version of Events. The Events may arrive in a
/// different order between Signals, or the stream might be completely
/// different!
public struct SignalProducer<T, E: ErrorType> {
	private let startHandler: (Signal<T, E>.Observer, CompositeDisposable) -> ()

	/// Initializes a SignalProducer that will invoke the given closure once
	/// for each invocation of start().
	///
	/// The events that the closure puts into the given sink will become the
	/// events sent by the started Signal to its observers.
	///
	/// If the Disposable returned from start() is disposed or a terminating
	/// event is sent to the observer, the given CompositeDisposable will be
	/// disposed, at which point work should be interrupted and any temporary
	/// resources cleaned up.
	public init(_ startHandler: (Signal<T, E>.Observer, CompositeDisposable) -> ()) {
		self.startHandler = startHandler
	}

	/// Creates a producer for a Signal that will immediately send one value
	/// then complete.
	public init(value: T) {
		self.init({ observer, disposable in
			sendNext(observer, value)
			sendCompleted(observer)
		})
	}

	/// Creates a producer for a Signal that will immediately send an error.
	public init(error: E) {
		self.init({ observer, disposable in
			sendError(observer, error)
		})
	}

	/// Creates a producer for a Signal that will immediately send one value
	/// then complete, or immediately send an error, depending on the given
	/// Result.
	public init(result: Result<T, E>) {
		switch result {
		case let .Success(value):
			self.init(value: value)

		case let .Failure(error):
			self.init(error: error)
		}
	}

	/// Creates a producer for a Signal that will immediately send the values
	/// from the given sequence, then complete.
	public init<S: SequenceType where S.Generator.Element == T>(values: S) {
		self.init({ observer, disposable in
			for value in values {
				sendNext(observer, value)

				if disposable.disposed {
					break
				}
			}

			sendCompleted(observer)
		})
	}

	/// A producer for a Signal that will immediately complete without sending
	/// any values.
	public static var empty: SignalProducer {
		return self { observer, disposable in
			sendCompleted(observer)
		}
	}

	/// A producer for a Signal that never sends any events to its observers.
	public static var never: SignalProducer {
		return self { _ in () }
	}

	/// Creates a queue for events that replays them when new signals are
	/// created from the returned producer.
	///
	/// When values are put into the returned observer (sink), they will be
	/// added to an internal buffer. If the buffer is already at capacity, 
	/// the earliest (oldest) value will be dropped to make room for the new
	/// value.
	///
	/// Signals created from the returned producer will stay alive until a
	/// terminating event is added to the queue. If the queue does not contain
	/// such an event when the Signal is started, all values sent to the
	/// returned observer will be automatically forwarded to the Signal’s
	/// observers until a terminating event is received.
	///
	/// After a terminating event has been added to the queue, the observer
	/// will not add any further events. This _does not_ count against the
	/// value capacity so no buffered values will be dropped on termination.
	public static func buffer(capacity: Int = Int.max) -> (SignalProducer, Signal<T, E>.Observer) {
		precondition(capacity >= 0)

		let lock = NSLock()
		lock.name = "org.reactivecocoa.ReactiveCocoa.SignalProducer.buffer"

		var events: [Event<T, E>] = []
		var terminationEvent: Event<T,E>?
		let observers: Atomic<Bag<Signal<T, E>.Observer>?> = Atomic(Bag())

		let producer = self { observer, disposable in
			lock.lock()

			var token: RemovalToken?
			observers.modify { observers in
				guard var observers = observers else { return nil }
				token = observers.insert(observer)
				return observers
			}

			for event in events {
				observer(event)
			}

			if let terminationEvent = terminationEvent {
				observer(terminationEvent)
			}

			lock.unlock()

			if let token = token {
				disposable.addDisposable {
					observers.modify { observers in
						guard var observers = observers else { return nil }

						observers.removeValueForToken(token)
						return observers
					}
				}
			}
		}

		let bufferingObserver: Signal<T, E>.Observer = { event in
			lock.lock()
			
			let oldObservers = observers.modify { (observers) in
				if event.isTerminating {
					return nil
				} else {
					return observers
				}
			}

			// If not disposed…
			if let liveObservers = oldObservers {
				if event.isTerminating {
					terminationEvent = event
				} else {
					events.append(event)
					while events.count > capacity {
						events.removeAtIndex(0)
					}
				}

				for observer in liveObservers {
					observer(event)
				}
			}
			
			lock.unlock()
		}

		return (producer, bufferingObserver)
	}

	/// Creates a SignalProducer that will attempt the given operation once for
	/// each invocation of start().
	///
	/// Upon success, the started signal will send the resulting value then
	/// complete. Upon failure, the started signal will send the error that
	/// occurred.
	public static func attempt(operation: () -> Result<T, E>) -> SignalProducer {
		return self { observer, disposable in
			operation().analysis(ifSuccess: { value in
				sendNext(observer, value)
				sendCompleted(observer)
			}, ifFailure: { error in
				sendError(observer, error)
			})
		}
	}

	/// Creates a Signal from the producer, passes it into the given closure,
	/// then starts sending events on the Signal when the closure has returned.
	///
	/// The closure will also receive a disposable which can be used to
	/// interrupt the work associated with the signal and immediately send an
	/// `Interrupted` event.
	public func startWithSignal(@noescape setUp: (Signal<T, E>, Disposable) -> ()) {
		let (signal, sink) = Signal<T, E>.pipe()

		// Disposes of the work associated with the SignalProducer and any
		// upstream producers.
		let producerDisposable = CompositeDisposable()

		// Directly disposed of when start() or startWithSignal() is disposed.
		let cancelDisposable = ActionDisposable {
			sendInterrupted(sink)
			producerDisposable.dispose()
		}

		setUp(signal, cancelDisposable)

		if cancelDisposable.disposed {
			return
		}

		let wrapperObserver: Signal<T, E>.Observer = { event in
			sink(event)

			if event.isTerminating {
				// Dispose only after notifying the Signal, so disposal
				// logic is consistently the last thing to run.
				producerDisposable.dispose()
			}
		}

		startHandler(wrapperObserver, producerDisposable)
	}

	/// Creates a Signal from the producer, then attaches the given sink to the
	/// Signal as an observer.
	///
	/// Returns a Disposable which can be used to interrupt the work associated
	/// with the signal and immediately send an `Interrupted` event.
	public func start(sink: Event<T, E>.Sink) -> Disposable {
		var disposable: Disposable!

		startWithSignal { signal, innerDisposable in
			signal.observe(sink)
			disposable = innerDisposable
		}

		return disposable
	}

	/// Creates a Signal from the producer, then adds exactly one observer to
	/// the Signal, which will invoke the given callbacks when events are
	/// received.
	///
	/// Returns a Disposable which can be used to interrupt the work associated
	/// with the Signal, and prevent any future callbacks from being invoked.
	public func start(next next: (T -> ())? = nil, error: (E -> ())? = nil, completed: (() -> ())? = nil, interrupted: (() -> ())? = nil) -> Disposable {
		return start(Event.sink(next: next, error: error, completed: completed, interrupted: interrupted))
	}

	/// Lifts an unary Signal operator to operate upon SignalProducers instead.
	///
	/// In other words, this will create a new SignalProducer which will apply
	/// the given Signal operator to _every_ created Signal, just as if the
	/// operator had been applied to each Signal yielded from start().
	public func lift<U, F>(transform: Signal<T, E> -> Signal<U, F>) -> SignalProducer<U, F> {
		return SignalProducer<U, F> { observer, outerDisposable in
			self.startWithSignal { signal, innerDisposable in
				outerDisposable.addDisposable(innerDisposable)

				transform(signal).observe(observer)
			}
		}
	}

	/// Lifts a binary Signal operator to operate upon SignalProducers instead.
	///
	/// In other words, this will create a new SignalProducer which will apply
	/// the given Signal operator to _every_ Signal created from the two
	/// producers, just as if the operator had been applied to each Signal
	/// yielded from start().
	public func lift<U, F, V, G>(transform: Signal<U, F> -> Signal<T, E> -> Signal<V, G>) -> SignalProducer<U, F> -> SignalProducer<V, G> {
		return { otherProducer in
			return SignalProducer<V, G> { observer, outerDisposable in
				self.startWithSignal { signal, disposable in
					outerDisposable.addDisposable(disposable)

					otherProducer.startWithSignal { otherSignal, otherDisposable in
						outerDisposable.addDisposable(otherDisposable)

						transform(otherSignal)(signal).observe(observer)
					}
				}
			}
		}
	}
}

public protocol SignalProducerType {
	/// The type of values being sent on the producer
	typealias T
	/// The type of error that can occur on the producer. If errors aren't possible
	/// than `NoError` can be used.
	typealias E: ErrorType

	/// Creates a Signal from the producer, passes it into the given closure,
	/// then starts sending events on the Signal when the closure has returned.
	func startWithSignal(@noescape setUp: (Signal<T, E>, Disposable) -> ())

	/// Lifts an unary Signal operator to operate upon SignalProducers instead.
	func lift<U, F>(transform: Signal<T, E> -> Signal<U, F>) -> SignalProducer<U, F>

	/// Lifts a binary Signal operator to operate upon SignalProducers instead.
	func lift<U, F, V, G>(transform: Signal<U, F> -> Signal<T, E> -> Signal<V, G>) -> SignalProducer<U, F> -> SignalProducer<V, G>
}

extension SignalProducer: SignalProducerType {
}

extension SignalProducerType {
	/// Maps each value in the producer to a new value.
	public func map<U>(transform: T -> U) -> SignalProducer<U, E> {
		return lift { $0.map(transform) }
	}

	/// Maps errors in the producer to a new error.
	public func mapError<F>(transform: E -> F) -> SignalProducer<T, F> {
		return lift { $0.mapError(transform) }
	}
	
	/// Preserves only the values of the producer that pass the given predicate.
	public func filter(predicate: T -> Bool) -> SignalProducer<T, E> {
		return lift { $0.filter(predicate) }
	}

	/// Maps values from the producer and forwards the non-nil ones on the
	/// returned producer.
	public func filterMap<U>(transform: T -> U?) -> SignalProducer<U, E> {
		return lift { $0.filterMap(transform) }
	}

	/// Returns a producer that will yield the first `count` values from the
	/// input producer.
	public func take(count: Int) -> SignalProducer<T, E> {
		return lift { $0.take(count) }
	}

	/// Returns a signal that will yield an array of values when `signal` completes.
	public func collect() -> SignalProducer<[T], E> {
		return lift { $0.collect() }
	}

	/// Forwards all events onto the given scheduler, instead of whichever
	/// scheduler they originally arrived upon.
	public func observeOn(scheduler: SchedulerType) -> SignalProducer<T, E> {
		return lift { $0.observeOn(scheduler) }
	}

	/// Combines the latest value of the receiver with the latest value from
	/// the given producer.
	///
	/// The returned producer will not send a value until both inputs have sent at
	/// least one value each. If either producer is interrupted, the returned producer
	/// will also be interrupted.
	public func combineLatestWith<U>(otherProducer: SignalProducer<U, E>) -> SignalProducer<(T, U), E> {
		return lift(ReactiveCocoa.combineLatestWith)(otherProducer)
	}

	/// Delays `Next` and `Completed` events by the given interval, forwarding
	/// them on the given scheduler.
	///
	/// `Error` and `Interrupted` events are always scheduled immediately.
	public func delay(interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType) -> SignalProducer<T, E> {
		return lift { $0.delay(interval, onScheduler: scheduler) }
	}

	/// Returns a producer that will skip the first `count` values, then forward
	/// everything afterward.
	public func skip(count: Int) -> SignalProducer<T, E> {
		return lift { $0.skip(count) }
	}

	/// Treats all Events from the input producer as plain values, allowing them to be
	/// manipulated just like any other value.
	///
	/// In other words, this brings Events “into the monad.”
	///
	/// When a Completed or Error event is received, the resulting producer will send
	/// the Event itself and then complete. When an Interrupted event is received,
	/// the resulting producer will send the Event itself and then interrupt.
	public func materialize() -> SignalProducer<Event<T, E>, NoError> {
		return lift { $0.materialize() }
	}

	/// Forwards the latest value from `self` whenever `sampler` sends a Next
	/// event.
	///
	/// If `sampler` fires before a value has been observed on `self`, nothing
	/// happens.
	///
	/// Returns a producer that will send values from `self`, sampled (possibly
	/// multiple times) by `sampler`, then complete once both input producers have
	/// completed, or interrupt if either input producer is interrupted.
	public func sampleOn(sampler: SignalProducer<(), NoError>) -> SignalProducer<T, E> {
		return lift(ReactiveCocoa.sampleOn)(sampler)
	}

	/// Forwards events from `self` until `trigger` sends a Next or Completed
	/// event, at which point the returned producer will complete.
	public func takeUntil(trigger: SignalProducer<(), NoError>) -> SignalProducer<T, E> {
		return lift(ReactiveCocoa.takeUntil)(trigger)
	}

	/// Forwards events from `self` with history: values of the returned producer
	/// are a tuple whose first member is the previous value and whose second member
	/// is the current value. `initial` is supplied as the first member when `self`
	/// sends its first value.
	public func combinePrevious(initial: T) -> SignalProducer<(T, T), E> {
		return lift { $0.combinePrevious(initial) }
	}

	/// Like `scan`, but sends only the final value and then immediately completes.
	public func reduce<U>(initial: U, _ combine: (U, T) -> U) -> SignalProducer<U, E> {
		return lift { $0.reduce(initial, combine) }
	}

	/// Aggregates `self`'s values into a single combined value. When `self` emits
	/// its first value, `combine` is invoked with `initial` as the first argument and
	/// that emitted value as the second argument. The result is emitted from the
	/// producer returned from `scan`. That result is then passed to `combine` as the
	/// first argument when the next value is emitted, and so on.
	public func scan<U>(initial: U, _ combine: (U, T) -> U) -> SignalProducer<U, E> {
		return lift { $0.scan(initial, combine) }
	}

	/// Forwards only those values from `self` which do not pass `isRepeat` with
	/// respect to the previous value. The first value is always forwarded.
	public func skipRepeats(isRepeat: (T, T) -> Bool) -> SignalProducer<T, E> {
		return lift { $0.skipRepeats(isRepeat) }
	}

	/// Does not forward any values from `self` until `predicate` returns false,
	/// at which point the returned signal behaves exactly like `self`.
	public func skipWhile(predicate: T -> Bool) -> SignalProducer<T, E> {
		return lift { $0.skipWhile(predicate) }
	}

	/// Forwards events from `self` until `replacement` begins sending events.
	///
	/// Returns a producer which passes through `Next`, `Error`, and `Interrupted`
	/// events from `self` until `replacement` sends an event, at which point the
	/// returned producer will send that event and switch to passing through events
	/// from `replacement` instead, regardless of whether `self` has sent events
	/// already.
	public func takeUntilReplacement(replacement: SignalProducer<T, E>) -> SignalProducer<T, E> {
		return lift(ReactiveCocoa.takeUntilReplacement)(replacement)
	}

	/// Waits until `self` completes and then forwards the final `count` values
	/// on the returned producer.
	public func takeLast(count: Int) -> SignalProducer<T, E> {
		return lift { $0.takeLast(count) }
	}

	/// Forwards any values from `self` until `predicate` returns false,
	/// at which point the returned producer will complete.
	public func takeWhile(predicate: T -> Bool) -> SignalProducer<T, E> {
		return lift { $0.takeWhile(predicate) }
	}

	/// Zips elements of two producers into pairs. The elements of any Nth pair
	/// are the Nth elements of the two input producers.
	public func zipWith<U>(otherProducer: SignalProducer<U, E>) -> SignalProducer<(T, U), E> {
		return lift(ReactiveCocoa.zipWith)(otherProducer)
	}

	/// Applies `operation` to values from `self` with `Success`ful results
	/// forwarded on the returned producer and `Failure`s sent as `Error` events.
	public func attempt(operation: T -> Result<(), E>) -> SignalProducer<T, E> {
		return lift { $0.attempt(operation) }
	}

	/// Applies `operation` to values from `self` with `Success`ful results mapped
	/// on the returned producer and `Failure`s sent as `Error` events.
	public func attemptMap<U>(operation: T -> Result<U, E>) -> SignalProducer<U, E> {
		return lift { $0.attemptMap(operation) }
	}

	/// Throttle values sent by the receiver, so that at least `interval`
	/// seconds pass between each, then forwards them on the given scheduler.
	///
	/// If multiple values are received before the interval has elapsed, the
	/// latest value is the one that will be passed on.
	///
	/// If `self` terminates while a value is being throttled, that value
	/// will be discarded and the returned producer will terminate immediately.
	public func throttle(interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType) -> SignalProducer<T, E> {
		return lift { $0.throttle(interval, onScheduler: scheduler) }
	}

	/// Forwards events from `self` until `interval`. Then if producer isn't completed yet,
	/// errors with `error` on `scheduler`.
	///
	/// If the interval is 0, the timeout will be scheduled immediately. The producer
	/// must complete synchronously (or on a faster scheduler) to avoid the timeout.
	public func timeoutWithError(error: E, afterInterval interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType) -> SignalProducer<T, E> {
		return lift { $0.timeoutWithError(error, afterInterval: interval, onScheduler: scheduler) }
	}

}

extension SignalProducerType where E == NoError {
	/// Promotes a producer that does not generate errors into one that can.
	///
	/// This does not actually cause errors to be generated for the given producer,
	/// but makes it easier to combine with other producers that may error; for
	/// example, with operators like `combineLatestWith`, `zipWith`, `flatten`, etc.
	public func promoteErrors<F: ErrorType>() -> SignalProducer<T, F> {
		return lift { $0.promoteErrors() }
	}
}

extension SignalProducerType where T: Equatable {
	/// Forwards only those values from `self` which are not duplicates of the
	/// immedately preceding value. The first value is always forwarded.
	public func skipRepeats() -> SignalProducer<T, E> {
		return lift { $0.skipRepeats() }
	}
}


/// Applies a Signal operator to a SignalProducer (equivalent to
/// SignalProducer.lift).
///
/// This will create a new SignalProducer which will apply the given Signal
/// operator to _every_ created Signal, just as if the operator had been applied
/// to each Signal yielded from start().
///
/// Example:
///
/// 	let filteredProducer = intProducer |> filter { num in num % 2 == 0 }
public func |> <T, E, U, F>(producer: SignalProducer<T, E>, transform: Signal<T, E> -> Signal<U, F>) -> SignalProducer<U, F> {
	return producer.lift(transform)
}

/// Applies a SignalProducer operator to a SignalProducer.
///
/// Example:
///
/// 	filteredProducer
/// 	|> startOn(UIScheduler())
/// 	|> start { signal in
/// 		signal.observe(next: { num in println(num) })
/// 	}
public func |> <T, E, X>(producer: SignalProducer<T, E>, @noescape transform: SignalProducer<T, E> -> X) -> X {
	return transform(producer)
}

/// Creates a repeating timer of the given interval, with a reasonable
/// default leeway, sending updates on the given scheduler.
///
/// This timer will never complete naturally, so all invocations of start() must
/// be disposed to avoid leaks.
public func timer(interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType) -> SignalProducer<NSDate, NoError> {
	// Apple's "Power Efficiency Guide for Mac Apps" recommends a leeway of
	// at least 10% of the timer interval.
	return timer(interval, onScheduler: scheduler, withLeeway: interval * 0.1)
}

/// Creates a repeating timer of the given interval, sending updates on the
/// given scheduler.
///
/// This timer will never complete naturally, so all invocations of start() must
/// be disposed to avoid leaks.
public func timer(interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType, withLeeway leeway: NSTimeInterval) -> SignalProducer<NSDate, NoError> {
	precondition(interval >= 0)
	precondition(leeway >= 0)

	return SignalProducer { observer, compositeDisposable in
		compositeDisposable += scheduler.scheduleAfter(scheduler.currentDate.dateByAddingTimeInterval(interval), repeatingEvery: interval, withLeeway: leeway) {
			sendNext(observer, scheduler.currentDate)
		}
		return ()
	}
}

extension SignalProducerType {
	/// Injects side effects to be performed upon the specified signal events.
	public func on(started started: (() -> ())? = nil, event: (Event<T, E> -> ())? = nil, error: (E -> ())? = nil, completed: (() -> ())? = nil, interrupted: (() -> ())? = nil, terminated: (() -> ())? = nil, disposed: (() -> ())? = nil, next: (T -> ())? = nil) -> SignalProducer<T, E> {
		return SignalProducer { observer, compositeDisposable in
			started?()
			disposed.map(compositeDisposable.addDisposable)

			self.startWithSignal { signal, disposable in
				compositeDisposable.addDisposable(disposable)

				signal.observe { receivedEvent in
					event?(receivedEvent)

					switch receivedEvent {
					case let .Next(value):
						next?(value)

					case let .Error(err):
						error?(err)

					case .Completed:
						completed?()

					case .Interrupted:
						interrupted?()
					}

					if receivedEvent.isTerminating {
						terminated?()
					}

					observer(receivedEvent)
				}
			}
		}
	}

	/// Starts the returned signal on the given Scheduler.
	///
	/// This implies that any side effects embedded in the producer will be
	/// performed on the given scheduler as well.
	///
	/// Events may still be sent upon other schedulers—this merely affects where
	/// the `start()` method is run.
	public func startOn(scheduler: SchedulerType) -> SignalProducer<T, E> {
		return SignalProducer { observer, compositeDisposable in
			compositeDisposable += scheduler.schedule {
				self.startWithSignal { signal, signalDisposable in
					compositeDisposable.addDisposable(signalDisposable)
					signal.observe(observer)
				}
			}
			return ()
		}
	}
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>) -> SignalProducer<(A, B), Error> {
	return a.combineLatestWith(b)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>) -> SignalProducer<(A, B, C), Error> {
	return combineLatest(a, b: b)
		.combineLatestWith(c)
		.map(repack)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>) -> SignalProducer<(A, B, C, D), Error> {
	return combineLatest(a, b: b, c: c)
		.combineLatestWith(d)
		.map(repack)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>) -> SignalProducer<(A, B, C, D, E), Error> {
	return combineLatest(a, b: b, c: c, d: d)
		.combineLatestWith(e)
		.map(repack)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>) -> SignalProducer<(A, B, C, D, E, F), Error> {
	return combineLatest(a, b: b, c: c, d: d, e: e)
		.combineLatestWith(f)
		.map(repack)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, G, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>, g: SignalProducer<G, Error>) -> SignalProducer<(A, B, C, D, E, F, G), Error> {
	return combineLatest(a, b: b, c: c, d: d, e: e, f: f)
		.combineLatestWith(g)
		.map(repack)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, G, H, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>, g: SignalProducer<G, Error>, h: SignalProducer<H, Error>) -> SignalProducer<(A, B, C, D, E, F, G, H), Error> {
	return combineLatest(a, b: b, c: c, d: d, e: e, f: f, g: g)
		.combineLatestWith(h)
		.map(repack)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, G, H, I, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>, g: SignalProducer<G, Error>, h: SignalProducer<H, Error>, i: SignalProducer<I, Error>) -> SignalProducer<(A, B, C, D, E, F, G, H, I), Error> {
	return combineLatest(a, b: b, c: c, d: d, e: e, f: f, g: g, h: h)
		.combineLatestWith(i)
		.map(repack)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`.
public func combineLatest<A, B, C, D, E, F, G, H, I, J, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>, g: SignalProducer<G, Error>, h: SignalProducer<H, Error>, i: SignalProducer<I, Error>, j: SignalProducer<J, Error>) -> SignalProducer<(A, B, C, D, E, F, G, H, I, J), Error> {
	return combineLatest(a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i)
		.combineLatestWith(j)
		.map(repack)
}

/// Combines the values of all the given producers, in the manner described by
/// `combineLatestWith`. Will return an empty `SignalProducer` if the sequence is empty.
public func combineLatest<S: SequenceType, T, Error where S.Generator.Element == SignalProducer<T, Error>>(producers: S) -> SignalProducer<[T], Error> {
	var generator = producers.generate()
	if let first = generator.next() {
		let initial = first.map { [$0] }
		return GeneratorSequence(generator).reduce(initial) { producer, next in
			producer.combineLatestWith(next).map { $0.0 + [$0.1] }
		}
	}
	
	return .empty
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>) -> SignalProducer<(A, B), Error> {
	return a.zipWith(b)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, C, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>) -> SignalProducer<(A, B, C), Error> {
	return zip(a, b: b)
		.zipWith(c)
		.map(repack)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>) -> SignalProducer<(A, B, C, D), Error> {
	return zip(a, b: b, c: c)
		.zipWith(d)
		.map(repack)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>) -> SignalProducer<(A, B, C, D, E), Error> {
	return zip(a, b: b, c: c, d: d)
		.zipWith(e)
		.map(repack)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>) -> SignalProducer<(A, B, C, D, E, F), Error> {
	return zip(a, b: b, c: c, d: d, e: e)
		.zipWith(f)
		.map(repack)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, G, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>, g: SignalProducer<G, Error>) -> SignalProducer<(A, B, C, D, E, F, G), Error> {
	return zip(a, b: b, c: c, d: d, e: e, f: f)
		.zipWith(g)
		.map(repack)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, G, H, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>, g: SignalProducer<G, Error>, h: SignalProducer<H, Error>) -> SignalProducer<(A, B, C, D, E, F, G, H), Error> {
	return zip(a, b: b, c: c, d: d, e: e, f: f, g: g)
		.zipWith(h)
		.map(repack)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, G, H, I, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>, g: SignalProducer<G, Error>, h: SignalProducer<H, Error>, i: SignalProducer<I, Error>) -> SignalProducer<(A, B, C, D, E, F, G, H, I), Error> {
	return zip(a, b: b, c: c, d: d, e: e, f: f, g: g, h: h)
		.zipWith(i)
		.map(repack)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`.
public func zip<A, B, C, D, E, F, G, H, I, J, Error>(a: SignalProducer<A, Error>, b: SignalProducer<B, Error>, c: SignalProducer<C, Error>, d: SignalProducer<D, Error>, e: SignalProducer<E, Error>, f: SignalProducer<F, Error>, g: SignalProducer<G, Error>, h: SignalProducer<H, Error>, i: SignalProducer<I, Error>, j: SignalProducer<J, Error>) -> SignalProducer<(A, B, C, D, E, F, G, H, I, J), Error> {
	return zip(a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i)
		.zipWith(j)
		.map(repack)
}

/// Zips the values of all the given producers, in the manner described by
/// `zipWith`. Will return an empty `SignalProducer` if the sequence is empty.
public func zip<S: SequenceType, T, Error where S.Generator.Element == SignalProducer<T, Error>>(producers: S) -> SignalProducer<[T], Error> {
	var generator = producers.generate()
	if let first = generator.next() {
		let initial = first.map { [$0] }
		return GeneratorSequence(generator).reduce(initial) { producer, next in
			producer.zipWith(next).map { $0.0 + [$0.1] }
		}
	}

	return .empty
}

/// Catches any error that may occur on the input producer, mapping to a new producer
/// that starts in its place.
public func flatMapError<T, E, F>(handler: E -> SignalProducer<T, F>) -> SignalProducer<T, E> -> SignalProducer<T, F> {
	return { producer in
		return SignalProducer { observer, disposable in
			let serialDisposable = SerialDisposable()
			disposable.addDisposable(serialDisposable)

			producer.startWithSignal { signal, signalDisposable in
				serialDisposable.innerDisposable = signalDisposable

				signal.observe(next: { value in
					sendNext(observer, value)
				}, error: { error in
					handler(error).startWithSignal { signal, signalDisposable in
						serialDisposable.innerDisposable = signalDisposable
						signal.observe(observer)
					}
				}, completed: {
					sendCompleted(observer)
				}, interrupted: {
					sendInterrupted(observer)
				})
			}
		}
	}
}

/// `concat`s `next` onto `producer`.
public func concat<T, E>(next: SignalProducer<T, E>) -> SignalProducer<T, E> -> SignalProducer<T, E> {
	return { producer in
		return SignalProducer(values: [producer, next]) |> flatten(.Concat)
	}
}

/// Repeats `producer` a total of `count` times.
/// Repeating `1` times results in a equivalent signal producer.
public func times<T, E>(count: Int) -> SignalProducer<T, E> -> SignalProducer<T, E> {
	precondition(count >= 0)

	return { producer in
		if count == 0 {
			return .empty
		} else if count == 1 {
			return producer
		}

		return SignalProducer { observer, disposable in
			let serialDisposable = SerialDisposable()
			disposable.addDisposable(serialDisposable)

			func iterate(current: Int) {
				producer.startWithSignal { signal, signalDisposable in
					serialDisposable.innerDisposable = signalDisposable

					signal.observe { event in
						switch event {
						case .Completed:
							let remainingTimes = current - 1
							if remainingTimes > 0 {
								iterate(remainingTimes)
							} else {
								sendCompleted(observer)
							}

						default:
							observer(event)
						}
					}
				}
			}

			iterate(count)
		}
	}
}

/// Ignores errors up to `count` times.
public func retry<T, E>(count: Int) -> SignalProducer<T, E> -> SignalProducer<T, E> {
	precondition(count >= 0)

	return { producer in
		if count == 0 {
			return producer
		} else {
			return producer |> flatMapError { _ in
				producer |> retry(count - 1)
			}
		}
	}
}

/// Waits for completion of `producer`, *then* forwards all events from
/// `replacement`. Any error sent from `producer` is forwarded immediately, in
/// which case `replacement` will not be started, and none of its events will be
/// be forwarded. All values sent from `producer` are ignored.
public func then<T, U, E>(replacement: SignalProducer<U, E>) -> SignalProducer<T, E> -> SignalProducer<U, E> {
	return { producer in
		let relay = SignalProducer<U, E> { observer, observerDisposable in
			producer.startWithSignal { signal, signalDisposable in
				observerDisposable.addDisposable(signalDisposable)

				signal.observe(error: { error in
					sendError(observer, error)
				}, completed: {
					sendCompleted(observer)
				}, interrupted: {
					sendInterrupted(observer)
				})
			}
		}

		return relay |> concat(replacement)
	}
}

/// Starts the producer, then blocks, waiting for the first value.
public func first<T, E>(producer: SignalProducer<T, E>) -> Result<T, E>? {
	return producer.take(1) |> single
}

/// Starts the producer, then blocks, waiting for events: Next and Completed.
/// When a single value or error is sent, the returned `Result` will represent
/// those cases. However, when no values are sent, or when more than one value
/// is sent, `nil` will be returned.
public func single<T, E>(producer: SignalProducer<T, E>) -> Result<T, E>? {
	let semaphore = dispatch_semaphore_create(0)
	var result: Result<T, E>?

	producer
		.take(2)
		.start(next: { value in
			if result != nil {
				// Move into failure state after recieving another value.
				result = nil
				return
			}
			result = .success(value)
		}, error: { error in
			result = .failure(error)
			dispatch_semaphore_signal(semaphore)
		}, completed: {
			dispatch_semaphore_signal(semaphore)
		}, interrupted: {
			dispatch_semaphore_signal(semaphore)
		})

	dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER)
	return result
}

/// Starts the producer, then blocks, waiting for the last value.
public func last<T, E>(producer: SignalProducer<T, E>) -> Result<T, E>? {
	return producer.takeLast(1) |> single
}

/// Starts the producer, then blocks, waiting for completion.
public func wait<T, E>(producer: SignalProducer<T, E>) -> Result<(), E> {
	let result = producer |> then(SignalProducer(value: ())) |> last
	return result ?? .success(())
}

/// SignalProducer.startWithSignal() as a free function, for easier use with |>.
public func startWithSignal<T, E>(setUp: (Signal<T, E>, Disposable) -> ()) -> SignalProducer<T, E> -> () {
	return { producer in
		return producer.startWithSignal(setUp)
	}
}

/// SignalProducer.start() as a free function, for easier use with |>.
public func start<T, E>(sink: Event<T, E>.Sink) -> SignalProducer<T, E> -> Disposable {
	return { producer in
		return producer.start(sink)
	}
}

/// SignalProducer.start() as a free function, for easier use with |>.
public func start<T, E>(error: (E -> ())? = nil, completed: (() -> ())? = nil, interrupted: (() -> ())? = nil, next: (T -> ())? = nil) -> SignalProducer<T, E> -> Disposable {
	return { producer in
		return producer.start(next: next, error: error, completed: completed, interrupted: interrupted)
	}
}

/// Describes how multiple producers should be joined together.
public enum FlattenStrategy: Equatable {
	/// The producers should be merged, so that any value received on any of the
	/// input producers will be forwarded immediately to the output producer.
	///
	/// The resulting producer will complete only when all inputs have completed.
	case Merge

	/// The producers should be concatenated, so that their values are sent in the
	/// order of the producers themselves.
	///
	/// The resulting producer will complete only when all inputs have completed.
	case Concat

	/// Only the events from the latest input producer should be considered for
	/// the output. Any producers received before that point will be disposed of.
	///
	/// The resulting producer will complete only when the producer-of-producers and
	/// the latest producer has completed.
	case Latest
}

extension FlattenStrategy: CustomStringConvertible {
	public var description: String {
		switch self {
		case .Merge:
			return "merge"

		case .Concat:
			return "concatenate"

		case .Latest:
			return "latest"
		}
	}
}

/// Flattens the inner producers sent upon `producer` (into a single producer of
/// values), according to the semantics of the given strategy.
///
/// If `producer` or an active inner producer emits an error, the returned
/// producer will forward that error immediately.
///
/// `Interrupted` events on inner producers will be treated like `Completed`
/// events on inner producers.
public func flatten<T, E>(strategy: FlattenStrategy) -> SignalProducer<SignalProducer<T, E>, E> -> SignalProducer<T, E> {
	return { producer in
		switch strategy {
		case .Merge:
			return producer |> merge

		case .Concat:
			return producer |> concat

		case .Latest:
			return producer |> switchToLatest
		}
	}
}

/// Maps each event from `producer` to a new producer, then flattens the
/// resulting producers (into a single producer of values), according to the
/// semantics of the given strategy.
///
/// If `producer` or any of the created producers emit an error, the returned
/// producer will forward that error immediately.
public func flatMap<T, U, E>(strategy: FlattenStrategy, transform: T -> SignalProducer<U, E>) -> SignalProducer<T, E> -> SignalProducer<U, E> {
	return { producer in
		return producer.map(transform) |> flatten(strategy)
	}
}

/// Returns a producer which sends all the values from each producer emitted from
/// `producer`, waiting until each inner producer completes before beginning to
/// send the values from the next inner producer.
///
/// If any of the inner producers emit an error, the returned producer will emit
/// that error.
///
/// The returned producer completes only when `producer` and all producers
/// emitted from `producer` complete.
private func concat<T, E>(producer: SignalProducer<SignalProducer<T, E>, E>) -> SignalProducer<T, E> {
	return SignalProducer { observer, disposable in
		let state = ConcatState(observer: observer, disposable: disposable)

		producer.startWithSignal { signal, signalDisposable in
			disposable.addDisposable(signalDisposable)
		
			signal.observe(next: { producer in
				state.enqueueSignalProducer(producer)
			}, error: { error in
				sendError(observer, error)
			}, completed: {
				// Add one last producer to the queue, whose sole job is to
				// "turn out the lights" by completing `observer`.
				let completion = SignalProducer<T, E> { innerObserver, _ in
					sendCompleted(innerObserver)
					sendCompleted(observer)
				}

				state.enqueueSignalProducer(completion)
			}, interrupted: {
				sendInterrupted(observer)
			})
		}
	}
}

private final class ConcatState<T, E: ErrorType> {
	/// The observer of a started `concat` producer.
	let observer: Signal<T, E>.Observer

	/// The top level disposable of a started `concat` producer.
	let disposable: CompositeDisposable

	/// The active producer, if any, and the producers waiting to be started.
	let queuedSignalProducers: Atomic<[SignalProducer<T, E>]> = Atomic([])

	init(observer: Signal<T, E>.Observer, disposable: CompositeDisposable) {
		self.observer = observer
		self.disposable = disposable
	}

	func enqueueSignalProducer(producer: SignalProducer<T, E>) {
		if disposable.disposed {
			return
		}

		var shouldStart = true

		queuedSignalProducers.modify { (var queue) in
			// An empty queue means the concat is idle, ready & waiting to start
			// the next producer.
			shouldStart = queue.isEmpty
			queue.append(producer)
			return queue
		}

		if shouldStart {
			startNextSignalProducer(producer)
		}
	}

	func dequeueSignalProducer() -> SignalProducer<T, E>? {
		if disposable.disposed {
			return nil
		}

		var nextSignalProducer: SignalProducer<T, E>?

		queuedSignalProducers.modify { (var queue) in
			// Active producers remain in the queue until completed. Since
			// dequeueing happens at completion of the active producer, the
			// first producer in the queue can be removed.
			if !queue.isEmpty { queue.removeAtIndex(0) }
			nextSignalProducer = queue.first
			return queue
		}

		return nextSignalProducer
	}

	/// Subscribes to the given signal producer.
	func startNextSignalProducer(signalProducer: SignalProducer<T, E>) {
		signalProducer.startWithSignal { signal, disposable in
			let handle = self.disposable.addDisposable(disposable)

			signal.observe { event in
				switch event {
				case .Completed, .Interrupted:
					handle.remove()

					if let nextSignalProducer = self.dequeueSignalProducer() {
						self.startNextSignalProducer(nextSignalProducer)
					}

				default:
					self.observer(event)
				}
			}
		}
	}
}

/// Merges a `producer` of SignalProducers down into a single producer, biased toward the producers
/// added earlier. Returns a SignalProducer that will forward events from the inner producers as they arrive.
private func merge<T, E>(producer: SignalProducer<SignalProducer<T, E>, E>) -> SignalProducer<T, E> {
	return SignalProducer<T, E> { relayObserver, disposable in
		let inFlight = Atomic(1)
		let decrementInFlight: () -> () = {
			let orig = inFlight.modify { $0 - 1 }
			if orig == 1 {
				sendCompleted(relayObserver)
			}
		}

		producer.startWithSignal { signal, signalDisposable in
			disposable.addDisposable(signalDisposable)

			signal.observe(next: { producer in
				producer.startWithSignal { innerSignal, innerDisposable in
					inFlight.modify { $0 + 1 }

					let handle = disposable.addDisposable(innerDisposable)

					innerSignal.observe { event in
						switch event {
						case .Completed, .Interrupted:
							if event.isTerminating {
								handle.remove()
							}

							decrementInFlight()

						default:
							relayObserver(event)
						}
					}
				}
			}, error: { error in
				sendError(relayObserver, error)
			}, completed: {
				decrementInFlight()
			}, interrupted: {
				sendInterrupted(relayObserver)
			})
		}
	}
}

/// Returns a producer that forwards values from the latest producer sent on
/// `producer`, ignoring values sent on previous inner producers.
///
/// An error sent on `producer` or the latest inner producer will be sent on the
/// returned producer.
///
/// The returned producer completes when `producer` and the latest inner
/// producer have both completed.
private func switchToLatest<T, E>(producer: SignalProducer<SignalProducer<T, E>, E>) -> SignalProducer<T, E> {
	return SignalProducer<T, E> { sink, disposable in
		let latestInnerDisposable = SerialDisposable()
		disposable.addDisposable(latestInnerDisposable)

		let state = Atomic(LatestState<T, E>())

		producer.startWithSignal { signal, signalDisposable in
			disposable.addDisposable(signalDisposable)

			signal.observe(next: { innerProducer in
				innerProducer.startWithSignal { innerSignal, innerDisposable in
					state.modify { (var state) in
						// When we replace the disposable below, this prevents the
						// generated Interrupted event from doing any work.
						state.replacingInnerSignal = true
						return state
					}

					latestInnerDisposable.innerDisposable = innerDisposable

					state.modify { (var state) in
						state.replacingInnerSignal = false
						state.innerSignalComplete = false
						return state
					}

					innerSignal.observe { event in
						switch event {
						case .Interrupted:
							// If interruption occurred as a result of a new signal
							// arriving, we don't want to notify our observer.
							let original = state.modify { (var state) in
								if !state.replacingInnerSignal {
									state.innerSignalComplete = true
								}

								return state
							}

							if !original.replacingInnerSignal && original.outerSignalComplete {
								sendCompleted(sink)
							}

						case .Completed:
							let original = state.modify { (var state) in
								state.innerSignalComplete = true
								return state
							}

							if original.outerSignalComplete {
								sendCompleted(sink)
							}

						default:
							sink(event)
						}
					}
				}
			}, error: { error in
				sendError(sink, error)
			}, completed: {
				let original = state.modify { (var state) in
					state.outerSignalComplete = true
					return state
				}

				if original.innerSignalComplete {
					sendCompleted(sink)
				}
			}, interrupted: {
				sendInterrupted(sink)
			})
		}
	}
}

private struct LatestState<T, E: ErrorType> {
	var outerSignalComplete: Bool = false
	var innerSignalComplete: Bool = true

	var replacingInnerSignal: Bool = false
}
