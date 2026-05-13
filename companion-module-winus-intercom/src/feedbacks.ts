import type { CompanionFeedbackDefinitions, DropdownChoice } from '@companion-module/base'
import { combineRgb } from '@companion-module/base'
import type { WinusIntercomInstance } from './index'

export function buildFeedbacks(self: WinusIntercomInstance): CompanionFeedbackDefinitions {
	const choices: DropdownChoice[] = self.getTargetChoices()
	const defaultId = choices[0]?.id ?? ''

	return {
		target_talking: {
			name: 'Target: currently talking (latched or momentary)',
			type: 'boolean',
			defaultStyle: {
				bgcolor: combineRgb(200, 40, 40),
				color: combineRgb(255, 255, 255),
			},
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
			callback: (feedback) => {
				const target = String(feedback.options.target ?? '')
				return self.isTalkingTo(target)
			},
		},
		target_latched: {
			name: 'Target: latched',
			type: 'boolean',
			defaultStyle: {
				// Blue-when-active, matching the Flutter UI latch look.
				bgcolor: combineRgb(38, 90, 210),
				color: combineRgb(255, 255, 255),
			},
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
			callback: (feedback) => {
				const target = String(feedback.options.target ?? '')
				return self.isLatched(target)
			},
		},
		target_online: {
			name: 'Target: online (only for user targets)',
			type: 'boolean',
			defaultStyle: {
				bgcolor: combineRgb(25, 80, 25),
				color: combineRgb(255, 255, 255),
			},
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
			callback: (feedback) => {
				const target = String(feedback.options.target ?? '')
				return self.isTargetOnline(target)
			},
		},
		mic_muted: {
			name: 'Mic: muted',
			type: 'boolean',
			defaultStyle: {
				bgcolor: combineRgb(180, 30, 30),
				color: combineRgb(255, 255, 255),
			},
			options: [],
			callback: () => self.isMicMuted(),
		},
	}
}
