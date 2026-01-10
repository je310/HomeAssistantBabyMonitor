# Audio Monitor Mix (Home Assistant Add-on)

Mixes audio from one or more RTSP camera streams into a **low-latency SRT audio stream** for VLC playback.

**Use case:** Baby monitor, whole-house audio monitoring with ~2 second latency.

## Quick Start

1. Install this add-on in Home Assistant
2. Configure your RTSP stream URL(s) in the add-on options
3. Start the add-on
4. In VLC, open: `srt://YOUR_HA_IP:8099`

## VLC Settings for Low Latency

For best results, configure VLC caching:

### Desktop (Windows/Mac/Linux)
Tools → Preferences → Show "All" settings → Input/Codecs:
- **Network caching:** `100` ms
- **Live capture caching:** `100` ms

Or use command line:
```
vlc --network-caching=100 srt://192.168.x.x:8099
```

### Android
Settings → Advanced → Network caching: `100` ms

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `streams` | — | List of RTSP URLs (required) |
| `volumes` | `[1.0]` | Per-stream volume multipliers |
| `rtsp_transport` | `udp` | RTSP transport: `udp` (recommended) or `tcp` |
| `srt_latency_ms` | `50` | SRT latency buffer (lower = less delay) |
| `codec` | `aac` | Audio codec: `aac` or `mp3` |
| `bitrate` | `128k` | Audio bitrate |
| `channels` | `1` | Mono (1) or stereo (2) |
| `sample_rate` | `16000` | Audio sample rate in Hz |
| `ffmpeg_loglevel` | `warning` | FFmpeg log verbosity |

## Example: Multiple Cameras

```yaml
streams:
  - rtsp://admin:pass@192.168.1.100
  - rtsp://admin:pass@192.168.1.101
  - rtsp://admin:pass@192.168.1.102
volumes:
  - 1.0
  - 1.5
  - 0.8
```

## Troubleshooting

### High latency (>5s)
- Use `rtsp_transport: udp` instead of `tcp`
- Reduce VLC network caching to 50-100ms
- Try your camera's sub-stream URL (e.g., `/h264Preview_01_sub`)

### Audio dropouts
- Increase `srt_latency_ms` to 100-200
- Check camera network connectivity

### VLC won't connect
- Ensure port 8099/udp is exposed in HA
- Try restarting the add-on
- Check add-on logs for errors

## Technical Details

- Uses FFmpeg for RTSP input and audio processing
- SRT (Secure Reliable Transport) for output
- MPEG-TS container for VLC compatibility
- Supports audio passthrough (no re-encoding) for single streams
