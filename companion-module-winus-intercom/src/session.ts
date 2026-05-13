import { EventEmitter } from 'events'
import { spawn, ChildProcess } from 'child_process'
import https from 'https'
import fetch from 'node-fetch'
import WebSocket from 'ws'
import { Device } from 'mediasoup-client'
import type { Transport, Producer, Consumer } from 'mediasoup-client/lib/types'
// @roamhq/wrtc is a CommonJS module; we pull the parts we need dynamically
// because its types don't ship properly as ESM.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const wrtc = require('@roamhq/wrtc') as {
	RTCPeerConnection: typeof RTCPeerConnection
	MediaStream: typeof MediaStream
	nonstandard: {
		RTCAudioSource: new () => {
			createTrack(): MediaStreamTrack
			onData(data: {
				samples: Int16Array
				sampleRate: number
				bitsPerSample: number
				channelCount: number
				numberOfFrames: number
			}): void
		}
	}
}

// Make the wrtc globals visible to mediasoup-client which expects a browser.
;(globalThis as any).RTCPeerConnection = wrtc.RTCPeerConnection
;(globalThis as any).MediaStream = wrtc.MediaStream

export interface SessionOptions {
	host: string
	port: number
	username: string
	password: string
	allowSelfSignedCert: boolean
	ffmpegInputArgs: string
	enableReceive: boolean
}

export interface Target {
	id: number
	type: 'user' | 'group'
	displayName: string
	online: boolean
}

interface PendingRequest {
	resolve: (msg: any) => void
	reject: (err: Error) => void
	timer: NodeJS.Timeout
}

type WsHandler = (msg: any) => void

const SAMPLE_RATE = 48_000
const CHANNELS = 1
const FRAME_MS = 10
const FRAME_SAMPLES = (SAMPLE_RATE * FRAME_MS) / 1000 // 480 samples/frame at 48k/10ms

/**
 * Encapsulates all network + audio plumbing so the Companion instance only
 * deals with high-level ptt/ring events.
 */
export class IntercomSession extends EventEmitter {
	private ws: WebSocket | null = null
	private token: string | null = null
	private httpsAgent: https.Agent
	private device: Device | null = null
	private sendTransport: Transport | null = null
	private recvTransport: Transport | null = null
	private producer: Producer | null = null
	private consumers = new Map<string, Consumer>()
	private audioSource: InstanceType<typeof wrtc.nonstandard.RTCAudioSource> | null = null
	private audioTrack: MediaStreamTrack | null = null
	private ffmpeg: ChildProcess | null = null
	private audioBuffer = Buffer.alloc(0)
	private requestSeq = 0
	private pending = new Map<number, PendingRequest>()
	private handlers = new Map<string, WsHandler>()

	private targets: Target[] = []
	private onlineUserIds = new Set<number>()

	private reconnectTimer: NodeJS.Timeout | null = null
	private disposed = false

	constructor(private readonly opts: SessionOptions) {
		super()
		this.httpsAgent = new https.Agent({
			rejectUnauthorized: !opts.allowSelfSignedCert,
		})
		this.registerHandlers()
	}

	// ------------------------------------------------------------------
	// Public API
	// ------------------------------------------------------------------

	async connect(): Promise<void> {
		await this.login()
		await this.openWs()
		await this.setupMediasoup()
		await this.loadTargets()
		this.emit('ready')
	}

	dispose(): void {
		this.disposed = true
		if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
		try {
			this.stopAudioCapture()
		} catch (_) {}
		try {
			this.producer?.close()
		} catch (_) {}
		for (const c of this.consumers.values()) {
			try { c.close() } catch (_) {}
		}
		this.consumers.clear()
		try { this.sendTransport?.close() } catch (_) {}
		try { this.recvTransport?.close() } catch (_) {}
		try { this.ws?.close() } catch (_) {}
		this.ws = null
	}

	getTargets(): Target[] {
		return this.targets.map((t) => ({ ...t, online: t.type === 'group' ? true : this.onlineUserIds.has(t.id) }))
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

	/** Pause the mediasoup producer (server stops forwarding our audio). */
	async pauseProducer(): Promise<void> {
		if (this.producer && !this.producer.paused) {
			this.producer.pause()
			// Notify server
			this.send({ type: 'pauseProducer', producerId: this.producer.id })
		}
	}

	/** Resume the mediasoup producer. */
	async resumeProducer(): Promise<void> {
		if (this.producer && this.producer.paused) {
			this.producer.resume()
			this.send({ type: 'resumeProducer', producerId: this.producer.id })
		}
	}

	// ------------------------------------------------------------------
	// REST login
	// ------------------------------------------------------------------

	private baseUrl(): string {
		return `https://${this.opts.host}:${this.opts.port}`
	}

	private wsUrl(): string {
		return `wss://${this.opts.host}:${this.opts.port}/ws`
	}

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
			...data.users.map((u) => ({ id: u.id, type: 'user' as const, displayName: u.display_name, online: false })),
			...data.groups.map((g) => ({ id: g.id, type: 'group' as const, displayName: g.name, online: true })),
		]
		this.emit('targets', this.targets)
	}

	// ------------------------------------------------------------------
	// WebSocket
	// ------------------------------------------------------------------

	private openWs(): Promise<void> {
		return new Promise((resolve, reject) => {
			const ws = new WebSocket(this.wsUrl(), {
				rejectUnauthorized: !this.opts.allowSelfSignedCert,
			})
			this.ws = ws
			ws.once('open', () => {
				ws.send(JSON.stringify({ type: 'auth', token: this.token }))
			})
			ws.on('message', (raw) => this.onMessage(raw.toString()))
			ws.on('close', () => this.onWsClose())
			ws.on('error', (err) => this.emit('error', err))
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
		if (this.ws && this.ws.readyState === WebSocket.OPEN) {
			this.ws.send(JSON.stringify(msg))
		}
	}

	private request(type: string, data: Record<string, any> = {}): Promise<any> {
		const requestId = ++this.requestSeq
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pending.delete(requestId)
				reject(new Error(`WS request "${type}" timeout`))
			}, 10_000)
			this.pending.set(requestId, { resolve, reject, timer })
			this.send({ type, requestId, ...data })
		})
	}

	private onMessage(raw: string): void {
		let msg: any
		try {
			msg = JSON.parse(raw)
		} catch {
			return
		}
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
		this.handlers.set('online_users', (msg) => {
			this.onlineUserIds = new Set<number>((msg.userIds || []).map((x: any) => Number(x)))
			this.emit('online', this.onlineUserIds)
		})
		this.handlers.set('kicked', (msg) => this.emit('kicked', msg.reason))
		this.handlers.set('newConsumer', (msg) => this.onNewConsumer(msg))
		this.handlers.set('transportClosed', () => {
			this.emit('error', new Error(`mediasoup transport closed`))
		})
	}

	// ------------------------------------------------------------------
	// mediasoup-client setup
	// ------------------------------------------------------------------

	private async setupMediasoup(): Promise<void> {
		const caps = await this.request('getRouterRtpCapabilities')
		this.device = new Device()
		await this.device.load({ routerRtpCapabilities: caps.rtpCapabilities })
		await this.request('setRtpCapabilities', { rtpCapabilities: this.device.rtpCapabilities })
		await this.createSendTransport()
		if (this.opts.enableReceive) {
			await this.createRecvTransport()
		}
		await this.startAudioCapture()
		await this.produceAudio()
	}

	private async createSendTransport(): Promise<void> {
		const data = await this.request('createWebRtcTransport', { direction: 'send' })
		this.sendTransport = this.device!.createSendTransport({
			id: data.id,
			iceParameters: data.iceParameters,
			iceCandidates: data.iceCandidates,
			dtlsParameters: data.dtlsParameters,
			iceServers: data.iceServers,
		})
		this.sendTransport.on('connect', ({ dtlsParameters }, callback, errback) => {
			this.request('connectTransport', { transportId: this.sendTransport!.id, dtlsParameters })
				.then(() => callback())
				.catch(errback)
		})
		this.sendTransport.on('produce', ({ kind, rtpParameters }, callback, errback) => {
			this.request('produce', { transportId: this.sendTransport!.id, kind, rtpParameters })
				.then((resp: any) => callback({ id: resp.id }))
				.catch(errback)
		})
	}

	private async createRecvTransport(): Promise<void> {
		const data = await this.request('createWebRtcTransport', { direction: 'recv' })
		this.recvTransport = this.device!.createRecvTransport({
			id: data.id,
			iceParameters: data.iceParameters,
			iceCandidates: data.iceCandidates,
			dtlsParameters: data.dtlsParameters,
			iceServers: data.iceServers,
		})
		this.recvTransport.on('connect', ({ dtlsParameters }, callback, errback) => {
			this.request('connectTransport', { transportId: this.recvTransport!.id, dtlsParameters })
				.then(() => callback())
				.catch(errback)
		})
	}

	private async onNewConsumer(msg: any): Promise<void> {
		if (!this.recvTransport) return
		try {
			const consumer = await this.recvTransport.consume({
				id: msg.id,
				producerId: msg.producerId,
				kind: msg.kind,
				rtpParameters: msg.rtpParameters,
			})
			this.consumers.set(consumer.id, consumer)
			this.send({ type: 'resumeConsumer', consumerId: consumer.id })
			this.emit('consumer', consumer)
		} catch (err) {
			this.emit('error', err as Error)
		}
	}

	// ------------------------------------------------------------------
	// Audio capture via ffmpeg (PCM s16le 48 kHz mono → RTCAudioSource)
	// ------------------------------------------------------------------

	private async startAudioCapture(): Promise<void> {
		const args = [
			...this.opts.ffmpegInputArgs.split(/\s+/).filter(Boolean),
			'-ar', String(SAMPLE_RATE),
			'-ac', String(CHANNELS),
			'-f', 's16le',
			'-acodec', 'pcm_s16le',
			'-loglevel', 'error',
			'pipe:1',
		]
		this.ffmpeg = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] })
		this.ffmpeg.stderr?.on('data', (d) => this.emit('ffmpeg-stderr', d.toString()))
		this.ffmpeg.on('exit', (code, signal) => {
			this.emit('ffmpeg-exit', { code, signal })
		})
		const source = new wrtc.nonstandard.RTCAudioSource()
		this.audioSource = source
		this.audioTrack = source.createTrack()
		const bytesPerFrame = FRAME_SAMPLES * CHANNELS * 2
		this.audioBuffer = Buffer.alloc(0)
		this.ffmpeg.stdout?.on('data', (chunk: Buffer) => {
			this.audioBuffer = Buffer.concat([this.audioBuffer, chunk])
			while (this.audioBuffer.length >= bytesPerFrame) {
				const frame = this.audioBuffer.subarray(0, bytesPerFrame)
				this.audioBuffer = this.audioBuffer.subarray(bytesPerFrame)
				const samples = new Int16Array(frame.buffer, frame.byteOffset, frame.length / 2)
				source.onData({
					samples,
					sampleRate: SAMPLE_RATE,
					bitsPerSample: 16,
					channelCount: CHANNELS,
					numberOfFrames: FRAME_SAMPLES,
				})
			}
		})
	}

	private stopAudioCapture(): void {
		if (this.ffmpeg) {
			try { this.ffmpeg.kill('SIGINT') } catch (_) {}
			this.ffmpeg = null
		}
		this.audioSource = null
		this.audioTrack = null
	}

	private async produceAudio(): Promise<void> {
		if (!this.sendTransport || !this.audioTrack) return
		this.producer = await this.sendTransport.produce({
			track: this.audioTrack,
			codecOptions: { opusStereo: false, opusDtx: true },
		})
		this.emit('producing', this.producer.id)
	}
}
