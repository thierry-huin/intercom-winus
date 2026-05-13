import type { CompanionVariableDefinition } from '@companion-module/base'

export function buildVariables(): CompanionVariableDefinition[] {
	return [
		{ variableId: 'connection_status', name: 'Connection status' },
		{ variableId: 'online_count', name: 'Online user count' },
		{ variableId: 'producing', name: 'Producing audio (yes/no)' },
		{ variableId: 'talking_count', name: 'Active PTT session count' },
		{ variableId: 'mic_muted', name: 'Mic muted (yes/no)' },
	]
}
