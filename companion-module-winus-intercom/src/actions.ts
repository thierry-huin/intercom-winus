import type { CompanionActionDefinitions, DropdownChoice } from '@companion-module/base'
import type { WinusIntercomInstance } from './index'

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
		mic_mute_toggle: {
			name: 'Mic: mute/unmute toggle',
			description: 'Pauses or resumes the audio producer. While muted, no audio is sent to any target.',
			options: [],
			callback: async () => {
				self.handleMicMuteToggle()
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
		volume_up: {
			name: 'Volume: +10%',
			description: 'Increase target volume by 10% (visual, stored in module).',
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
				self.adjustVolume(target, 10)
			},
		},
		volume_down: {
			name: 'Volume: -10%',
			description: 'Decrease target volume by 10% (visual, stored in module).',
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
				self.adjustVolume(target, -10)
			},
		},
	}
}
