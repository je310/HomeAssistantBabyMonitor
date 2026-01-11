#!/usr/bin/with-contenv bash
set -euo pipefail

source /usr/lib/bashio/bashio.sh

bashio::log.info "=========================================="
bashio::log.info "  AUDIO MONITOR MIX (v3.0 multi-stream)   "
bashio::log.info "=========================================="

# -----------------------------
# Read config
# -----------------------------
OUTPUT_FORMAT="$(bashio::config 'output_format')"          # rtsp|http|srt
CODEC="$(bashio::config 'codec')"                          # aac|mp3
BITRATE="$(bashio::config 'bitrate')"
CHANNELS_OUT="$(bashio::config 'channels')"                # 1 or 2
SR="$(bashio::config 'sample_rate')"                       # 8000..48000
RTSP_TRANSPORT_CFG="$(bashio::config 'rtsp_transport')"    # tcp|udp (we force TCP for cameras)
RESTART_DELAY="$(bashio::config 'restart_delay_sec')"
FFMPEG_LOGLEVEL="$(bashio::config 'ffmpeg_loglevel')"
SRT_LATENCY_MS="$(bashio::config 'srt_latency_ms')"

mapfile -t STREAMS < <(bashio::config 'streams[]' || true)
mapfile -t VOLUMES < <(bashio::config 'volumes[]' || true)

# Deduplicate streams (workaround for HA config caching bug)
declare -A seen_streams
declare -a UNIQUE_STREAMS=()
declare -a UNIQUE_VOLUMES=()
for i in "${!STREAMS[@]}"; do
  url="${STREAMS[$i]:-}"
  if [[ -n "$url" && -z "${seen_streams[$url]:-}" ]]; then
    seen_streams["$url"]=1
    UNIQUE_STREAMS+=("$url")
    UNIQUE_VOLUMES+=("${VOLUMES[$i]:-1.0}")
  fi
done
STREAMS=("${UNIQUE_STREAMS[@]}")
VOLUMES=("${UNIQUE_VOLUMES[@]}")

N_STREAMS="${#STREAMS[@]}"
if [[ "$N_STREAMS" -lt 1 ]]; then
  bashio::log.error "Configure at least 1 RTSP URL under options.streams"
  exit 1
fi

# Pad volumes if fewer than streams
for ((i=${#VOLUMES[@]}; i<"$N_STREAMS"; i++)); do
  VOLUMES+=("1.0")
done

# -----------------------------
# Internal hop format (IMPORTANT)
# -----------------------------
# amix only supports float samples; feeding integer PCM makes ffmpeg auto-insert aresample conversions.
# Use float PCM internally to keep the graph simpler/cleaner and reduce buffering surprises.
RX_CHANNELS=1
RX_RATE="$SR"
RX_CODEC="pcm_f32le"
RX_MUX="f32le"
BYTES_PER_SAMPLE=4  # f32

# -----------------------------
# Latency knobs
# -----------------------------
CAM_RTSP_TRANSPORT="tcp"     # container-friendly; avoids UDP RTP port issues
MAX_DELAY_US=200000          # cap RTP reordering/jitter buffering where applicable
RTP_REORDER_QUEUE_SIZE=0

# Startup warmup:
# Start receivers first (no listener yet -> UDP packets are dropped).
# This lets each receiver "burn off" any initial camera/buffer burst so when mixer binds it starts near-live.
WARMUP_SEC=3

# UDP input buffer in the mixer (bytes). Keep small to avoid "seconds of lag".
# At 16k mono f32: 16,000 * 4 = 64KB/sec. So 64KB ≈ 1 second.
UDP_FIFO_SIZE_BYTES=$(( RX_RATE * RX_CHANNELS * BYTES_PER_SAMPLE ))  # ~1s
# You can push this down (e.g. /2) for even lower latency, at the expense of more dropouts.

# -----------------------------
# Output ports
# -----------------------------
SRT_PORT="8099"
HTTP_PORT="8098"
RTSP_PORT="28554"

# Internal UDP fanout base port
UDP_BASE_PORT="11111"

MEDIAMTX_PID=""
MIX_PID=""
declare -a RX_PIDS=()
declare -a UDP_PORTS=()

cleanup() {
  bashio::log.info "Cleaning up child processes..."

  if [[ -n "${MIX_PID:-}" ]] && kill -0 "$MIX_PID" 2>/dev/null; then
    kill -TERM "$MIX_PID" 2>/dev/null || true
  fi

  for pid in "${RX_PIDS[@]:-}"; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  if [[ -n "${MEDIAMTX_PID:-}" ]] && kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    kill -TERM "$MEDIAMTX_PID" 2>/dev/null || true
  fi

  sleep 0.5

  if [[ -n "${MIX_PID:-}" ]] && kill -0 "$MIX_PID" 2>/dev/null; then
    kill -KILL "$MIX_PID" 2>/dev/null || true
  fi

  for pid in "${RX_PIDS[@]:-}"; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  if [[ -n "${MEDIAMTX_PID:-}" ]] && kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    kill -KILL "$MEDIAMTX_PID" 2>/dev/null || true
  fi

  MIX_PID=""
  MEDIAMTX_PID=""
  RX_PIDS=()
  UDP_PORTS=()
}

trap cleanup EXIT INT TERM

start_mediamtx_if_needed() {
  if [[ "$OUTPUT_FORMAT" != "rtsp" ]]; then
    return 0
  fi

  bashio::log.info "Starting MediaMTX RTSP server on port ${RTSP_PORT}..."
  /usr/local/bin/mediamtx /mediamtx.yml &
  MEDIAMTX_PID=$!

  sleep 0.5
  if ! kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    bashio::log.error "MediaMTX failed to start (check /mediamtx.yml)."
    return 1
  fi
}

start_receivers() {
  RX_PIDS=()
  UDP_PORTS=()

  bashio::log.info "Starting ${N_STREAMS} receiver(s) (camera RTSP over ${CAM_RTSP_TRANSPORT}; config rtsp_transport=${RTSP_TRANSPORT_CFG})..."
  bashio::log.info "Internal hop: udp://127.0.0.1:<port> raw PCM ${RX_CODEC} (${RX_RATE} Hz, mono)"

  for ((i=0; i<N_STREAMS; i++)); do
    local url="${STREAMS[$i]}"
    local port=$((UDP_BASE_PORT + i))
    UDP_PORTS+=("$port")

    bashio::log.info "Receiver CAM$((i+1)) → udp://127.0.0.1:${port} (${RX_MUX})"

    ffmpeg -nostdin -hide_banner -loglevel "$FFMPEG_LOGLEVEL" \
      -rtsp_transport "$CAM_RTSP_TRANSPORT" -timeout 5000000 \
      -fflags nobuffer+discardcorrupt -flags low_delay \
      -max_delay "$MAX_DELAY_US" \
      -reorder_queue_size "$RTP_REORDER_QUEUE_SIZE" \
      -probesize 32k -analyzeduration 0 \
      -i "$url" \
      -map 0:a:0 -vn -sn -dn \
      -ac "$RX_CHANNELS" -ar "$RX_RATE" -c:a "$RX_CODEC" \
      -f "$RX_MUX" -flush_packets 1 \
      "udp://127.0.0.1:${port}?pkt_size=1316" \
      &

    RX_PIDS+=("$!")
  done
}

build_filter_complex() {
  local fc=""
  local mix_inputs=""

  for ((i=0; i<N_STREAMS; i++)); do
    local vol="${VOLUMES[$i]:-1.0}"
    fc+="[${i}:a]volume=${vol}[a${i}];"
    mix_inputs+="[a${i}]"
  done

  # For live sources, drive output duration/clock off the first input to avoid a laggy input stalling the whole mix.
  # Also disable normalize to keep it a straight sum + limiter.
  fc+="${mix_inputs}amix=inputs=${N_STREAMS}:duration=first:normalize=0:dropout_transition=0,alimiter=limit=0.95[outa]"

  echo "$fc"
}

start_mixer() {
  bashio::log.info "Starting mixer (${N_STREAMS} input(s)) → ${OUTPUT_FORMAT} (codec=${CODEC}, bitrate=${BITRATE})"
  bashio::log.info "Mixer UDP fifo_size=${UDP_FIFO_SIZE_BYTES} bytes (small buffer to prevent multi-second lag)"

  local IN_ARGS=()
  for ((i=0; i<N_STREAMS; i++)); do
    local port="${UDP_PORTS[$i]}"
    IN_ARGS+=(
      -f "$RX_MUX" -ar "$RX_RATE" -ac "$RX_CHANNELS"
      -i "udp://127.0.0.1:${port}?fifo_size=${UDP_FIFO_SIZE_BYTES}&overrun_nonfatal=1"
    )
  done

  local OUT_ARGS=()
  if [[ "$OUTPUT_FORMAT" == "http" ]]; then
    OUT_ARGS=(
      -f mpegts
      -mpegts_flags +initial_discontinuity
      -flush_packets 1
      -muxdelay 0 -muxpreload 0
      -listen 1 -seekable 0
      "http://0.0.0.0:${HTTP_PORT}/"
    )
  elif [[ "$OUTPUT_FORMAT" == "rtsp" ]]; then
    OUT_ARGS=(
      -f rtsp
      -rtsp_transport tcp
      -rtsp_flags prefer_tcp
      -flush_packets 1
      -muxdelay 0 -muxpreload 0
      "rtsp://127.0.0.1:${RTSP_PORT}/live"
    )
  else
    OUT_ARGS=(
      -f mpegts
      -flush_packets 1
      -muxdelay 0 -muxpreload 0
      "srt://0.0.0.0:${SRT_PORT}?mode=listener&latency=${SRT_LATENCY_MS}000&transtype=live&payloadsize=1316"
    )
  fi

  local FILTER_COMPLEX
  FILTER_COMPLEX="$(build_filter_complex)"

  ffmpeg -nostdin -hide_banner -loglevel "$FFMPEG_LOGLEVEL" \
    -fflags nobuffer -flags low_delay \
    "${IN_ARGS[@]}" \
    -filter_complex "$FILTER_COMPLEX" \
    -map "[outa]" \
    -ar "$RX_RATE" \
    -ac "$CHANNELS_OUT" \
    -c:a "$CODEC" -b:a "$BITRATE" \
    "${OUT_ARGS[@]}" \
    &

  MIX_PID=$!
  bashio::log.info "Mixer PID=${MIX_PID}"
}

# -----------------------------
# Main supervisor loop
# -----------------------------
while true; do
  cleanup || true

  bashio::log.info "Launching pipeline (${N_STREAMS} receiver(s) + mixer, output=${OUTPUT_FORMAT})..."
  start_mediamtx_if_needed

  # Start receivers first. UDP packets are dropped until mixer binds its ports.
  start_receivers

  bashio::log.info "Warmup: letting receivers settle for ${WARMUP_SEC}s before binding mixer UDP inputs..."
  sleep "$WARMUP_SEC"

  start_mixer

  bashio::log.info "Running. MIX=${MIX_PID} ${MEDIAMTX_PID:+, MTX=${MEDIAMTX_PID}} RX_PIDS=${RX_PIDS[*]}"

  set +e
  # If any one process dies, restart the whole pipeline.
  wait -n "$MIX_PID" "${RX_PIDS[@]}"
  EXIT_CODE=$?
  set -e

  bashio::log.warning "A pipeline process exited (code=${EXIT_CODE}). Restarting in ${RESTART_DELAY}s..."
  sleep "$RESTART_DELAY"
done
