import { EventEmitter } from 'events'
import https from 'https'
import fetch from 'node-fetch'
import WebSocket from 'ws'

export interface SessionOptions {
	host: string
	port: number
	username: string
	password: string
	allowSelfSignedCert: boolean
}

export interface Target {
	id: number
	type: 'user' | 'group'
	displayName: string
	online: boolean
}

type WsHandler = (msg: any) => void

/**
 * WebSocket-only session for PTT control. No audio — audio comes from
 * the Flutter/web app on the same machine. This module only sends PTT
 * start/stop commands and tracks online users.
 */
export class IntercomSession extends EventEmitter {
	private ws: WebSocket | null = null
	private token: string | null = null
	private httpsAgent: https.Agent
	private requestSeq = 0
	private pending = new Map<number, { resolve: (msg: any) => void; reject: (err: Error) => void; timer: NodeJS.Timeout }>()
	private handlers = new Map<string, WsHandler>()
	private targets: Target[] = []
	private onlineUserIds = new Set<number>()
	private reconnectTimer: NodeJS.Timeout | null = null
	private disposed = false

	constructor(private readonly opts: SessionOptions) {
		super()
		this.httpsAgent = new https.Agent({ rejectUnauthorized: !opts.allowSelfSignedCert })
		this.registerHandlers()
	}

	async connect(): Promise<void> {
		await this.login()
		await this.openWs()
		await this.loadTargets()
		this.emit('ready')
	}

	dispose(): void {
		this.disposed = true
		if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
		try { this.ws?.close() } catch (_) {}
		this.ws = null
	}

	isTargetOnline(type: 'user' | 'group', id: number): boolean {
		if (type === 'group') return true
		return this.onlineUserIds.has(id)
	}

	pttStart(type: 'user' | 'group', id: number): void {
		this.send({ type: 'ptt_start', targetType: type, targetId: id })
	}

	pttStop(type: 'user' | 'group', id: number): void {
		this.send({ type: 'ptt_stop', targetType: type, targetId: id })
	}

	ringUser(targetUserId: number): void {
		this.send({ type: 'ring_user', targetUserId })
	}

	async pauseProducer(): Promise<void> {}
	async resumeProducer(): Promise<void> {}

	// ── REST ──
	private baseUrl(): string { return `https://${this.opts.host}:${this.opts.port}` }
	private wsUrl(): string { return `wss://${this.opts.host}:${this.opts.port}/ws` }

	private async login(): Promise<void> {
		const res = await fetch(`${this.baseUrl()}/api/auth/login`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ username: this.opts.username, password: this.opts.password }),
			agent: this.httpsAgent as any,
		})
		if (!res.ok) {
			const text = await res.text().catch(() => '')
			throw new Error(`Login failed (${res.status}): ${text}`)
		}
		const data = (await res.json()) as { token: string }
		this.token = data.token
	}

	private async loadTargets(): Promise<void> {
		if (!this.token) return
		const res = await fetch(`${this.baseUrl()}/api/rooms/my-targets`, {
			headers: { Authorization: `Bearer ${this.token}` },
			agent: this.httpsAgent as any,
		})
		if (!res.ok) return
		const data = (await res.json()) as {
			users: Array<{ id: number; display_name: string }>
			groups: Array<{ id: number; name: string }>
		}
		this.targets = [
			...data.users.map((u: any) => ({ id: u.id, type: 'user' as const, displayName: u.display_name, online: false })),
			...data.groups.map((g: any) => ({ id: g.id, type: 'group' as const, displayName: g.name, online: true })),
		]
		this.emit('targets', this.targets)
	}

	// ── WebSocket ──
	private openWs(): Promise<void> {
		return new Promise((resolve, reject) => {
			const ws = new WebSocket(this.wsUrl(), { rejectUnauthorized: !this.opts.allowSelfSignedCert })
			this.ws = ws
			ws.once('open', () => ws.send(JSON.stringify({ type: 'auth', token: this.token })))
			ws.on('message', (raw: any) => this.onMessage(raw.toString()))
			ws.on('close', () => this.onWsClose())
			ws.on('error', (err: Error) => this.emit('error', err))
			this.once('auth_ok', () => resolve())
			setTimeout(() => reject(new Error('auth timeout')), 10_000).unref()
		})
	}

	private onWsClose(): void {
		this.ws = null
		if (this.disposed) return
		this.emit('disconnected')
		this.reconnectTimer = setTimeout(() => {
			if (!this.disposed) this.connect().catch((err) => this.emit('error', err))
		}, 3_000)
	}

	private send(msg: any): void {
		if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg))
	}

	private request(type: string, data: Record<string, any> = {}): Promise<any> {
		const requestId = ++this.requestSeq
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => { this.pending.delete(requestId); reject(new Error(`WS "${type}" timeout`)) }, 10_000)
			this.pending.set(requestId, { resolve, reject, timer })
			this.send({ type, requestId, ...data })
		})
	}

	private onMessage(raw: string): void {
		let msg: any
		try { msg = JSON.parse(raw) } catch { return }
		if (msg.requestId && this.pending.has(msg.requestId)) {
			const p = this.pending.get(msg.requestId)!
			this.pending.delete(msg.requestId)
			clearTimeout(p.timer)
			p.resolve(msg)
			return
		}
		const h = this.handlers.get(msg.type)
		if (h) h(msg)
	}

	private registerHandlers(): void {
		this.handlers.set('auth_ok', () => this.emit('auth_ok'))
		this.handlers.set('online_users', (msg: any) => {
			this.onlineUserIds = new Set<number>((msg.userIds || []).map((x: any) => Number(x)))
			this.emit('online', this.onlineUserIds)
		})
		this.handlers.set('kicked', (msg: any) => this.emit('kicked', msg.reason))
		this.handlers.set('incoming_audio', (msg: any) => {
			this.emit('incoming_audio', {
				fromUserId: Number(msg.fromUserId),
				fromDisplayName: msg.fromDisplayName || '',
				talking: msg.talking === true,
			})
		})
	}
}
