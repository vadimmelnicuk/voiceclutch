# VoiceClutch

<img src="Resources/VoiceClutch.png" alt="VoiceClutch" width="200" />

Private, on-device voice dictation for macOS with low-latency streaming transcription and LLM-powered corrections.

- **Stay in flow** - Dictate naturally with low-latency streaming and quick text injection into any active app.
- **Get cleaner output** - Optional LLM final pass improves punctuation, structure, and readability before insertion.
- **Keep your data local** - Speech recognition and transcript cleanup run on-device for privacy-first usage.

## Features

### Dictation Workflow & Controls

- **Menu bar app** - Runs as a lightweight macOS status bar utility with quick access to controls and preferences.
- **Flexible interaction modes** - Choose between `Hold-to-talk` and `Press-to-talk` based on your workflow.
- **Configurable listening shortcut** - Set a preferred modifier key or create a custom key combination.

### Productivity Helpers

- **Vocabulary manager** - Add manual replacements, review learned corrections, and import/export vocabulary JSON.
- **Clipboard recovery** - Restores your previous clipboard contents after dictation injection.
- **Media pause/resume** - Optionally pauses active macOS media playback while dictating and resumes after.
- **Microphone chimes** - Optional start/stop sounds for listening state feedback.

### Local Intelligence & Privacy

- **On-device processing** - Speech recognition and transcript post-processing run locally on your Mac.
- **Optional LLM final pass** - Enable local transcript cleanup and formatting refinement.
- **Optional clipboard context** - Allow clipboard-aware formatting context for the final pass.
- **Privacy-first behavior** - VoiceClutch does not collect analytics or usage telemetry.

## Getting Started

1. Download the latest release, then move `VoiceClutch.app` to `Applications`.
2. Launch VoiceClutch and confirm the menu bar icon appears.
3. Grant requested permissions (microphone and accessibility) when prompted.
4. Place your cursor in any text field.
5. Press and hold `Left Control` to dictate.
6. Open `Preferences` to customize shortcut, interaction mode, and optional features.

## Acknowledgements

- [FluidInference Nvidia Nemotron Speech Streaming 0.6b CoreML](https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml) - On-device low-latency streaming speech-to-text.
- [LFM2.5-1.2B-Instruct-MLX-4bit](https://huggingface.co/lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit) - Compact local model for cleanup.
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) - Swift MLX language-model runtime.
- [Apple Frameworks](https://developer.apple.com/documentation) - Native frameworks for app core.

## Feedback & Contributions

For issues, suggestions, or feature requests, please [open a ticket](https://github.com/vadimmelnicuk/voiceclutch/issues).

## License

[MIT License](LICENSE)
