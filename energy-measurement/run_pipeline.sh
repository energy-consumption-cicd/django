#!/usr/bin/env bash
# RAPL energy measurement of the CI stages of django (non-ML: build and test, no train).
# Usage: bash run_pipeline.sh <run_number>

set -euo pipefail

RUN_NUM="${1:?Run number required (e.g. 1)}"
PROJECT_NAME="django"
# Overridable only to exercise the gates against deliberately defective images.
IMAGE_NAME="${IMAGE_NAME:-django-measurement-5.2.0}"
MEDICAO_DIR="$HOME/experimentos/medicao/repositorios/django/release-5.2.0"
# Overridable only for local tests, whose energy is diagnostic and must stay
# outside the run_*.csv glob of the aggregation.
RESULTS_DIR="${RESULTS_DIR:-$HOME/experimentos/medicao/resultados/django/release-5.2.0/runs}"
RAPL_BASE="/sys/class/powercap/intel-rapl"
BASELINE_DURATION=120
TIME_FILE="/tmp/django_time_$$.txt"
CSV_FILE="$RESULTS_DIR/run_$(printf '%02d' "$RUN_NUM").csv"
# Exit code sidecar (run,stage,exit_code), outside the CSV; its name must not
# match the run_*.csv glob of the aggregation.
EXITS_FILE="$RESULTS_DIR/exit_codes_run_$(printf '%02d' "$RUN_NUM").txt"

# Deferred status: every CSV row is written before the job fails.
PIPELINE_EXIT=0
FAILED_STAGES=""

# MEM_SWAP == MEM_LIMIT sets memory.swap.max=0: the measured process cannot page,
# while host swap remains an availability safeguard.
MEM_LIMIT="${MEM_LIMIT:-12g}"
MEM_SWAP="${MEM_SWAP:-$MEM_LIMIT}"

# --parallel stays at the upstream default (cpu_count): 8 processes here, 4 on the
# hosted runner. The divergence is declared, not corrected; upstream does not fix it.

# Pre-registered accepted exit codes per stage (space-separated).
EXIT_ACEITOS_build="${EXIT_ACEITOS_build:-0}"
# test accepts 1: intermittent failures under fork leave the executed test set unchanged.
EXIT_ACEITOS_test="${EXIT_ACEITOS_test:-0 1}"

# Outside the workload range (0..2, 128+N): 0 valid run; 65 run rejected by exit
# code (measurement intact, CSV moved to the discard directory); 1 measurement failure.
EXIT_RUN_REJEITADA=65

# Rejected runs are moved, not deleted: out of reach of the run_*.csv glob, still auditable.
DESCARTE_DIR="$RESULTS_DIR/discarded_exit_code"

RUN_REJEITADA_MOTIVO=""

# Paging alert threshold in 4 KiB pages (256 = 1 MiB); 15 pages is routine noise.
SWAP_WARN_PAGES="${SWAP_WARN_PAGES:-256}"

mkdir -p "$RESULTS_DIR"

# Stage stdout/stderr persisted on disk; the Actions log expires after 90 days.
LOGS_DIR="${LOGS_DIR:-$HOME/experimentos/medicao/resultados/django/release-5.2.0/logs}"
mkdir -p "$LOGS_DIR"

if [ ! -d "$RAPL_BASE" ]; then
  echo "RAPL not available at $RAPL_BASE" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Docker image '$IMAGE_NAME' not found." >&2
  echo "   Build it first:" >&2
  echo "   docker build -t $IMAGE_NAME -f energy-measurement/Dockerfile . (clone of branch release-5.2.0)" >&2
  exit 1
fi

# Functional gates, run before any measurement under the same --network none as the stages.

# GATE 1: django.setup() completes under test_sqlite with the sqlite3 backend.
if ! docker run --rm --network none -w /project/tests \
       -e DJANGO_SETTINGS_MODULE=test_sqlite "$IMAGE_NAME" \
       python -c "import django; django.setup(); from django.conf import settings; \
assert settings.DATABASES['default']['ENGINE'].endswith('sqlite3')" 2>/dev/null; then
  echo "In image '$IMAGE_NAME', django does not complete django.setup() under test_sqlite." >&2
  echo "   The 'test' stage would fail after measurement started. Rebuild the image." >&2
  exit 1
fi

# GATE 2: the interpreter of the tag cell (CPython 3.13.2, GIL enabled).
if ! docker run --rm --network none "$IMAGE_NAME" \
       python -c "import sys; assert sys._is_gil_enabled() and sys.version.split()[0] == '3.13.2'" 2>/dev/null; then
  echo "Image '$IMAGE_NAME' does not carry CPython 3.13.2 with the GIL enabled. Rebuild it." >&2
  exit 1
fi

# GATE 3: the wheelhouse resolves offline. --ignore-installed is required: otherwise
# the preinstalled /venv satisfies every requirement and an incomplete wheelhouse passes.
if ! docker run --rm --network none -w /project "$IMAGE_NAME" \
       pip install --dry-run --ignore-installed --quiet --no-index \
       --find-links=/wheelhouse \
       -r tests/requirements/py3.txt >/dev/null 2>&1; then
  echo "The /wheelhouse of image '$IMAGE_NAME' does not resolve offline." >&2
  echo "   The 'build' stage would fail under --network none. Rebuild the image." >&2
  exit 1
fi

# Truncated only after the gates pass, so the sidecar always describes the run
# that produced the adjacent CSV.
: > "$EXITS_FILE"

read_rapl() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]] || \
       [[ "$name" == "core"      && "$domain_name" == "cores" ]] || \
       [[ "$name" == "uncore"    && "$domain_name" == "gpu" ]] || \
       [[ "$name" == "dram"      && "$domain_name" == "ram" ]]; then
      local energy_file="$dir/energy_uj"
      [ -f "$energy_file" ] && value=$(cat "$energy_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_energy="$subdir/energy_uj"
        [ -f "$sub_energy" ] && value=$(cat "$sub_energy") && break 2
      fi
    done
  done
  echo "$value"
}

read_rapl_max() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]]; then
      local max_file="$dir/max_energy_range_uj"
      [ -f "$max_file" ] && value=$(cat "$max_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_max="$subdir/max_energy_range_uj"
        [ -f "$sub_max" ] && value=$(cat "$sub_max") && break 2
      fi
    done
  done
  [ "$value" -eq 0 ] && value=999999999999
  echo "$value"
}

# Package temperature (hwmon coretemp, label "Package id 0", located by name, never by
# index), read immediately before and after each stage's RAPL window, never inside it;
# recorded as a sidecar. Host swap stays in the CSV columns of the HEAD campaign.
TEMP_SENSOR=""
for hw in /sys/class/hwmon/hwmon*; do
  [ "$(cat "$hw/name" 2>/dev/null)" = "coretemp" ] || continue
  for lbl in "$hw"/temp*_label; do
    [ "$(cat "$lbl" 2>/dev/null)" = "Package id 0" ] && TEMP_SENSOR="${lbl%_label}_input" && break 2
  done
done
read_temp_c() { if [ -n "$TEMP_SENSOR" ] && [ -r "$TEMP_SENSOR" ]; then awk '{printf "%.1f", $1/1000}' "$TEMP_SENSOR"; else echo ""; fi; }

# RAPL counters wrap at max_energy_range_uj; deltas are overflow-corrected.
delta_uj() {
  local ini="$1" fin="$2" max="$3"
  if [ "$fin" -ge "$ini" ]; then
    echo $(( fin - ini ))
  else
    echo $(( max - ini + fin ))
  fi
}

echo ""
echo "-------------------------------------------------------"
echo " Run $RUN_NUM - $PROJECT_NAME"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "-------------------------------------------------------"
echo "Baseline rest (${BASELINE_DURATION}s)..."

b_pkg_ini=$(read_rapl pkg)
b_cores_ini=$(read_rapl cores)
b_gpu_ini=$(read_rapl gpu)
b_ram_ini=$(read_rapl ram)

sleep "$BASELINE_DURATION"

b_pkg_fin=$(read_rapl pkg)
b_cores_fin=$(read_rapl cores)
b_gpu_fin=$(read_rapl gpu)
b_ram_fin=$(read_rapl ram)

max_pkg=$(read_rapl_max pkg)
max_cores=$(read_rapl_max cores)
max_gpu=$(read_rapl_max gpu)
max_ram=$(read_rapl_max ram)

# Idle rate per domain (uJ/s), subtracted from each stage in proportion to its wall time.
b_delta_pkg=$(delta_uj "$b_pkg_ini" "$b_pkg_fin" "$max_pkg")
b_delta_cores=$(delta_uj "$b_cores_ini" "$b_cores_fin" "$max_cores")
b_delta_gpu=$(delta_uj "$b_gpu_ini" "$b_gpu_fin" "$max_gpu")
b_delta_ram=$(delta_uj "$b_ram_ini" "$b_ram_fin" "$max_ram")

taxa_pkg=$(awk  "BEGIN {printf \"%.6f\", $b_delta_pkg  / $BASELINE_DURATION}")
taxa_cores=$(awk "BEGIN {printf \"%.6f\", $b_delta_cores / $BASELINE_DURATION}")
taxa_gpu=$(awk  "BEGIN {printf \"%.6f\", $b_delta_gpu  / $BASELINE_DURATION}")
taxa_ram=$(awk  "BEGIN {printf \"%.6f\", $b_delta_ram  / $BASELINE_DURATION}")

echo "Baseline rate:"
echo "   pkg:   $(awk "BEGIN {printf \"%.2f\", $taxa_pkg / 1e6}") W"
echo "   cores: $(awk "BEGIN {printf \"%.2f\", $taxa_cores / 1e6}") W"
echo "   ram:   $(awk "BEGIN {printf \"%.2f\", $taxa_ram / 1e6}") W"

# swap_in_pages, swap_out_pages and cpu_time_cgroup_s are diagnostic, outside the
# statistical analysis. Under the forkserver start method (the CPython default from
# 3.14), test workers are not children of the timed process, so user_time_s and
# sys_time_s miss them; the container cgroup accounts for every process. Appended as
# column 14 so the first 13 keep their positions.
echo "run,stage,energy_pkg_j,energy_cores_j,energy_gpu_j,energy_ram_j,wall_time_s,user_time_s,sys_time_s,energy_ram_liquid_raw_j,wall_time_container_s,swap_in_pages,swap_out_pages,cpu_time_cgroup_s" \
  > "$CSV_FILE"

total_pkg=0; total_cores=0; total_gpu=0; total_ram=0; total_ram_raw=0
total_wall=0; total_user=0; total_sys=0; total_wall_container=0
total_swap_in=0; total_swap_out=0; total_cpu_cgroup=0

# Non-blocking CPU capture check: cpu/wall below 0.5 means either the cgroup capture
# regressed or the stage did not run its workload. Falls back to user+sys without the column.
alertar_user_sys() {
  local stage="$1" wall="$2" user_t="$3" sys_t="$4" cpu_cg="$5"
  local cpu fonte
  if awk "BEGIN {exit !($cpu_cg > 0)}"; then
    cpu="$cpu_cg"; fonte="cpu_time_cgroup_s"
  else
    cpu=$(awk "BEGIN {printf \"%.3f\", $user_t + $sys_t}"); fonte="user_time_s+sys_time_s (fallback)"
  fi
  awk "BEGIN {exit !($wall > 0)}" || return 0
  local r
  r=$(awk "BEGIN {printf \"%.4f\", $cpu / $wall}")
  if awk "BEGIN {exit !($r < 0.5)}"; then
    echo "   CPU CAPTURE in stage '$stage': ratio = $r < 0.5 (cpu=${cpu}s wall=${wall}s, source: $fonte)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "::warning title=Suspicious CPU capture::Run $RUN_NUM, stage '$stage': cpu/wall = $r < 0.5 (cpu=${cpu}s wall=${wall}s, source: $fonte)."
    fi
  else
    echo "   cpu/wall = $r (source: $fonte)"
  fi
  return 0
}

measure_stage() {
  local stage="$1"
  echo ""
  echo "Stage: $stage - $(date '+%H:%M:%S')"

  # World-writable: the container runs as uid 1001, and mktemp creates a mode 700
  # directory owned by the host user.
  local timing_dir
  timing_dir=$(mktemp -d)
  chmod 777 "$timing_dir"

  local temp_ini
  temp_ini=$(read_temp_c)

  local ini_pkg ini_cores ini_gpu ini_ram
  ini_pkg=$(read_rapl pkg)
  ini_cores=$(read_rapl cores)
  ini_gpu=$(read_rapl gpu)
  ini_ram=$(read_rapl ram)

  # pswpin/pswpout are host-wide: the measured process cannot page (memory.swap.max=0),
  # so a nonzero delta signals host memory pressure, which inflates wall time through
  # I/O contention without proportional energy.
  local pswpin_ini pswpout_ini
  pswpin_ini=$(awk '/^pswpin/{print $2}' /proc/vmstat)
  pswpout_ini=$(awk '/^pswpout/{print $2}' /proc/vmstat)

  # --network none: energy of computation only, no network traffic. set +e: a nonzero
  # workload exit must not abort before the final RAPL read and the CSV row.
  # PIPESTATUS[0] keeps the container status rather than that of tee.
  local stage_log="$LOGS_DIR/run_$(printf '%02d' "$RUN_NUM")_${stage}.log"
  local stage_exit=0
  set +e
  /usr/bin/time -f "%e" -o "$TIME_FILE" \
    docker run --rm --privileged --network none \
      --memory="$MEM_LIMIT" --memory-swap="$MEM_SWAP" \
      -v "$MEDICAO_DIR:/medicao:ro" \
      -v "$timing_dir:/timing" \
      -e "STAGE=$stage" \
      "$IMAGE_NAME" \
      bash -c 'C0=$(grep ^usage_usec /sys/fs/cgroup/cpu.stat | cut -d" " -f2 || echo "");
               exec 3>&2; TIMEFORMAT="%R %U %S";
               { time bash /medicao/commands.sh "$STAGE" 2>&3; } 2>/timing/time.txt
               rc=$?
               C1=$(grep ^usage_usec /sys/fs/cgroup/cpu.stat | cut -d" " -f2 || echo "");
               echo "$C0 $C1" > /timing/cpu.txt
               exit $rc' \
      2>&1 | tee "$stage_log"
  stage_exit=${PIPESTATUS[0]}
  set -e
  echo "   stage log: $stage_log"

  # Sidecar, not CSV: the CSV schema is shared across projects.
  echo "$RUN_NUM,$stage,$stage_exit" >> "$EXITS_FILE"

  # Rejection is decided here but applied after the CSV row is written, so the
  # measurement of what already ran is preserved.
  local aceitos_var="EXIT_ACEITOS_${stage}"
  local aceitos="${!aceitos_var:-0}"
  local dentro_da_lista=0
  local c
  for c in $aceitos; do
    [ "$stage_exit" -eq "$c" ] && dentro_da_lista=1 && break
  done

  if [ "$stage_exit" -ne 0 ]; then
    PIPELINE_EXIT="$stage_exit"
    FAILED_STAGES="${FAILED_STAGES:+$FAILED_STAGES }$stage(exit=$stage_exit)"
  fi

  if [ "$dentro_da_lista" -eq 0 ]; then
    RUN_REJEITADA_MOTIVO="stage '$stage' exited with exit=$stage_exit, outside the declared list {$(echo $aceitos | tr ' ' ',')}"
    echo "   stage '$stage': exit=$stage_exit OUTSIDE the declared list {$(echo $aceitos | tr ' ' ',')}; RUN WILL BE REJECTED"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "::error title=Run rejected by exit code::Run $RUN_NUM, stage '$stage': exit=$stage_exit, outside the DECLARED list {$(echo $aceitos | tr ' ' ',')} for django. The run is discarded and must be REPEATED; it does NOT count among the 10 official runs. CSV and sidecar preserved in runs/discarded_exit_code/. Stage log in resultados/django/logs/run_$(printf '%02d' "$RUN_NUM")_${stage}.log" | tee -a "$GITHUB_STEP_SUMMARY"
    fi
  elif [ "$stage_exit" -ne 0 ]; then
    echo "   stage '$stage': exit=$stage_exit (within the declared list; measurement PRESERVED, see $EXITS_FILE)"
  else
    echo "   stage '$stage': container exited with exit=0"
  fi

  local fin_pkg fin_cores fin_gpu fin_ram
  fin_pkg=$(read_rapl pkg)
  fin_cores=$(read_rapl cores)
  fin_gpu=$(read_rapl gpu)
  fin_ram=$(read_rapl ram)

  local temp_fin
  temp_fin=$(read_temp_c)
  {
    echo "sensor,${TEMP_SENSOR:--}"
    echo "label,Package id 0"
    echo "temp_pkg_start_c,$temp_ini"
    echo "temp_pkg_end_c,$temp_fin"
  } > "$RESULTS_DIR/temp_run_$(printf '%02d' "$RUN_NUM")_${stage}.txt"

  local pswpin_fim pswpout_fim swap_in swap_out
  pswpin_fim=$(awk '/^pswpin/{print $2}' /proc/vmstat)
  pswpout_fim=$(awk '/^pswpout/{print $2}' /proc/vmstat)
  swap_in=$(( pswpin_fim - pswpin_ini ))
  swap_out=$(( pswpout_fim - pswpout_ini ))

  local wall wall_container_t user_t sys_t
  # tail -n 1: on a nonzero exit, GNU time prepends a diagnostic line to the file.
  wall=$(tail -n 1 "$TIME_FILE")
  if ! [[ "$wall" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "   non-numeric wall_time ('$wall'); recording 0 and continuing" >&2
    wall="0.00"
  fi
  if [ -f "$timing_dir/time.txt" ]; then
    read -r wall_container_t user_t sys_t < "$timing_dir/time.txt"
  else
    wall_container_t="0.000"; user_t="0.000"; sys_t="0.000"
  fi

  # cgroup CPU in microseconds; 0.000 when unreadable (cgroup v1 or aborted stage),
  # the same fallback as the in-container timing.
  local cpu_cgroup_t="0.000"
  if [ -f "$timing_dir/cpu.txt" ]; then
    local c0 c1
    read -r c0 c1 < "$timing_dir/cpu.txt" || true
    if [[ "${c0:-}" =~ ^[0-9]+$ && "${c1:-}" =~ ^[0-9]+$ && "$c1" -ge "$c0" ]]; then
      cpu_cgroup_t=$(awk "BEGIN {printf \"%.3f\", ($c1 - $c0) / 1e6}")
    else
      echo "   unreadable cgroup cpu.stat ('${c0:-}' '${c1:-}'); cpu_time_cgroup_s=0" >&2
    fi
  fi
  rm -rf "$timing_dir"

  local d_pkg d_cores d_gpu d_ram
  d_pkg=$(delta_uj   "$ini_pkg"   "$fin_pkg"   "$max_pkg")
  d_cores=$(delta_uj "$ini_cores" "$fin_cores" "$max_cores")
  d_gpu=$(delta_uj   "$ini_gpu"   "$fin_gpu"   "$max_gpu")
  d_ram=$(delta_uj   "$ini_ram"   "$fin_ram"   "$max_ram")

  # Baseline subtracted and floored at zero.
  local j_pkg j_cores j_gpu j_ram j_ram_raw
  j_pkg=$(awk   "BEGIN {v=($d_pkg   - $taxa_pkg   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_cores=$(awk "BEGIN {v=($d_cores - $taxa_cores * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_gpu=$(awk   "BEGIN {v=($d_gpu   - $taxa_gpu   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_ram=$(awk   "BEGIN {v=($d_ram   - $taxa_ram   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")

  # Same net RAM delta without the floor (may be negative); transparency only, not analysed.
  j_ram_raw=$(awk "BEGIN {printf \"%.6f\", ($d_ram - $taxa_ram * $wall) / 1e6}")

  echo "   ram: delta=${d_ram}uJ baseline=$(awk "BEGIN {printf \"%.0f\", $taxa_ram * $wall}")uJ net=$(awk "BEGIN {printf \"%.3f\", ($d_ram - $taxa_ram * $wall) / 1e6}")J -> ${j_ram}J"

  # Always recorded; the warning fires only above the threshold so that routine
  # noise is not learned as ignorable. Does not block the run.
  if [ "$swap_out" -gt "$SWAP_WARN_PAGES" ]; then
    echo "   HOST PAGING in stage '$stage': swap_out_pages=$swap_out (swap_in_pages=$swap_in)"
    echo "::warning title=Host paging during measurement::Run $RUN_NUM, stage '$stage': swap_out_pages=$swap_out (> $SWAP_WARN_PAGES pages = $((SWAP_WARN_PAGES*4/1024)) MiB). The host was under memory pressure during the measured window (the container itself cannot page: memory.swap.max=0). Run suspect due to I/O contention; review before including it in the valid set."
  elif [ "$swap_out" -gt 0 ]; then
    echo "   swap_out_pages=$swap_out (below the $SWAP_WARN_PAGES threshold; noise, no alert)"
  fi

  echo "$RUN_NUM,$stage,$j_pkg,$j_cores,$j_gpu,$j_ram,$wall,$user_t,$sys_t,$j_ram_raw,$wall_container_t,$swap_in,$swap_out,$cpu_cgroup_t" >> "$CSV_FILE"

  total_pkg=$(awk   "BEGIN {printf \"%.6f\", $total_pkg   + $j_pkg}")
  total_cores=$(awk "BEGIN {printf \"%.6f\", $total_cores + $j_cores}")
  total_gpu=$(awk   "BEGIN {printf \"%.6f\", $total_gpu   + $j_gpu}")
  total_ram=$(awk   "BEGIN {printf \"%.6f\", $total_ram   + $j_ram}")
  total_ram_raw=$(awk "BEGIN {printf \"%.6f\", $total_ram_raw + $j_ram_raw}")
  total_wall=$(awk  "BEGIN {printf \"%.3f\", $total_wall  + $wall}")
  total_user=$(awk  "BEGIN {printf \"%.3f\", $total_user  + $user_t}")
  total_sys=$(awk   "BEGIN {printf \"%.3f\", $total_sys   + $sys_t}")
  total_wall_container=$(awk "BEGIN {printf \"%.3f\", $total_wall_container + $wall_container_t}")
  total_swap_in=$(( total_swap_in + swap_in ))
  total_swap_out=$(( total_swap_out + swap_out ))
  total_cpu_cgroup=$(awk "BEGIN {printf \"%.3f\", $total_cpu_cgroup + $cpu_cgroup_t}")

  alertar_user_sys "$stage" "$wall" "$user_t" "$sys_t" "$cpu_cgroup_t"

  echo "   pkg: ${j_pkg}J | cores: ${j_cores}J | ram: ${j_ram}J | wall: ${wall}s | cpu_cgroup: ${cpu_cgroup_t}s | swap_out: ${swap_out}p"

  # Nonzero aborts the run before the next stage; this stage is already recorded.
  [ -n "$RUN_REJEITADA_MOTIVO" ] && return 1
  return 0
}

# `if !` consumes the status without triggering set -e, so the discard block below still runs.
if ! measure_stage build; then
  echo "Run $RUN_NUM aborted after stage 'build'; stage 'test' will NOT run"
elif ! measure_stage test; then
  echo "Run $RUN_NUM aborted after stage 'test'"
fi

# Rejected run: CSV, sidecars and reason moved together, timestamped, to the discard
# directory; it must be repeated under the same number.
if [ -n "$RUN_REJEITADA_MOTIVO" ]; then
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$DESCARTE_DIR"
  NN="$(printf '%02d' "$RUN_NUM")"
  [ -f "$CSV_FILE" ]   && mv -f "$CSV_FILE"   "$DESCARTE_DIR/run_${NN}_${STAMP}.csv"
  [ -f "$EXITS_FILE" ] && mv -f "$EXITS_FILE" "$DESCARTE_DIR/exit_codes_run_${NN}_${STAMP}.txt"
  for st in build test; do
    [ -f "$RESULTS_DIR/temp_run_${NN}_${st}.txt" ] && mv -f "$RESULTS_DIR/temp_run_${NN}_${st}.txt" "$DESCARTE_DIR/temp_run_${NN}_${st}_${STAMP}.txt"
  done
  {
    echo "run:            $RUN_NUM"
    echo "discarded_at:   $STAMP"
    echo "reason:         $RUN_REJEITADA_MOTIVO"
    echo "list_build:     {$(echo $EXIT_ACEITOS_build | tr ' ' ',')}"
    echo "list_test:      {$(echo $EXIT_ACEITOS_test  | tr ' ' ',')}"
    echo "list_source:    pre-registration of this release"
    echo "failed_stages:  ${FAILED_STAGES:-(none recorded)}"
    echo "logs:           $LOGS_DIR/run_${NN}_*.log"
  } > "$DESCARTE_DIR/reason_run_${NN}_${STAMP}.txt"

  echo ""
  echo "-----------------------------------------------------"
  echo "RUN $RUN_NUM REJECTED: $RUN_REJEITADA_MOTIVO"
  echo "   Nothing was written to the official path: $CSV_FILE does not exist."
  echo "   Material preserved in: $DESCARTE_DIR/"
  echo "   This run must be REPEATED (rerun the same number)."
  echo "-----------------------------------------------------"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo ""
      echo "### Run $RUN_NUM REJECTED by exit code"
      echo ""
      echo "- **Reason:** $RUN_REJEITADA_MOTIVO"
      echo "- **Declared list:** \`build\` {$(echo $EXIT_ACEITOS_build | tr ' ' ',')}, \`test\` {$(echo $EXIT_ACEITOS_test | tr ' ' ',')} (pre-registered)"
      echo "- **Official CSV:** NOT written; \`aggregate.py\` cannot see it"
      echo "- **Preserved in:** \`runs/discarded_exit_code/run_${NN}_${STAMP}.csv\`"
      echo "- **Action:** run to be REPEATED. The campaign does not proceed with it."
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  rm -f "$TIME_FILE"
  exit "$EXIT_RUN_REJEITADA"
fi

echo "$RUN_NUM,total,$total_pkg,$total_cores,$total_gpu,$total_ram,$total_wall,$total_user,$total_sys,$total_ram_raw,$total_wall_container,$total_swap_in,$total_swap_out,$total_cpu_cgroup" \
  >> "$CSV_FILE"

echo ""
echo "-----------------------------------------------------"
echo " Run $RUN_NUM finished - $(date '+%H:%M:%S')"
echo " CSV: $CSV_FILE"
echo " Total: pkg=${total_pkg}J | wall=${total_wall}s | cpu_cgroup=${total_cpu_cgroup}s"
if [ "$total_swap_out" -gt "$SWAP_WARN_PAGES" ]; then
  echo " Paging: swap_in=${total_swap_in}p swap_out=${total_swap_out}p (> $SWAP_WARN_PAGES); RUN SUSPECT"
elif [ "$total_swap_out" -gt 0 ]; then
  echo " Negligible paging: swap_out=${total_swap_out}p (threshold $SWAP_WARN_PAGES)"
else
  echo " No paging: swap_in=${total_swap_in}p swap_out=${total_swap_out}p"
fi
echo "-----------------------------------------------------"
echo ""

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<EOF

## Run $RUN_NUM - $PROJECT_NAME

| Stage | pkg (J) | cores (J) | gpu (J) | ram (J) | wall (s) |
|-------|---------|-----------|---------|---------|----------|
$(grep "^$RUN_NUM," "$CSV_FILE" | awk -F',' '{printf "| %s | %s | %s | %s | %s | %s |\n", $2,$3,$4,$5,$6,$7}')
EOF
fi

rm -f "$TIME_FILE"

# Only now, with every CSV row written, is a nonzero stage status propagated.
if [ "$PIPELINE_EXIT" -ne 0 ]; then
  echo "Run $RUN_NUM: stage(s) with nonzero exit: $FAILED_STAGES"
  echo "   Full CSV in $CSV_FILE; exit codes in $EXITS_FILE"
  exit "$PIPELINE_EXIT"
fi
