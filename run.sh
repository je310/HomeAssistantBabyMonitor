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

# Debug: show raw config
bashio::log.info "DEBUG: Raw streams config:"
bashio::config 'streams[]' || true

mapfile -t STREAMS < <(bashio::config 'streams[]' || true)
mapfile -t VOLUMES < <(bashio::config 'volumes[]' || true)
mapfile -t DELAYS < <(bashio::config 'delays[]' || true)

# Deduplicate streams (workaround for HA config caching bug)
declare -A seen_streams
declare -a UNIQUE_STREAMS=()
declare -a UNIQUE_VOLUMES=()
declare -a UNIQUE_DELAYS=()
for i in "${!STREAMS[@]}"; do
  url="${STREAMS[$i]}"
  if [[ -z "${seen_streams[$url]:-}" ]]; then
    seen_streams[$url]=1
    UNIQUE_STREAMS+=("$url")
    UNIQUE_VOLUMES+=("${VOLUMES[$i]:-1.0}")
    UNIQUE_DELAYS+=("${DELAYS[$i]:-0}")
  fi
done
STREAMS=("${UNIQUE_STREAMS[@]}")
VOLUMES=("${UNIQUE_VOLUMES[@]}")
DELAYS=("${UNIQUE_DELAYS[@]}")

SRT_PORT="8099"

bashio::log.info "Config:"
bashio::log.info "  Streams:      ${#STREAMS[@]}"
for i in "${!STREAMS[@]}"; do
  bashio::log.info "    [$i] ${STREAMS[$i]} (vol=${VOLUMES[$i]:-1.0}, delay=${DELAYS[$i]:-0}ms)"
done
bashio::log.info "  RTSP:         ${RTSP_TRANSPORT}"
bashio::log.info "  SRT latency:  ${SRT_LATENCY_MS}ms"
bashio::log.info "  Codec:        ${CODEC} (${BITRATE}, ${SR}Hz, ${CHANNELS}ch)"
bashio::log.info "=============================================="

if [ "${#STREAMS[@]}" -lt 1 ]; then
  bashio::log.error "No streams configured. Add RTSP URLs under options.streams"
  exit 1
fi

run_ffmpeg() {
  local -a cmd=()
  local i url vol
  local n="${#STREAMS[@]}"

  # Build FFmpeg command with parallel input threads
  cmd=(ffmpeg -hide_banner -nostdin -loglevel "${FFMPEG_LOGLEVEL}")

  # Add inputs with thread_queue_size for parallel processing
  for i in "${!STREAMS[@]}"; do
    url="${STREAMS[$i]}"
    cmd+=(
      -fflags nobuffer
      -flags low_delay
      -probesize 32
      -analyzeduration 0
      -thread_queue_size 512
      -rtsp_transport "$RTSP_TRANSPORT"
      -allowed_media_types audio
      -i "$url"
    )
  done

  # Build filter and output
  if [ "$n" -eq 1 ] && [ "${VOLUMES[0]:-1.0}" = "1.0" ]; then
    # Single stream, no volume: passthrough
    bashio::log.info "SRT: srt://<HA_IP>:${SRT_PORT} (passthrough, latency=${SRT_LATENCY_MS}ms)"
    cmd+=(-map 0:a -vn -c:a copy)
  elif [ "$n" -eq 1 ]; then
    # Single stream with volume
    vol="${VOLUMES[0]}"
    bashio::log.info "SRT: srt://<HA_IP>:${SRT_PORT} (aac ${BITRATE}, latency=${SRT_LATENCY_MS}ms)"
    cmd+=(-filter_complex "[0:a]volume=${vol}[aout]" -map "[aout]" -vn -ac "$CHANNELS" -ar "$SR" -c:a aac -b:a "$BITRATE")
  else
    # Multiple streams: mix with volume
    local filter=""
    local amix_in=""
    for i in "${!STREAMS[@]}"; do
      vol="${VOLUMES[$i]:-1.0}"
      filter="${filter}[${i}:a]volume=${vol}[a${i}];"
      amix_in="${amix_in}[a${i}]"
    done
    filter="${filter}${amix_in}amix=inputs=${n}:duration=shortest:dropout_transition=0:normalize=0[aout]"
    bashio::log.info "Filter: ${filter}"
    bashio::log.info "SRT: srt://<HA_IP>:${SRT_PORT} (aac ${BITRATE}, latency=${SRT_LATENCY_MS}ms)"
    cmd+=(-filter_complex "$filter" -map "[aout]" -vn -ac "$CHANNELS" -ar "$SR" -c:a aac -b:a "$BITRATE")
  fi

  # Output settings
  local srt_url="srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=${SRT_LATENCY_MS}000&transtype=live&payloadsize=1316"
  cmd+=(-f mpegts -flush_packets 1 -muxdelay 0 -muxpreload 0 "$srt_url")

  # Run
  "${cmd[@]}"
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
