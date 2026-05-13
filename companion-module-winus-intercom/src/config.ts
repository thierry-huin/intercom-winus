import type { SomeCompanionConfigField } from '@companion-module/base'

export interface WinusIntercomConfig {
	host: string
	port: number
	username: string
	password: string
	allowSelfSignedCert: boolean
	holdTimeoutMs: number
	doubleTapWindowMs: number
	ffmpegInputArgs: string
	enableReceive: boolean
}

export const DEFAULT_CONFIG: WinusIntercomConfig = {
	host: 'huin.tv',
	port: 8443,
	username: '',
	password: '',
	allowSelfSignedCert: true,
	holdTimeoutMs: 250,
	doubleTapWindowMs: 500,
	ffmpegInputArgs: '-f pulse -i default',
	enableReceive: false,
}

export function getConfigFields(): SomeCompanionConfigField[] {
	return [
		{
			type: 'static-text',
			id: 'info',
			width: 12,
			label: 'Winus Intercom',
			value:
				'<p>Drives PTT against a Winus Intercom server. Create a dedicated user in the admin panel for this Streamdeck and grant it permissions to the targets you want to push. Audio is captured from the local PC microphone via ffmpeg.</p>',
		},
		{
			type: 'textinput',
			id: 'host',
			label: 'Server host',
			width: 8,
			default: DEFAULT_CONFIG.host,
			required: true,
		},
		{
			type: 'number',
			id: 'port',
			label: 'Server port (HTTPS/WSS)',
			width: 4,
			default: DEFAULT_CONFIG.port,
			min: 1,
			max: 65535,
		},
		{
			type: 'textinput',
			id: 'username',
			label: 'Username',
			width: 6,
			default: DEFAULT_CONFIG.username,
			required: true,
		},
		{
			type: 'textinput',
			id: 'password',
			label: 'Password',
			width: 6,
			default: DEFAULT_CONFIG.password,
			required: true,
		},
		{
			type: 'checkbox',
			id: 'allowSelfSignedCert',
			label: 'Accept self-signed certificate',
			width: 6,
			default: DEFAULT_CONFIG.allowSelfSignedCert,
		},
		{
			type: 'checkbox',
			id: 'enableReceive',
			label: 'Also receive audio (play on PC speakers)',
			width: 6,
			default: DEFAULT_CONFIG.enableReceive,
		},
		{
			type: 'number',
			id: 'holdTimeoutMs',
			label: 'Hold-to-talk threshold (ms)',
			width: 6,
			default: DEFAULT_CONFIG.holdTimeoutMs,
			min: 100,
			max: 1000,
		},
		{
			type: 'number',
			id: 'doubleTapWindowMs',
			label: 'Double-tap window (ms)',
			width: 6,
			default: DEFAULT_CONFIG.doubleTapWindowMs,
			min: 150,
			max: 1500,
		},
		{
			type: 'textinput',
			id: 'ffmpegInputArgs',
			label: 'ffmpeg input arguments (used to capture the PC microphone)',
			width: 12,
			default: DEFAULT_CONFIG.ffmpegInputArgs,
			tooltip:
				'Linux (PulseAudio): -f pulse -i default   ·   Linux (ALSA): -f alsa -i default   ·   macOS: -f avfoundation -i ":0"   ·   Windows: -f dshow -i audio="Microphone (...)"',
		},
	]
}
