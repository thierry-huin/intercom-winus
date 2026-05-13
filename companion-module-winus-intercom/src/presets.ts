import { combineRgb, type CompanionPresetDefinitions } from '@companion-module/base'
import type { WinusIntercomInstance } from './index'

/**
 * Stream Deck XL layout (4 rows × 8 columns):
 *
 *   Col:  1          2       3       4       5       6       7       8
 *   R1:   (empty)    VOL+    VOL+    VOL+    VOL+    VOL+    VOL+    (empty)
 *   R2:   MIC MUTE   VOL-    VOL-    VOL-    VOL-    VOL-    VOL-    (empty)
 *   R3:   TALK ALL   TALK    TALK    TALK    TALK    TALK    TALK    (empty)
 *   R4:   (empty)    LATCH   LATCH   LATCH   LATCH   LATCH   LATCH   (empty)
 *
 * Columns 2-7 map to the first 6 targets from the server (auto-filled).
 */

const BG_DEFAULT = combineRgb(30, 30, 30)
const BG_VOL_UP = combineRgb(40, 60, 40)
const BG_VOL_DOWN = combineRgb(60, 40, 40)
const BG_TALK = combineRgb(50, 50, 50)
const BG_LATCH = combineRgb(35, 35, 55)
const BG_MIC_MUTE = combineRgb(50, 50, 50)
const BG_TALK_ALL = combineRgb(60, 50, 20)
const FG_WHITE = combineRgb(255, 255, 255)
const FG_DIM = combineRgb(160, 160, 160)

export function buildPresets(self: WinusIntercomInstance): CompanionPresetDefinitions {
	const targets = self.getTargetChoices().slice(0, 6)
	const presets: CompanionPresetDefinitions = {}

	// ── Row 2 Col 1: MIC MUTE ──
	presets['mic_mute'] = {
		type: 'button',
		category: 'Intercom Control',
		name: 'Mic Mute',
		style: {
			text: 'MIC\\nMUTE',
			size: 14,
			color: FG_WHITE,
			bgcolor: BG_MIC_MUTE,
		},
		steps: [
			{
				down: [{ actionId: 'mic_mute_toggle', options: {} }],
				up: [],
			},
		],
		feedbacks: [
			{
				feedbackId: 'mic_muted',
				options: {},
				style: {
					bgcolor: combineRgb(200, 30, 30),
					color: FG_WHITE,
					text: 'MIC\\nOFF',
				},
			},
		],
	}

	// ── Row 3 Col 1: TALK ALL ──
	presets['talk_all'] = {
		type: 'button',
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

		// Row 1: VOL+
		presets[`vol_up_${i}`] = {
			type: 'button',
			category: 'Volume',
			name: `Vol+ ${label}`,
			style: {
				text: `${short}\\n▲ VOL`,
				size: 'auto',
				color: FG_DIM,
				bgcolor: BG_VOL_UP,
			},
			steps: [
				{
					down: [{ actionId: 'volume_up', options: { target: targetId } }],
					up: [],
				},
			],
			feedbacks: [],
		}

		// Row 2: VOL-
		presets[`vol_down_${i}`] = {
			type: 'button',
			category: 'Volume',
			name: `Vol- ${label}`,
			style: {
				text: `${short}\\n▼ VOL`,
				size: 'auto',
				color: FG_DIM,
				bgcolor: BG_VOL_DOWN,
			},
			steps: [
				{
					down: [{ actionId: 'volume_down', options: { target: targetId } }],
					up: [],
				},
			],
			feedbacks: [],
		}

		// Row 3: TALK (momentary)
		presets[`talk_${i}`] = {
			type: 'button',
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
			type: 'button',
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
