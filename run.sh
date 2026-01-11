#!/usr/bin/with-contenv bash
set -euo pipefail

source /usr/lib/bashio/bashio.sh

bashio::log.info "=========================================="
bashio::log.info "     AUDIO MONITOR MIX (v2.9 - UDP)       "
bashio::log.info "=========================================="

# -----------------------------
# Helpers
# -----------------------------
cfg() {
  local key="$1"
  local def="$2"
  if bashio::config.has_value "$key"; then
    bashio::config "$key"
  else
    echo "$def"
  fi
}

# -----------------------------
# Read config
# -----------------------------
OUTPUT_FORMAT="$(cfg 'output_format' 'rtsp')"          # rtsp|http|srt
CODEC="$(cfg 'codec' 'aac')"                           # aac|mp3
BITRATE="$(cfg 'bitrate' '64k')"
CHANNELS_OUT="$(cfg 'channels' '1')"                   # 1 or 2
SR="$(cfg 'sample_rate' '16000')"                      # 8000..48000
RESTART_DELAY="$(cfg 'restart_delay_sec' '1')"
FFMPEG_LOGLEVEL="$(cfg 'ffmpeg_loglevel' 'info')"
SRT_LATENCY_MS="$(cfg 'srt_latency_ms' '50')"

# New knobs (safe defaults)
INGEST_WARMUP_SEC="$(cfg 'ingest_warmup_sec' '2')"     # discard first N seconds before mixing starts
UDP_FIFO_MS="$(cfg 'udp_fifo_ms' '250')"               # target buffering per input (ms)
UDP_BUFFER_SIZE="$(cfg 'udp_buffer_size' '65536')"     # kernel socket buffer hint (bytes)
MAX_DELAY_US="$(cfg 'max_delay_us' '150000')"          # RTSP demux jitter cap (microseconds)
CAM_RTSP_TRANSPORT="$(cfg 'camera_rtsp_transport' 'tcp')"  # tcp recommended in HA add-on containers

mapfile -t STREAMS < <(bashio::config 'streams[]' || true)
mapfile -t VOLUMES < <(bashio::config 'volumes[]' || true)

# Deduplicate streams (workaround for HA config caching bug)
declare -A seen_streams
declare -a UNIQUE_STREAMS=()
declare -a UNIQUE_VOLUMES=()
for i in "${!STREAMS[@]}"; do
  url="${STREAMS[$i]}"
  if [[ -n "$url" && -z "${seen_streams[$url]:-}" ]]; then
    seen_streams["$url"]=1
    UNIQUE_STREAMS+=("$url")
    UNIQUE_VOLUMES+=("${VOLUMES[$i]:-1.0}")
  fi
done
STREAMS=("${UNIQUE_STREAMS[@]}")
VOLUMES=("${UNIQUE_VOLUMES[@]}")

if [ "${#STREAMS[@]}" -ne 2 ]; then
  bashio::log.error "This version requires exactly 2 streams. Configure 2 RTSP URLs under options.streams"
  exit 1
fi

CAM1_URL="${STREAMS[0]}"
CAM2_URL="${STREAMS[1]}"
VOL1="${VOLUMES[0]:-1.0}"
VOL2="${VOLUMES[1]:-1.0}"

# -----------------------------
# Internal UDP hop (drop-capable)
# -----------------------------
# 16kHz mono s16le = 32000 bytes/sec.
# UDP protocol fifo_size is in 188-byte packets, NOT bytes. 
RX_CHANNELS=1
RX_CODEC="pcm_s16le"
RX_MUX="s16le"
PKT_SIZE=1316

# Compute fifo_size packets to approximate UDP_FIFO_MS of audio
# bytes = SR * channels * 2bytes * ms/1000
FIFO_BYTES=$(( SR * RX_CHANNELS * 2 * UDP_FIFO_MS / 1000 ))
FIFO_PKTS=$(( (FIFO_BYTES + 187) / 188 ))
# Clamp to sane minimum/maximum
if (( FIFO_PKTS < 16 )); then FIFO_PKTS=16; fi
if (( FIFO_PKTS > 2048 )); then FIFO_PKTS=2048; fi

# Local ports for hop
HOP1_PORT=11111
HOP2_PORT=11112

HOP1_OUT="udp://127.0.0.1:${HOP1_PORT}?pkt_size=${PKT_SIZE}"
HOP2_OUT="udp://127.0.0.1:${HOP2_PORT}?pkt_size=${PKT_SIZE}"

# Small fifo + overrun_nonfatal=1 => drop old packets instead of building delay 
HOP1_IN="udp://127.0.0.1:${HOP1_PORT}?fifo_size=${FIFO_PKTS}&overrun_nonfatal=1&buffer_size=${UDP_BUFFER_SIZE}"
HOP2_IN="udp://127.0.0.1:${HOP2_PORT}?fifo_size=${FIFO_PKTS}&overrun_nonfatal=1&buffer_size=${UDP_BUFFER_SIZE}"

# -----------------------------
# Output ports
# -----------------------------
SRT_PORT="8099"
HTTP_PORT="8098"
RTSP_PORT="28554"

MEDIAMTX_PID=""
RX1_PID=""
RX2_PID=""
MIX_PID=""

cleanup() {
  bashio::log.info "Cleaning up child processes..."

  for pid in "$MIX_PID" "$RX1_PID" "$RX2_PID" "$MEDIAMTX_PID"; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  sleep 0.5

  for pid in "$MIX_PID" "$RX1_PID" "$RX2_PID" "$MEDIAMTX_PID"; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  MIX_PID=""; RX1_PID=""; RX2_PID=""; MEDIAMTX_PID=""
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

start_receiver_cam1() {
  bashio::log.info "Starting receiver CAM1 → UDP hop ${HOP1_PORT} (rtsp_transport=${CAM_RTSP_TRANSPORT}, max_delay=${MAX_DELAY_US}us)"
  ffmpeg -nostdin -hide_banner -loglevel "$FFMPEG_LOGLEVEL" \
    -rtsp_transport "$CAM_RTSP_TRANSPORT" -timeout 5000000 \
    -fflags nobuffer+discardcorrupt -flags low_delay \
    -max_delay "$MAX_DELAY_US" \
    -probesize 64k -analyzeduration 0 \
    -i "$CAM1_URL" \
    -map 0:a:0 -vn -sn -dn \
    -ac "$RX_CHANNELS" -ar "$SR" -c:a "$RX_CODEC" \
    -f "$RX_MUX" "$HOP1_OUT" \
    &
  RX1_PID=$!
}

start_receiver_cam2() {
  bashio::log.info "Starting receiver CAM2 → UDP hop ${HOP2_PORT} (rtsp_transport=${CAM_RTSP_TRANSPORT}, max_delay=${MAX_DELAY_US}us)"
  ffmpeg -nostdin -hide_banner -loglevel "$FFMPEG_LOGLEVEL" \
    -rtsp_transport "$CAM_RTSP_TRANSPORT" -timeout 5000000 \
    -fflags nobuffer+discardcorrupt -flags low_delay \
    -max_delay "$MAX_DELAY_US" \
    -probesize 64k -analyzeduration 0 \
    -i "$CAM2_URL" \
    -map 0:a:0 -vn -sn -dn \
    -ac "$RX_CHANNELS" -ar "$SR" -c:a "$RX_CODEC" \
    -f "$RX_MUX" "$HOP2_OUT" \
    &
  RX2_PID=$!
}

start_mixer() {
  bashio::log.info "Starting mixer: UDP hop → ${OUTPUT_FORMAT} (codec=${CODEC}, bitrate=${BITRATE})"
  bashio::log.info "UDP fifo target: ${UDP_FIFO_MS}ms => fifo_size=${FIFO_PKTS} (188-byte packets), overrun_nonfatal=1 (drops old) "

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

  ffmpeg -nostdin -hide_banner -loglevel "$FFMPEG_LOGLEVEL" \
    -fflags nobuffer -flags low_delay \
    -f "$RX_MUX" -ar "$SR" -ac "$RX_CHANNELS" -i "$HOP1_IN" \
    -f "$RX_MUX" -ar "$SR" -ac "$RX_CHANNELS" -i "$HOP2_IN" \
    -filter_complex "\
      [0:a]volume=${VOL1}[a0]; \
      [1:a]volume=${VOL2}[a1]; \
      [a0][a1]amix=inputs=2:normalize=0:dropout_transition=0,alimiter=limit=0.95[outa]" \
    -map "[outa]" \
    -ar "$SR" \
    -ac "$CHANNELS_OUT" \
    -c:a "$CODEC" -b:a "$BITRATE" \
    "${OUT_ARGS[@]}" \
    &
  MIX_PID=$!
}

# -----------------------------
# Main supervisor loop
# -----------------------------
while true; do
  cleanup || true

  bashio::log.info "Launching 3-process pipeline (UDP hop + warmup drop)..."
  start_mediamtx_if_needed

  # 1) Start both receivers FIRST (independent)
  start_receiver_cam1
  start_receiver_cam2
  bashio::log.info "Receivers running. PIDs: RX1=${RX1_PID}, RX2=${RX2_PID}"
  bashio::log.info "Warmup: discarding first ${INGEST_WARMUP_SEC}s of audio before starting mixer (prevents 'first stream wins' skew)."
  sleep "$INGEST_WARMUP_SEC"

  # If a receiver died during warmup, restart whole loop
  if ! kill -0 "$RX1_PID" 2>/dev/null || ! kill -0 "$RX2_PID" 2>/dev/null; then
    bashio::log.warning "A receiver exited during warmup; restarting..."
    continue
  fi

  # 2) Start mixer AFTER warmup (effectively: “open both, then add”)
  start_mixer
  bashio::log.info "Running. PIDs: RX1=${RX1_PID}, RX2=${RX2_PID}, MIX=${MIX_PID} ${MEDIAMTX_PID:+, MTX=${MEDIAMTX_PID}}"

  set +e
  wait -n "$RX1_PID" "$RX2_PID" "$MIX_PID" ${MEDIAMTX_PID:+ "$MEDIAMTX_PID"}
  EXIT_CODE=$?
  set -e

  bashio::log.warning "A pipeline process exited (code=${EXIT_CODE}). Restarting in ${RESTART_DELAY}s..."
  sleep "$RESTART_DELAY"
done
