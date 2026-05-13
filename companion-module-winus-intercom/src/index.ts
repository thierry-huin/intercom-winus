import {
	InstanceBase,
	InstanceStatus,
	runEntrypoint,
	type DropdownChoice,
	type SomeCompanionConfigField,
} from '@companion-module/base'
import { DEFAULT_CONFIG, getConfigFields, type WinusIntercomConfig } from './config'
import { IntercomSession, type Target } from './session'
import { PttGesture } from './ptt-gesture'
import { buildActions } from './actions'
import { buildFeedbacks } from './feedbacks'
import { buildVariables } from './variables'
import { buildPresets } from './presets'

/** Canonical target key used everywhere: "user:3", "group:1". */
type TargetKey = string

function parseTargetKey(key: TargetKey): { type: 'user' | 'group'; id: number } | null {
	const [t, rawId] = key.split(':')
	const id = Number(rawId)
	if ((t !== 'user' && t !== 'group') || !Number.isFinite(id)) return null
	return { type: t, id }
}

export class WinusIntercomInstance extends InstanceBase<WinusIntercomConfig> {
	private session: IntercomSession | null = null
	private gestures = new Map<TargetKey, PttGesture>()
	private talking = new Set<TargetKey>()
	private latched = new Set<TargetKey>()
	private targets: Target[] = []
	private micMuted = false
	private volumes = new Map<TargetKey, number>() // 0-100, default 100

	async init(config: WinusIntercomConfig): Promise<void> {
		this.updateStatus(InstanceStatus.Connecting)
		await this.applyConfig(config)
	}

	async configUpdated(config: WinusIntercomConfig): Promise<void> {
		await this.applyConfig(config)
	}

	async destroy(): Promise<void> {
		this.tearDownSession()
	}

	getConfigFields(): SomeCompanionConfigField[] {
		return getConfigFields()
	}

	// ------------------------------------------------------------------
	// Session lifecycle
	// ------------------------------------------------------------------

	private async applyConfig(config: WinusIntercomConfig): Promise<void> {
		this.tearDownSession()
		// Merge with defaults to preserve timings when user clears a field.
		const cfg: WinusIntercomConfig = { ...DEFAULT_CONFIG, ...config }
		if (!cfg.username || !cfg.password || !cfg.host) {
			this.updateStatus(InstanceStatus.BadConfig, 'Missing host / username / password')
			return
		}
		const s = new IntercomSession({
			host: cfg.host,
			port: cfg.port,
			username: cfg.username,
			password: cfg.password,
			allowSelfSignedCert: cfg.allowSelfSignedCert,
			ffmpegInputArgs: cfg.ffmpegInputArgs,
			enableReceive: cfg.enableReceive,
		})
		this.session = s
		s.on('ready', () => {
			this.updateStatus(InstanceStatus.Ok)
			this.setVariableValues({ connection_status: 'ok', producing: 'yes' })
		})
		s.on('disconnected', () => {
			this.updateStatus(InstanceStatus.Disconnected)
			this.setVariableValues({ connection_status: 'disconnected', producing: 'no' })
		})
		s.on('error', (err: Error) => {
			this.log('error', `Session error: ${err.message}`)
			this.updateStatus(InstanceStatus.UnknownError, err.message)
		})
		s.on('kicked', (reason: string) => {
			this.log('warn', `Kicked by server: ${reason}`)
		})
		s.on('targets', (targets: Target[]) => {
			this.targets = targets
			this.refreshDefinitions()
		})
		s.on('online', (ids: Set<number>) => {
			this.setVariableValues({ online_count: String(ids.size) })
			this.checkFeedbacks('target_online')
		})

		this.setActionDefinitions(buildActions(this))
		this.setFeedbackDefinitions(buildFeedbacks(this))
		this.setVariableDefinitions(buildVariables())
		this.setPresetDefinitions(buildPresets(this))
		this.setVariableValues({
			connection_status: 'connecting',
			producing: 'no',
			online_count: '0',
			talking_count: '0',
			mic_muted: 'no',
		})

		try {
			await s.connect()
		} catch (err) {
			const msg = (err as Error).message
			this.log('error', `Connect failed: ${msg}`)
			this.updateStatus(InstanceStatus.ConnectionFailure, msg)
		}
	}

	private tearDownSession(): void {
		if (this.session) {
			try { this.session.dispose() } catch (_) {}
		}
		this.session = null
		for (const g of this.gestures.values()) g.reset()
		this.gestures.clear()
		this.talking.clear()
	}

	private refreshDefinitions(): void {
		// Rebuild action/feedback choices whenever the target list changes.
		this.setActionDefinitions(buildActions(this))
		this.setFeedbackDefinitions(buildFeedbacks(this))
		this.setPresetDefinitions(buildPresets(this))
		this.checkFeedbacks('target_online', 'target_latched', 'target_talking', 'mic_muted')
	}

	// ------------------------------------------------------------------
	// Helpers exposed to actions.ts / feedbacks.ts
	// ------------------------------------------------------------------

	getTargetChoices(): DropdownChoice[] {
		return this.targets.map((t) => ({
			id: `${t.type}:${t.id}`,
			label: `${t.type === 'group' ? '[G] ' : ''}${t.displayName} (${t.id})`,
		}))
	}

	isTargetOnline(targetKey: TargetKey): boolean {
		const t = parseTargetKey(targetKey)
		if (!t || !this.session) return false
		return this.session.isTargetOnline(t.type, t.id)
	}

	isTalkingTo(targetKey: TargetKey): boolean {
		return this.talking.has(targetKey)
	}

	isLatched(targetKey: TargetKey): boolean {
		return this.latched.has(targetKey)
	}

	isMicMuted(): boolean {
		return this.micMuted
	}

	getVolume(targetKey: TargetKey): number {
		return this.volumes.get(targetKey) ?? 100
	}

	getAllTargetKeys(): TargetKey[] {
		return this.targets.map((t) => `${t.type}:${t.id}`)
	}

	// ------------------------------------------------------------------
	// Button event handlers (called from action callbacks)
	// ------------------------------------------------------------------

	handlePttPress(targetKey: TargetKey): void {
		const t = parseTargetKey(targetKey)
		if (!t || !this.session) return
		if (!this.session.isTargetOnline(t.type, t.id)) {
			this.log('info', `ptt_press ignored: ${targetKey} is offline`)
			return
		}
		this.getGesture(targetKey, t).press()
	}

	handlePttRelease(targetKey: TargetKey): void {
		const t = parseTargetKey(targetKey)
		if (!t || !this.session) return
		this.getGesture(targetKey, t).release()
	}

	handlePttCancel(targetKey: TargetKey): void {
		const t = parseTargetKey(targetKey)
		if (!t) return
		this.getGesture(targetKey, t).reset()
		this.latched.delete(targetKey)
		this.checkFeedbacks('target_latched')
	}

	/** Explicit latch toggle — no gesture detection, just on/off. */
	handlePttLatchToggle(targetKey: TargetKey): void {
		const t = parseTargetKey(targetKey)
		if (!t || !this.session) return
		if (this.latched.has(targetKey)) {
			// Unlatch
			this.latched.delete(targetKey)
			this.session.pttStop(t.type, t.id)
			this.talking.delete(targetKey)
		} else {
			// Latch on
			this.latched.add(targetKey)
			this.session.pttStart(t.type, t.id)
			this.talking.add(targetKey)
		}
		this.setVariableValues({ talking_count: String(this.talking.size) })
		this.checkFeedbacks('target_talking', 'target_latched')
	}

	/** Mic mute toggle — pauses/resumes the mediasoup producer. */
	handleMicMuteToggle(): void {
		if (!this.session) return
		this.micMuted = !this.micMuted
		if (this.micMuted) {
			this.session.pauseProducer()
		} else {
			this.session.resumeProducer()
		}
		this.setVariableValues({ mic_muted: this.micMuted ? 'yes' : 'no' })
		this.checkFeedbacks('mic_muted')
	}

	/** Talk All — momentary PTT to every target. */
	handleTalkAllPress(): void {
		if (!this.session) return
		for (const key of this.getAllTargetKeys()) {
			const t = parseTargetKey(key)
			if (!t) continue
			this.session.pttStart(t.type, t.id)
			this.talking.add(key)
		}
		this.setVariableValues({ talking_count: String(this.talking.size) })
		this.checkFeedbacks('target_talking')
	}

	handleTalkAllRelease(): void {
		if (!this.session) return
		for (const key of this.getAllTargetKeys()) {
			// Don't release individually latched targets
			if (this.latched.has(key)) continue
			const t = parseTargetKey(key)
			if (!t) continue
			this.session.pttStop(t.type, t.id)
			this.talking.delete(key)
		}
		this.setVariableValues({ talking_count: String(this.talking.size) })
		this.checkFeedbacks('target_talking')
	}

	/** Volume adjust — ±10%, clamped 0-100. */
	adjustVolume(targetKey: TargetKey, delta: number): void {
		const cur = this.volumes.get(targetKey) ?? 100
		const next = Math.max(0, Math.min(100, cur + delta))
		this.volumes.set(targetKey, next)
		this.checkFeedbacks('target_talking') // refresh button text
	}

	private getGesture(key: TargetKey, t: { type: 'user' | 'group'; id: number }): PttGesture {
		let g = this.gestures.get(key)
		if (g) return g
		const cfg = DEFAULT_CONFIG // timings picked up at construction time
		g = new PttGesture({
			holdTimeoutMs: cfg.holdTimeoutMs,
			doubleTapWindowMs: cfg.doubleTapWindowMs,
			onStart: () => {
				if (!this.session) return
				this.session.pttStart(t.type, t.id)
				this.talking.add(key)
				this.setVariableValues({ talking_count: String(this.talking.size) })
				this.checkFeedbacks('target_talking')
			},
			onStop: () => {
				if (this.session) this.session.pttStop(t.type, t.id)
				this.talking.delete(key)
				this.setVariableValues({ talking_count: String(this.talking.size) })
				this.checkFeedbacks('target_talking')
			},
			onLatchChanged: () => this.checkFeedbacks('target_latched'),
		})
		this.gestures.set(key, g)
		return g
	}
}

runEntrypoint(WinusIntercomInstance, [])
