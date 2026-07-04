export function buildVariables(): Record<string, { name: string }> {
	return {
		connection_status: { name: 'Connection status' },
		online_count: { name: 'Online user count' },
		producing: { name: 'Producing audio (yes/no)' },
		talking_count: { name: 'Active PTT session count' },
		mic_muted: { name: 'Mic muted (yes/no)' },
	}
}
