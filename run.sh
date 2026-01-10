#!/usr/bin/with-contenv bash
set -euo pipefail

source /usr/lib/bashio/bashio.sh

bashio::log.info "=============================================="
bashio::log.info "          AUDIO MONITOR MIX                   "
bashio::log.info "=============================================="

# Read config
CODEC="$(bashio::config 'codec')"
BITRATE="$(bashio::config 'bitrate')"
CHANNELS="$(bashio::config 'channels')"
SR="$(bashio::config 'sample_rate')"
RTSP_TRANSPORT="$(bashio::config 'rtsp_transport')"
RESTART_DELAY="$(bashio::config 'restart_delay_sec')"
FFMPEG_LOGLEVEL="$(bashio::config 'ffmpeg_loglevel')"
SRT_LATENCY_MS="$(bashio::config 'srt_latency_ms')"

mapfile -t STREAMS < <(bashio::config 'streams[]' || true)
mapfile -t VOLUMES < <(bashio::config 'volumes[]' || true)

SRT_PORT="8099"

bashio::log.info "Config:"
bashio::log.info "  Streams:      ${#STREAMS[@]}"
bashio::log.info "  RTSP:         ${RTSP_TRANSPORT}"
bashio::log.info "  SRT latency:  ${SRT_LATENCY_MS}ms"
bashio::log.info "  Codec:        ${CODEC} (${BITRATE}, ${SR}Hz, ${CHANNELS}ch)"
bashio::log.info "=============================================="

if [ "${#STREAMS[@]}" -lt 1 ]; then
  bashio::log.error "No streams configured. Add RTSP URLs under options.streams"
  exit 1
fi

run_ffmpeg() {
  local -a input_args=()
  local i url vol

  # Build input arguments
  for i in "${!STREAMS[@]}"; do
    url="${STREAMS[$i]}"
    input_args+=(
      -rtsp_transport "$RTSP_TRANSPORT"
      -fflags +nobuffer+genpts+igndts
      -flags low_delay
      -probesize 32768
      -analyzeduration 500000
      -i "$url"
    )
  done

  local n="${#STREAMS[@]}"
  local filter=""
  local map_arg="0:a"
  local use_filter=false

  if [ "$n" -eq 1 ] && [ "${VOLUMES[0]:-1.0}" = "1.0" ]; then
    # Single stream, no volume change: passthrough (copy)
    use_filter=false
    map_arg="0:a"
  elif [ "$n" -eq 1 ]; then
    # Single stream with volume change
    use_filter=true
    filter="[0:a]volume=${VOLUMES[0]}[aout]"
    map_arg="[aout]"
  else
    # Multiple streams: mix them
    for i in "${!STREAMS[@]}"; do
      vol="${VOLUMES[$i]:-1.0}"
      filter="${filter}[${i}:a]volume=${vol}[a${i}];"
    done
    local amix_in=""
    for i in "${!STREAMS[@]}"; do
      amix_in="${amix_in}[a${i}]"
    done
    filter="${filter}${amix_in}amix=inputs=${n}:duration=longest:dropout_transition=0.5[aout]"
    map_arg="[aout]"
    use_filter=true
  fi

  # SRT output URL
  local srt_url="srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=${SRT_LATENCY_MS}000&transtype=live&payloadsize=1316"

  # Build output arguments
  local -a out_args=()
  if [ "$use_filter" = false ]; then
    # Passthrough mode - no encoding
    out_args=(-map "$map_arg" -vn -c:a copy)
    bashio::log.info "SRT: srt://<HA_IP>:${SRT_PORT} (passthrough, latency=${SRT_LATENCY_MS}ms)"
  elif [ "$CODEC" = "aac" ]; then
    out_args=(-map "$map_arg" -vn -ac "$CHANNELS" -ar "$SR" -c:a aac -b:a "$BITRATE")
    bashio::log.info "SRT: srt://<HA_IP>:${SRT_PORT} (aac ${BITRATE}, latency=${SRT_LATENCY_MS}ms)"
  else
    out_args=(-map "$map_arg" -vn -ac "$CHANNELS" -ar "$SR" -c:a libmp3lame -b:a "$BITRATE")
    bashio::log.info "SRT: srt://<HA_IP>:${SRT_PORT} (mp3 ${BITRATE}, latency=${SRT_LATENCY_MS}ms)"
  fi

  # MPEG-TS muxer settings for low latency
  out_args+=(-f mpegts -flush_packets 1 -muxdelay 0 -muxpreload 0)

  # Run FFmpeg
  if [ "$use_filter" = true ]; then
    ffmpeg -hide_banner -nostdin -loglevel "${FFMPEG_LOGLEVEL}" \
      -avioflags direct \
      "${input_args[@]}" \
      -filter_complex "$filter" \
      "${out_args[@]}" \
      "$srt_url"
  else
    ffmpeg -hide_banner -nostdin -loglevel "${FFMPEG_LOGLEVEL}" \
      -avioflags direct \
      "${input_args[@]}" \
      "${out_args[@]}" \
      "$srt_url"
  fi
}

bashio::log.info "Starting audio stream..."

while true; do
  set +e
  run_ffmpeg
  rc=$?
  set -e
  bashio::log.warning "FFmpeg exited (code=${rc}). Restarting in ${RESTART_DELAY}s..."
  sleep "$RESTART_DELAY"
done
