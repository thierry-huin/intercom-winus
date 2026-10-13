import type { CompanionActionDefinitions, DropdownChoice } from '@companion-module/base'
import type { WinusIntercomInstance } from './index.js'

export function buildActions(self: WinusIntercomInstance): CompanionActionDefinitions {
	const choices: DropdownChoice[] = self.getTargetChoices()
	const defaultId = choices[0]?.id ?? ''

	return {
		ptt_press: {
			name: 'PTT: press (assign to Streamdeck press)',
			description:
				'Call this from the button press event. Combined with ptt_release it implements the Latch (double tap) / Momentary (hold) gesture.',
			options: [
				{
					id: 'target',
					type: 'dropdown',
					label: 'Target',
					choices,
					default: defaultId,
					allowCustom: true,
				},
			],
			callback: async (event) => {
				const target = String(event.options.target ?? '')
				self.handlePttPress(target)
			},
		},
		ptt_release: {
			name: 'PTT: release (assign to Streamdeck release)',
			description:
				'Call this from the button release event. The gesture machine decides whether a press was momentary or part of a double-tap latch.',
			options: [
				{
					id: 'target',
					type: 'dropdown',
					label: 'Target',
					choices,
					default: defaultId,
					allowCustom: true,
				},
			],
			callback: async (event) => {
				const target = String(event.options.target ?? '')
				self.handlePttRelease(target)
			},
		},
		ptt_cancel_latch: {
			name: 'PTT: cancel latch (emergency off)',
			description: 'Immediately send ptt_stop and drop the latched state for a target.',
			options: [
				{
					id: 'target',
					type: 'dropdown',
					label: 'Target',
					choices,
					default: defaultId,
					allowCustom: true,
				},
			],
			callback: async (event) => {
				const target = String(event.options.target ?? '')
				self.handlePttCancel(target)
			},
		},
		ptt_latch_toggle: {
			name: 'PTT: latch toggle (permanent talk on/off)',
			description: 'Toggle permanent talk to a target. Press once to latch on, press again to stop.',
			options: [
				{
					id: 'target',
					type: 'dropdown',
					label: 'Target',
					choices,
					default: defaultId,
					allowCustom: true,
				},
			],
			callback: async (event) => {
				const target = String(event.options.target ?? '')
				self.handlePttLatchToggle(target)
			},
		},
		mute_all_toggle: {
			name: 'Mute All: pause/resume all active PTTs',
			description: 'First press stops all active PTTs. Second press restores them. Latch state is preserved.',
			options: [],
			callback: async () => {
				self.handleMuteAllToggle()
			},
		},
		talk_all_press: {
			name: 'Talk All: press (momentary, assign to key down)',
			description: 'Start PTT to ALL targets simultaneously. Pair with talk_all_release on key up.',
			options: [],
			callback: async () => {
				self.handleTalkAllPress()
			},
		},
		talk_all_release: {
			name: 'Talk All: release (assign to key up)',
			description: 'Stop PTT on all non-latched targets.',
			options: [],
			callback: async () => {
				self.handleTalkAllRelease()
			},
		},
		ring_user: {
			name: 'Ring: send alert to a user',
			description: 'Ring a user to get their attention. Triggers a ringtone + vibration on their device.',
			options: [
				{
					id: 'target',
					type: 'dropdown',
					label: 'Target (user only)',
					choices: choices.filter(c => String(c.id).startsWith('user:')),
					default: defaultId,
					allowCustom: true,
				},
			],
			callback: async (event) => {
				const target = String(event.options.target ?? '')
				self.handleRingUser(target)
			},
		},
	}
}
