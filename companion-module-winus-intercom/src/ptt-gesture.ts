/**
 * Per-target PTT gesture state machine.
 *
 *  - Sustained press (>= holdTimeoutMs while holding): momentary talk
 *    (ptt_start on hold, ptt_stop on release).
 *  - Two quick taps (each press < holdTimeoutMs, gap < doubleTapWindowMs):
 *    toggle latch (second tap enters latched, a later double-tap leaves it).
 *  - Single short tap: no-op (matches the desired UX).
 */
export interface GestureOptions {
	holdTimeoutMs: number
	doubleTapWindowMs: number
	onStart: () => void
	onStop: () => void
	onLatchChanged?: (latched: boolean) => void
}

enum State {
	Idle = 'idle',
	WaitingForHold = 'waiting-for-hold',
	Holding = 'holding',
	AwaitingSecondTap = 'awaiting-second-tap',
	Latched = 'latched',
	AwaitingSecondTapOffFromLatch = 'awaiting-second-tap-off-from-latch',
}

export class PttGesture {
	private state: State = State.Idle
	private holdTimer: NodeJS.Timeout | null = null
	private doubleTapTimer: NodeJS.Timeout | null = null

	constructor(private readonly opts: GestureOptions) {}

	get isLatched(): boolean {
		return this.state === State.Latched
	}

	press(): void {
		switch (this.state) {
			case State.AwaitingSecondTap: {
				// Second tap of a double-tap while idle → enter latched.
				this.clearDoubleTapTimer()
				this.clearHoldTimer()
				this.state = State.Latched
				this.opts.onLatchChanged?.(true)
				this.opts.onStart()
				return
			}
			case State.AwaitingSecondTapOffFromLatch: {
				// Second tap while latched → leave latched.
				this.clearDoubleTapTimer()
				this.clearHoldTimer()
				this.state = State.Idle
				this.opts.onLatchChanged?.(false)
				this.opts.onStop()
				return
			}
			case State.Latched: {
				// First tap of a potential latch-off pair.
				this.clearHoldTimer()
				this.state = State.AwaitingSecondTapOffFromLatch
				this.startDoubleTapWindow()
				return
			}
			case State.Idle:
			default: {
				// First tap of a potential sequence. Arm the hold timer.
				this.clearHoldTimer()
				this.state = State.WaitingForHold
				this.holdTimer = setTimeout(() => {
					if (this.state === State.WaitingForHold) {
						this.state = State.Holding
						this.opts.onStart()
					}
				}, this.opts.holdTimeoutMs)
			}
		}
	}

	release(): void {
		switch (this.state) {
			case State.WaitingForHold: {
				// Short tap: wait to see if a second tap follows.
				this.clearHoldTimer()
				this.state = State.AwaitingSecondTap
				this.startDoubleTapWindow()
				break
			}
			case State.Holding: {
				this.state = State.Idle
				this.opts.onStop()
				break
			}
			default:
				// Latched / AwaitingSecondTap* states ignore release.
				break
		}
	}

	/** Force-clear the gesture state (e.g. on disconnect). */
	reset(): void {
		this.clearHoldTimer()
		this.clearDoubleTapTimer()
		if (this.state === State.Latched || this.state === State.Holding) {
			this.opts.onStop()
			this.opts.onLatchChanged?.(false)
		}
		this.state = State.Idle
	}

	private startDoubleTapWindow(): void {
		this.clearDoubleTapTimer()
		this.doubleTapTimer = setTimeout(() => {
			if (this.state === State.AwaitingSecondTap) {
				// Single short tap → no-op, back to idle.
				this.state = State.Idle
			} else if (this.state === State.AwaitingSecondTapOffFromLatch) {
				// Single press while latched (no second tap) → stay latched.
				this.state = State.Latched
			}
		}, this.opts.doubleTapWindowMs)
	}

	private clearHoldTimer(): void {
		if (this.holdTimer) {
			clearTimeout(this.holdTimer)
			this.holdTimer = null
		}
	}

	private clearDoubleTapTimer(): void {
		if (this.doubleTapTimer) {
			clearTimeout(this.doubleTapTimer)
			this.doubleTapTimer = null
		}
	}
}
