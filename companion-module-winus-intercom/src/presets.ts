// @ts-nocheck
import { combineRgb, type CompanionPresetDefinitions } from '@companion-module/base'
import type { WinusIntercomInstance } from './index.js'

/**
 * Presets for Stream Deck: MIC MUTE, TALK ALL, per-target TALK + LATCH.
 */
const BG_TALK = combineRgb(50, 50, 50)
const BG_LATCH = combineRgb(35, 35, 55)
const BG_MIC_MUTE = combineRgb(50, 50, 50)
const BG_TALK_ALL = combineRgb(60, 50, 20)
const FG_WHITE = combineRgb(255, 255, 255)
const FG_DIM = combineRgb(160, 160, 160)

export function buildPresets(self: WinusIntercomInstance): CompanionPresetDefinitions {
	const targets = self.getTargetChoices().slice(0, 6)
	const presets: CompanionPresetDefinitions = {}

	// ── TALK ALL ──
	presets['talk_all'] = {
		type: 'simple',
		category: 'Intercom Control',
		name: 'Talk All',
		style: {
			text: 'TALK\\nALL',
			size: 14,
			color: FG_WHITE,
			bgcolor: BG_TALK_ALL,
		},
		steps: [
			{
				down: [{ actionId: 'talk_all_press', options: {} }],
				up: [{ actionId: 'talk_all_release', options: {} }],
			},
		],
		feedbacks: [],
	}

	// ── Per-target presets (columns 2-7) ──
	for (let i = 0; i < 6; i++) {
		const target = targets[i]
		const targetId = target?.id ?? ''
		const label = target?.label ?? `Dest ${i + 1}`
		// Short label for button text (first word or truncated)
		const short = label.split(/[\s(]/)[0].substring(0, 8)

		// TALK (momentary)
		presets[`talk_${i}`] = {
			type: 'simple',
			category: 'PTT Momentary',
			name: `Talk ${label}`,
			style: {
				text: `${short}\\nTALK`,
				size: 'auto',
				color: FG_WHITE,
				bgcolor: BG_TALK,
			},
			steps: [
				{
					down: [{ actionId: 'ptt_press', options: { target: targetId } }],
					up: [{ actionId: 'ptt_release', options: { target: targetId } }],
				},
			],
			feedbacks: [
				{
					feedbackId: 'target_talking',
					options: { target: targetId },
					style: {
						bgcolor: combineRgb(200, 40, 40),
						color: FG_WHITE,
					},
				},
				{
					feedbackId: 'target_online',
					options: { target: targetId },
					style: {
						bgcolor: combineRgb(30, 70, 30),
					},
				},
			],
		}

		// Row 4: LATCH (permanent toggle)
		presets[`latch_${i}`] = {
			type: 'simple',
			category: 'PTT Latch',
			name: `Latch ${label}`,
			style: {
				text: `${short}\\nLATCH`,
				size: 'auto',
				color: FG_DIM,
				bgcolor: BG_LATCH,
			},
			steps: [
				{
					down: [{ actionId: 'ptt_latch_toggle', options: { target: targetId } }],
					up: [],
				},
			],
			feedbacks: [
				{
					feedbackId: 'target_latched',
					options: { target: targetId },
					style: {
						bgcolor: combineRgb(38, 90, 210),
						color: FG_WHITE,
						text: `${short}\\n● ON`,
					},
				},
			],
		}
	}

	return presets
}
