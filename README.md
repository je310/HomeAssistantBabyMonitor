# Audio Monitor Mix (Home Assistant Add-on)

Mix audio from **two or more RTSP camera streams** into a **single low-latency live audio stream** that you can play in VLC (desktop or Android).

**Typical use cases**
- Baby monitor audio in the background
- Whole-house “audio monitor” (multiple rooms at once)
- “Always on” audio feed with ~1–3s end-to-end latency (depends on cameras + network)

---

## How it works (architecture)

This add-on runs a small live audio pipeline:

1) **One FFmpeg “receiver” per camera**  
   Each receiver opens its own RTSP session and decodes camera audio to raw PCM.

2) **One FFmpeg “mixer” process**  
   The mixer consumes the per-camera PCM feeds, applies per-stream volumes, mixes them, adds a limiter, and encodes the final output.

3) **Optional MediaMTX RTSP server** (when `output_format: rtsp`)  
   MediaMTX publishes `rtsp://<HA_IP>:28554/live` for client playback.

**Design goal:** keep everything “live” by avoiding unbounded buffering, and recover automatically if any stream drops.

---

## Quick start

1. Install this add-on.
2. Configure at least **two** RTSP URLs under `streams`.
3. Start the add-on.
4. Open in VLC:

### RTSP (recommended)
`rtsp://YOUR_HA_IP:28554/live`

### HTTP
`http://YOUR_HA_IP:8098/`

### SRT
`srt://YOUR_HA_IP:8099`

> Tip: If VLC is outside your LAN, you’ll need the relevant port exposed (or use VPN). RTSP is easiest on LAN; SRT can work well over unreliable links.

---

## VLC low-latency settings

Latency is the sum of:
- camera encode / stream delay,
- network jitter/buffering,
- VLC caching.

### Desktop VLC (Windows/macOS/Linux)
Tools → Preferences → **Input/Codecs**:
- **Network caching:** `100 ms` (try 50–250ms)
- **File caching:** `100 ms`

Command line:
```bash
vlc --network-caching=100 rtsp://YOUR_HA_IP:28554/live
```

### VLC for Android
- Open the RTSP URL: `rtsp://YOUR_HA_IP:28554/live`
- Settings → Advanced → **Network caching:** `100 ms`

VLC should treat it as an audio stream and show the audio player UI.

---

## Configuration

### Basic options

| Option | Default | Meaning |
|---|---:|---|
| `output_format` | `rtsp` | Output protocol: `rtsp`, `http`, or `srt` |
| `streams` | — | List of camera RTSP URLs (required) |
| `volumes` | `[1.0, …]` | Per-stream gain multiplier (same length as `streams`) |
| `codec` | `aac` | Output codec: `aac` or `mp3` |
| `bitrate` | `64k` | Output bitrate (e.g., `64k`, `96k`, `128k`) |
| `channels` | `1` | Output channels: `1` mono / `2` stereo |
| `sample_rate` | `16000` | Output sample rate (Hz) |
| `ffmpeg_loglevel` | `info` | FFmpeg log verbosity |
| `restart_delay_sec` | `1` | Restart delay if pipeline crashes |

### Transport / latency tuning options

These matter when you’re chasing “as live as possible”:

| Option | Recommended | Meaning |
|---|---:|---|
| `rtsp_transport` | `tcp` | Camera RTSP transport. TCP is usually more stable (fewer late packets / reordering). UDP can be lower latency on perfect LANs but can drift badly if packets are missed. |
| `max_delay_us` | `150000` | Caps how long FFmpeg will buffer/reorder RTSP/RTP packets before dropping late data (microseconds). Lower = more live; too low = more dropouts. |
| `ingest_warmup_sec` | `2` | Discards startup skew by letting all receivers “settle” before mixing begins. Useful when one camera connects faster than the other. |
| `udp_fifo_ms` | `250` | (If using UDP internal hop) Target buffering for local audio hop. Lower = more live; higher = fewer dropouts. |
| `udp_buffer_size` | `65536` | Kernel UDP receive buffer hint for the internal hop. |

> If you ever hear “one stream is seconds behind another,” it is almost always caused by buffering/jitter handling. Start by switching camera inputs to `rtsp_transport: tcp`, then tune `max_delay_us` / warmup.

---

## Examples

### Two cameras (most common)
```yaml
output_format: rtsp
rtsp_transport: tcp
streams:
  - rtsp://admin:pass@192.168.1.100/h264Preview_01_sub
  - rtsp://admin:pass@192.168.1.101/h264Preview_01_sub
volumes:
  - 1.0
  - 1.0
sample_rate: 16000
codec: aac
bitrate: 64k
channels: 1
```

### Make it “more live” (at the cost of dropouts)
```yaml
rtsp_transport: tcp
max_delay_us: 80000
ingest_warmup_sec: 2
udp_fifo_ms: 150
```

### Make it “more stable” (at the cost of latency)
```yaml
rtsp_transport: tcp
max_delay_us: 250000
udp_fifo_ms: 500
```

---

## Troubleshooting

### VLC can’t connect
- RTSP output: confirm `28554/tcp` is exposed and not blocked.
- HTTP output: confirm `8098/tcp`.
- SRT output: confirm `8099/udp`.
- Check add-on logs for MediaMTX startup and “publishing to path ‘live’”.

### High latency (>5s)
- Reduce VLC network caching to 50–150ms.
- Prefer the camera “sub stream” URL (e.g. `…/h264Preview_01_sub`).
- Set `rtsp_transport: tcp` if you see packet loss / drift.
- Lower buffering knobs:
  - `udp_fifo_ms: 150–250`
  - `max_delay_us: 80000–150000`

### Streams drift / one room echoes seconds later
This is typically buffering buildup. Fix order:
1) Use `rtsp_transport: tcp`
2) Set/keep `ingest_warmup_sec: 2–4`
3) Lower `udp_fifo_ms` (if enabled)
4) Lower `max_delay_us` (but don’t go so low that it becomes unusable)

### Dropouts / stuttering
- Increase VLC caching slightly (e.g., 150–300ms).
- Increase `udp_fifo_ms` (e.g., 400–600).
- Increase `max_delay_us` (e.g., 200000–300000).
- Ensure the camera network is stable.

---

## Notes / limitations

- Designed for **audio monitoring**, not A/V sync.
- Mixing inherently means you may hear an “echo” if cameras have different inherent encode delays. The pipeline prioritizes staying live and stable over perfect alignment.
- If you want deterministic alignment, you’d add per-stream fixed delay (`adelay`) — but that’s intentionally not the default.

---

## Development / technical details

- Each camera runs in its own FFmpeg receiver process (independent RTSP session + jitter handling).
- Mixer uses FFmpeg `amix` + limiter to prevent clipping.
- RTSP output uses **MediaMTX** and publishes to `/live`.
- The add-on restarts the entire pipeline if any receiver/mixer exits.

---

## URLs recap

- RTSP: `rtsp://YOUR_HA_IP:28554/live`
- HTTP: `http://YOUR_HA_IP:8098/`
- SRT: `srt://YOUR_HA_IP:8099`
