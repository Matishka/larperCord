# Go Live / screen sharing for larperCord (work in progress)

**Status:** protocol groundwork only. The Windows build produced from this branch **cannot transmit or watch a Discord screen share yet**. Do not represent this as a working "Go Live" feature.

## Why this is a separate feature

The user asked for "демки" — screen sharing/Go Live in Discord voice channels. The app currently has working **audio** with Discord voice gateway v8, Opus, UDP and libdave/DAVE, but no screen video transport or capture path. The existing `--demo` CLI switch is unrelated; it loads fake UI data and does not share the screen.

Discord streams are **separate RTC sessions** from a parent call. A stream's `stream_key` identifies the type, parent channel and owner; stream create/server update events provide **separate** RTC IDs and endpoint. A player must not reuse the parent audio SSRC or DAVE group ID.

References:
- Discord Voice Connections (DAVE and E2EE): https://github.com/discord/discord-api-docs/blob/main/developers/topics/voice-connections.mdx
- DAVE protocol: https://github.com/discord/dave-protocol/blob/main/protocol.md
- Community documentation for streaming (unofficial and subject to change): https://docs.discord.food/gateway/gateway-events#stream-create
- Community voice/stream transport description: https://docs.discord.food/topics/voice-connections#streams
- Discord Go Live help: https://support.discord.com/hc/en-us/articles/360040816151-Go-Live-and-Screen-Share

## Current groundwork

- `src/net/stream_keys.zig` parses and validates `guild:<guild>:<channel>:<owner>`, `call:<channel>:<owner>` and `test:<owner>` identifiers without network calls.
- Tests include large snowflakes, invalid IDs, missing and extra segments, stream-to-call matching.
- `src/tests.zig` imports the tests so Windows CI checks the parser.
- No token, video, stream signaling, screen recording or user-interface modification is introduced in this first milestone.

## Recommended implementation sequence

1. **Incoming metadata, no media.** Parse `STREAM_CREATE`, `STREAM_UPDATE`, `STREAM_SERVER_UPDATE`, `STREAM_DELETE` through the existing Gateway → Event → Store pipeline. Keep stream token/endpoint in the networking layer, not UI/logs; notify the UI of active stream owner/channel and pause state. Test server guild, DM calls, deleted streams, unavailable endpoint, reconnect and RESUME. Do not infer stream availability from partial events.
2. **Local capture preview (Windows first).** With explicit user interaction, select screen/window and show a preview that stays *on the local machine*. Prefer Windows Graphics Capture (modern OS compositor API), with a controlled fallback only if necessary. Handle permission denials, protected content, device loss, monitor unplug, resizing and high DPI; stop capture immediately on leave/stop/crash. Never auto-start or persist captured frames.
3. **Encoder and packetization.** Implement H.264/AV1 as negotiated using a supported encoder (consider platform hardware encoding or FFmpeg), video RTP timestamps/fragmentation and RTCP/RTX feedback. Respect CPU/GPU, frame pacing and sender-requested quality. Do not silently transmit application/system sound.
4. **Own-stream negotiation.** Build the separate stream signaling/RTC pipeline, then integrate DAVE E2EE for *stream* media (not only voice), key rotation, transitions and stream-specific MLS identity. Allow Start/Stop only after the parent voice call is established and permissions are verified. Always emit a clear persistent "you are streaming" indicator. On errors, stop without leaking resources or leaving an orphaned stream.
5. **Viewing other streams.** Explicit Watch/Stop Watching, receive SSRC mapping, Media Sink Wants, RTP depacketization, DAVE decrypt, decoder, stream player, full-screen, quality selector, stream stop and graceful parent voice disconnect. Avoid transmitting as a viewer.
6. **Application audio sharing**, optional later milestone with opt-in capture and separate soundshare track.
7. **Tests / QA.** Unit tests on metadata and state transitions, demo/fake gateway fixtures, Windows Actions builds, then *manual two-account* checks (viewer + streamer) and a recording-free/privacy-oriented regression checklist.

## Product UX / accessibility

- Separate controls **Share screen** and **Watch** only after the associated transport works.
- Choose window vs whole monitor, give a strong capture indicator, and have one-click **Stop sharing** always visible.
- Smooth Cupertino styling is a later polish, not a prerequisite.
- Keep feature behind an **experimental** setting until successful interop tests.
- Reduced-motion and no unnecessary idle redraw must be respected.

## Compatibility / safety

Discord's third-party user-client behavior is not officially supported; account restriction risk exists. Do not automatically test live stream APIs with a real account or send probes to undocumented endpoints. Only test real streaming with a user-approved test account. Discord documents mandatory end-to-end encryption for audio/video after March 1, 2026, so an RTP-only stream without stream-specific DAVE must not be advertised as working.

**Branch policy:** This feature branches from the last manually tested folder commit `93a27cb`, and remains independent from the untested visual animations in PR #3. PR #2 and `main` must not be merged without the user's explicit approval.
