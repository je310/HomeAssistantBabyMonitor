# Audio Monitor Mix (Home Assistant Add-on)

Mix audio from one or more RTSP camera streams into a **low-latency audio stream** for VLC playback.

**Use case:** Baby monitor, whole-house audio monitoring with ~2 second latency.

## Quick Start

1. Install this add-on in Home Assistant
2. Configure your RTSP stream URL(s) in the add-on options
3. Start the add-on
4. In VLC, open:
   - **RTSP (recommended):** `rtsp://YOUR_HA_IP:18554/live`
   - **HTTP:** `http://YOUR_HA_IP:8098/`
   - **SRT:** `srt://YOUR_HA_IP:8099`

## VLC Settings for Low Latency

### Desktop (Windows/Mac/Linux)
Tools → Preferences → Show "All" settings → Input/Codecs:
- **Network caching:** `100` ms
- **File caching:** `100` ms

Or use command line:
```bash
vlc --network-caching=100 rtsp://192.168.x.x:18554/live
```

### Android
**For RTSP (recommended):**
1. Open VLC for Android
2. Go to: `rtsp://YOUR_HA_IP:18554/live`
3. Settings → Advanced → Network caching: `100` ms

VLC will detect it as audio-only and display it in the audio player interface.

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `output_format` | `rtsp` | Output protocol: `rtsp` (recommended), `http`, or `srt` |
| `streams` | — | List of RTSP URLs (required) |
| `volumes` | `[1.0]` | Per-stream volume multipliers |
| `rtsp_transport` | `udp` | RTSP transport: `udp` (recommended) or `tcp` |
| `srt_latency_ms` | `50` | SRT latency buffer (only used with SRT output) |
| `codec` | `aac` | Audio codec: `aac` or `mp3` |
| `bitrate` | `128k` | Audio bitrate |
| `channels` | `1` | Mono (1) or stereo (2) |
| `sample_rate` | `16000` | Audio sample rate in Hz |
| `ffmpeg_loglevel` | `warning` | FFmpeg log verbosity |
| `restart_delay_sec` | `1` | Seconds to wait before restarting on failure |

## Example: Multiple Cameras

```yaml
output_format: rtsp
streams:
  - rtsp://admin:pass@192.168.1.100/h264Preview_01_sub
  - rtsp://admin:pass@192.168.1.101/h264Preview_01_sub
  - rtsp://admin:pass@192.168.1.102/h264Preview_01_sub
volumes:
  - 1.0
  - 1.5
  - 0.8
```

## Troubleshooting

### High latency (>5s)
- Use `rtsp_transport: udp` instead of `tcp` for camera inputs
- Reduce VLC network caching to 50-100ms
- Try your camera's sub-stream URL (e.g., `/h264Preview_01_sub`)

### Audio dropouts
- For HTTP/RTSP: Increase VLC caching slightly
- For SRT: Increase `srt_latency_ms` to 100-200
- Check camera network connectivity

### VLC won't connect
- **RTSP:** Ensure port 18554/tcp is accessible
- **HTTP:** Ensure port 8098/tcp is accessible
- **SRT:** Ensure port 8099/udp is accessible
- Try restarting the add-on
- Check add-on logs for errors

### Android VLC issues
- Use `output_format: rtsp` (best compatibility)
- Make sure you're using the correct URL format

## Technical Details

- Uses FFmpeg with parallel input thread processing (`-thread_queue_size 512`)
- RTSP output uses MediaMTX server (lightweight RTSP server for live streaming)
- HTTP output uses MPEG-TS with chunked transfer for live streaming
- SRT output uses UDP with configurable latency buffer
- Automatic audio sync without manual delay configuration
- Supports audio passthrough (no re-encoding) for single streams
