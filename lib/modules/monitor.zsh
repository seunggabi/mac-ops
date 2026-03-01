# =============================================================================
# mac-ops: Memory & CPU monitoring module
# 7-day history stored as CSV, CLI table + sparkline visualization
# Process cleanup by memory threshold
# =============================================================================

# --- Config ---
MAC_OPS_MONITOR_DIR="${MAC_OPS_HOME}/monitor"
MAC_OPS_MONITOR_RETENTION_DAYS=${MAC_OPS_MONITOR_RETENTION_DAYS:-7}
MAC_OPS_MONITOR_KILL_THRESHOLD_MB=${MAC_OPS_MONITOR_KILL_THRESHOLD_MB:-500}

# Sparkline chars: index 1..8 (zsh arrays are 1-indexed)
_MAC_OPS_SPARK=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')

# =============================================================================
# Internal helpers
# =============================================================================

# Get memory stats via vm_stat (fast, no external tools needed)
# Outputs: "mem_used_bytes mem_total_bytes mem_pct"
_mac_ops_monitor_mem() {
  local page_size
  page_size=$(pagesize 2>/dev/null || echo 4096)

  local vm_out
  vm_out=$(vm_stat 2>/dev/null)

  # Include speculative pages — consistent with snapshot.zsh formula
  local wired active compressed speculative
  wired=$(awk '/Pages wired down/{gsub(/\./, "", $NF); print $NF+0}' <<< "$vm_out")
  active=$(awk '/Pages active/{gsub(/\./, "", $NF); print $NF+0}' <<< "$vm_out")
  compressed=$(awk '/Pages occupied by compressor/{gsub(/\./, "", $NF); print $NF+0}' <<< "$vm_out")
  speculative=$(awk '/Pages speculative/{gsub(/\./, "", $NF); print $NF+0}' <<< "$vm_out")

  local total used pct
  total=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  used=$(( (wired + active + compressed + speculative) * page_size ))
  pct=$(awk "BEGIN{printf \"%.1f\", ($total>0)?($used/$total*100):0}")

  echo "$used $total $pct"
}

# Get CPU usage % via top (takes ~1 second sample)
# Outputs: "cpu_pct"
# Uses BSD awk-compatible parsing (no gawk extensions)
_mac_ops_monitor_cpu() {
  top -l 2 -n 0 2>/dev/null | awk '
    /CPU usage/ { line=$0 }
    END {
      if (!line) { print "0.0"; exit }
      # "CPU usage: 15.8% user, 5.4% sys, 78.7% idle"
      # Split by space and match tokens following numeric% values
      n = split(line, a, " ")
      user=0; sys=0
      for (i=1; i<=n; i++) {
        if (a[i] ~ /user/) { v=a[i-1]; gsub(/[^0-9.]/, "", v); user=v+0 }
        if (a[i] ~ /sys/)  { v=a[i-1]; gsub(/[^0-9.]/, "", v); sys=v+0 }
      }
      printf "%.1f", user+sys
    }
  '
}

# Get local UTC offset in seconds (handles half-hour timezones like IST +0530)
_mac_ops_monitor_tz_offset() {
  local z
  z=$(date +%z)  # e.g., +0900
  local sign=1
  [[ "${z:0:1}" == "-" ]] && sign=-1
  echo $(( sign * (10#${z:1:2} * 3600 + 10#${z:3:2} * 60) ))
}

# Render sparkline from space-separated float values (0–100 scale)
# Usage: _mac_ops_monitor_sparkline "63.1 70.2 68.5"
_mac_ops_monitor_sparkline() {
  local -a vals=("${(s: :)1}")
  local result=""
  local v idx
  for v in "${vals[@]}"; do
    idx=$(awk "BEGIN{x=int($v/100*7+0.5); print (x>7)?7:(x<0)?0:x}")
    result+="${_MAC_OPS_SPARK[$((idx+1))]}"
  done
  echo "$result"
}

# Render a colored horizontal bar
# Usage: _mac_ops_monitor_bar <pct_float> [width=20]
# (writes directly to stdout with ANSI codes)
_mac_ops_monitor_bar() {
  local pct="${1}"
  local width="${2:-20}"
  local filled
  filled=$(awk "BEGIN{x=int($pct/100*$width+0.5); print (x>$width)?$width:(x<0)?0:x}")
  local empty=$(( width - filled ))

  local red=$'\033[31m' yellow=$'\033[33m' green=$'\033[32m' reset=$'\033[0m'
  local color
  if   awk "BEGIN{exit ($pct < 60)?0:1}"; then color="$green"
  elif awk "BEGIN{exit ($pct < 80)?0:1}"; then color="$yellow"
  else color="$red"
  fi

  printf "%s" "$color"
  local i
  for (( i=0; i<filled; i++ )); do printf "█"; done
  for (( i=0; i<empty; i++ )); do printf "░"; done
  printf "%s" "$reset"
}

# Get daily averages from a day's CSV
# Usage: _mac_ops_monitor_daily_stats <YYYY-MM-DD>
# Outputs: "mem_avg cpu_avg count"
_mac_ops_monitor_daily_stats() {
  local csv="${MAC_OPS_MONITOR_DIR}/${1}.csv"
  [[ ! -f "$csv" ]] && echo "0 0 0" && return
  awk -F',' '
    NR>1 && NF>=5 && $4+0>0 {m+=$4; c+=$5; n++}
    END {printf "%.1f %.1f %d\n", (n>0)?m/n:0, (n>0)?c/n:0, n+0}
  ' "$csv"
}

# Get hourly averages for a day (24 lines: "HH mem_avg cpu_avg")
# Usage: _mac_ops_monitor_hourly_stats <YYYY-MM-DD>
_mac_ops_monitor_hourly_stats() {
  local csv="${MAC_OPS_MONITOR_DIR}/${1}.csv"
  if [[ ! -f "$csv" ]]; then
    local h
    for h in $(seq 0 23); do printf "%02d 0 0\n" "$h"; done
    return
  fi
  local tz_offset
  tz_offset=$(_mac_ops_monitor_tz_offset)
  awk -F',' -v tz="$tz_offset" '
    NR>1 && NF>=5 && $1+0>0 {
      h = int(($1 + tz) / 3600) % 24
      if (h < 0) h += 24
      key = sprintf("%02d", h)
      ms[key]+=$4; cs[key]+=$5; cnt[key]++
    }
    END {
      for (h=0; h<24; h++) {
        key=sprintf("%02d",h)
        if (key in cnt) printf "%s %.1f %.1f\n", key, ms[key]/cnt[key], cs[key]/cnt[key]
        else             printf "%s 0 0\n", key
      }
    }
  ' "$csv" | sort
}

# Purge CSV files older than retention period
_mac_ops_monitor_purge_old() {
  local cutoff=$(( $(date +%s) - MAC_OPS_MONITOR_RETENTION_DAYS * 86400 ))
  local f fname epoch
  # shellcheck disable=SC1036,SC1058,SC1072,SC1073
  for f in "${MAC_OPS_MONITOR_DIR}"/*.csv(N); do
    fname=$(basename "$f" .csv)
    epoch=$(date -j -f '%Y-%m-%d' "$fname" +%s 2>/dev/null || echo 0)
    if [[ $epoch -gt 0 && $epoch -lt $cutoff ]]; then
      rm -f "$f"
      mac_ops_log_debug "Monitor: purged old file $f"
    fi
  done
}

# =============================================================================
# Public: collect snapshot
# Designed to be called from launchd or cron (e.g., every 5 minutes)
# =============================================================================
mac_ops_monitor_collect() {
  mkdir -p "${MAC_OPS_MONITOR_DIR}"

  local ts mem_used mem_total mem_pct cpu_pct
  ts=$(date +%s)
  read -r mem_used mem_total mem_pct <<< "$(_mac_ops_monitor_mem)"
  cpu_pct=$(_mac_ops_monitor_cpu)

  local date_str csv
  date_str=$(date '+%Y-%m-%d')
  csv="${MAC_OPS_MONITOR_DIR}/${date_str}.csv"

  [[ ! -f "$csv" ]] && echo "timestamp,mem_used,mem_total,mem_pct,cpu_pct" > "$csv"
  echo "${ts},${mem_used},${mem_total},${mem_pct},${cpu_pct}" >> "$csv"

  _mac_ops_monitor_purge_old
  mac_ops_log_debug "Monitor: snapshot saved (mem=${mem_pct}%, cpu=${cpu_pct}%)"
}

# =============================================================================
# Internal: show top N processes by memory
# =============================================================================
_mac_ops_monitor_show_top() {
  local limit="${1:-10}"
  local red=$'\033[31m' yellow=$'\033[33m' reset=$'\033[0m'

  printf "\033[1m◉ Top %d Processes by Memory\033[0m\n" "$limit"
  printf "  %s\n" "──────────────────────────────────────────────────────────────────────"
  printf "  %-8s %-36s %10s %8s\n" "PID" "PROCESS" "MEMORY" "CPU%"
  printf "  %s\n" "──────────────────────────────────────────────────────────────────────"

  ps -eo pid,rss,pcpu,comm= | tail -n +2 | sort -k2 -rn | \
  awk -v limit="$limit" -v red="$red" -v yellow="$yellow" -v rst="$reset" '
    count < limit && $2 > 0 {
      pid=$1; rss=$2; cpu=$3; cmd=$4
      n=split(cmd, p, "/"); short=p[n]
      mem_mb = rss / 1024
      color = (mem_mb >= 2048) ? red : (mem_mb >= 512) ? yellow : rst
      if (mem_mb >= 1024)
        printf "  %-8s %s%-36s%s %7.1f GB %7.1f%%\n", pid, color, short, rst, mem_mb/1024, cpu
      else
        printf "  %-8s %s%-36s%s %7.1f MB %7.1f%%\n", pid, color, short, rst, mem_mb, cpu
      count++
    }
  '
  echo ""
  printf "  \033[2mTip: 'mac-ops monitor kill [MB]' to terminate high-memory processes\033[0m\n"
  echo ""
}

# =============================================================================
# Public: display monitoring dashboard
# Usage: mac_ops_monitor_show [--hours]
# =============================================================================
mac_ops_monitor_show() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  local show_hours=false
  [[ "${1}" == "--hours" || "${1}" == "-h" ]] && show_hours=true

  mac_ops_print_header "       mac-ops Resource Monitor"

  # ── Current Status ─────────────────────────────────────────────────────────
  printf "\033[1m◉ Current Status\033[0m  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "  %s\n" "──────────────────────────────────────────────────"

  local mem_used mem_total mem_pct
  read -r mem_used mem_total mem_pct <<< "$(_mac_ops_monitor_mem)"
  local mem_used_fmt mem_total_fmt
  mem_used_fmt=$(mac_ops_format_bytes "$mem_used")
  mem_total_fmt=$(mac_ops_format_bytes "$mem_total")

  printf "  Memory  ["
  _mac_ops_monitor_bar "$mem_pct" 20
  printf "]  %5.1f%%  %s / %s\n" "$mem_pct" "$mem_used_fmt" "$mem_total_fmt"

  printf "  CPU     ["
  local cpu_pct
  cpu_pct=$(_mac_ops_monitor_cpu)
  _mac_ops_monitor_bar "$cpu_pct" 20
  printf "]  %5.1f%%\n" "$cpu_pct"

  echo ""

  # ── 7-Day History ──────────────────────────────────────────────────────────
  local no_data=true
  printf "\033[1m◉ 7-Day History\033[0m"
  if [[ "$show_hours" == true ]]; then
    printf "  \033[2m(hourly sparkline, 00:00→23:00)\033[0m"
  fi
  echo ""
  printf "  %s\n" "──────────────────────────────────────────────────────────────────────"

  if [[ "$show_hours" == true ]]; then
    printf "  %-12s  %7s  %7s  %s\n" "DATE" "MEM AVG" "CPU AVG" "MEMORY (24h)"
  else
    printf "  %-12s  %7s  %7s  %5s  %5s\n" "DATE" "MEM AVG" "CPU AVG" "MEM" "CPU"
  fi
  printf "  %s\n" "──────────────────────────────────────────────────────────────────────"

  local -a daily_mem_avgs daily_cpu_avgs
  local today_str
  today_str=$(date '+%Y-%m-%d')

  # Declare all loop variables once outside the loop to avoid zsh re-declaration output
  local i date_str day_label mem_avg cpu_avg count today_marker
  local spark mspark cspark hh hmem hcpu
  local -a hour_mem_vals

  for (( i = MAC_OPS_MONITOR_RETENTION_DAYS - 1; i >= 0; i-- )); do
    if [[ $i -eq 0 ]]; then
      date_str=$(date '+%Y-%m-%d')
      day_label=$(date '+%m/%d %a')
    else
      date_str=$(date -v -${i}d '+%Y-%m-%d')
      day_label=$(date -v -${i}d '+%m/%d %a')
    fi

    read -r mem_avg cpu_avg count <<< "$(_mac_ops_monitor_daily_stats "$date_str")"
    daily_mem_avgs+=("$mem_avg")
    daily_cpu_avgs+=("$cpu_avg")

    today_marker=""
    [[ "$date_str" == "$today_str" ]] && today_marker=$'\033[2m ← today\033[0m'

    if [[ "$count" -eq 0 ]]; then
      if [[ "$show_hours" == true ]]; then
        printf "  %-12s  %7s  %7s  %s\n" "$day_label" "--" "--" "(no data)"
      else
        printf "  %-12s  %7s  %7s  %5s  %5s\n" "$day_label" "--" "--" "" ""
      fi
      continue
    fi

    no_data=false

    if [[ "$show_hours" == true ]]; then
      hour_mem_vals=()
      while IFS=' ' read -r hh hmem hcpu; do
        hour_mem_vals+=("$hmem")
      done < <(_mac_ops_monitor_hourly_stats "$date_str")
      spark=$(_mac_ops_monitor_sparkline "${hour_mem_vals[*]}")
      printf "  %-12s  %6.1f%%  %6.1f%%  %s%b\n" \
        "$day_label" "$mem_avg" "$cpu_avg" "$spark" "$today_marker"
    else
      mspark=$(_mac_ops_monitor_sparkline "$mem_avg")
      cspark=$(_mac_ops_monitor_sparkline "$cpu_avg")
      printf "  %-12s  %6.1f%%  %6.1f%%  %5s  %5s%b\n" \
        "$day_label" "$mem_avg" "$cpu_avg" "$mspark" "$cspark" "$today_marker"
    fi
  done

  echo ""
  if [[ "$no_data" == false ]]; then
    printf "  Memory 7-day trend: %s\n" "$(_mac_ops_monitor_sparkline "${daily_mem_avgs[*]}")"
    printf "  CPU    7-day trend: %s\n" "$(_mac_ops_monitor_sparkline "${daily_cpu_avgs[*]}")"
    echo ""
    if [[ "$show_hours" == false ]]; then
      printf "  \033[2mTip: 'mac-ops monitor --hours' for hourly sparkline view\033[0m\n"
    fi
  else
    printf "  \033[2mNo history data yet. Run 'mac-ops monitor collect' to start recording.\033[0m\n"
    printf "  \033[2mFor automatic collection, see: mac-ops monitor setup\033[0m\n"
  fi
  echo ""

  # ── Top Processes ──────────────────────────────────────────────────────────
  _mac_ops_monitor_show_top 10
}

# =============================================================================
# Public: show top processes by memory
# Usage: mac_ops_monitor_top [N]
# =============================================================================
mac_ops_monitor_top() {
  local limit="${1:-10}"
  mac_ops_print_header "       mac-ops Top Processes"
  _mac_ops_monitor_show_top "$limit"
}

# =============================================================================
# Public: kill high-memory processes interactively
# Usage: mac_ops_monitor_kill [threshold_MB]
# =============================================================================
mac_ops_monitor_kill() {
  local threshold_mb="${1:-${MAC_OPS_MONITOR_KILL_THRESHOLD_MB}}"

  mac_ops_print_header "       mac-ops Process Cleanup"

  local proc_list
  proc_list=$(
    ps -eo pid,rss,pcpu,comm= | tail -n +2 | sort -k2 -rn | \
    awk -v thresh="$((threshold_mb * 1024))" '
      $2 >= thresh && $2 > 0 {
        pid=$1; rss=$2; cpu=$3; cmd=$4
        n=split(cmd, p, "/"); short=p[n]
        printf "%s %.1f %.1f %s\n", pid, rss/1024, cpu, short
      }
    '
  )

  if [[ -z "${proc_list}" ]]; then
    printf "  \033[32m✓\033[0m No processes using more than %d MB\n\n" "$threshold_mb"
    return 0
  fi

  printf "\033[1m◉ Processes using more than %d MB\033[0m\n" "$threshold_mb"
  printf "  %s\n" "──────────────────────────────────────────────────────────────────────"
  printf "  %-8s %-36s %10s %8s\n" "PID" "PROCESS" "MEMORY" "CPU%"
  printf "  %s\n" "──────────────────────────────────────────────────────────────────────"

  local -a candidate_pids
  local pid mem_mb cpu cmd
  while IFS=' ' read -r pid mem_mb cpu cmd; do
    if awk "BEGIN{exit ($mem_mb >= 1024)?0:1}"; then
      local gb
      gb=$(awk "BEGIN{printf \"%.1f\", $mem_mb/1024}")
      printf "  %-8s \033[33m%-36s\033[0m %7s GB %7.1f%%\n" "$pid" "$cmd" "$gb" "$cpu"
    else
      printf "  %-8s %-36s %7.1f MB %7.1f%%\n" "$pid" "$cmd" "$mem_mb" "$cpu"
    fi
    candidate_pids+=("$pid")
  done <<< "$proc_list"

  echo ""
  printf "  Enter PID to kill, \033[1mall\033[0m for all listed, or \033[1mq\033[0m to quit: "

  local input
  if ! read -r input 2>/dev/null; then
    echo ""
    return 0
  fi

  case "${input}" in
    q|Q|"")
      return 0
      ;;
    all|ALL)
      local p
      for p in "${candidate_pids[@]}"; do
        local pname
        pname=$(ps -p "$p" -o comm= 2>/dev/null | awk -F/ '{print $NF}')
        if mac_ops_is_process_protected "${pname}" 2>/dev/null; then
          printf "  \033[33m⚠\033[0m  Skipping protected process: %s (PID %s)\n" "$pname" "$p"
        elif kill -15 "$p" 2>/dev/null; then
          printf "  \033[32m✓\033[0m  SIGTERM sent to %s (PID %s)\n" "${pname:-unknown}" "$p"
        else
          printf "  \033[31m✗\033[0m  Failed to kill PID %s (try with sudo)\n" "$p"
        fi
      done
      ;;
    *)
      if [[ "${input}" =~ ^[0-9]+$ ]]; then
        local pname
        pname=$(ps -p "$input" -o comm= 2>/dev/null | awk -F/ '{print $NF}')
        if mac_ops_is_process_protected "${pname}" 2>/dev/null; then
          printf "  \033[33m⚠\033[0m  Skipping protected process: %s (PID %s)\n" "$pname" "$input"
        elif kill -15 "$input" 2>/dev/null; then
          printf "  \033[32m✓\033[0m  SIGTERM sent to %s (PID %s)\n" "${pname:-unknown}" "$input"
        else
          printf "  \033[31m✗\033[0m  Failed to kill PID %s (try with sudo)\n" "$input"
        fi
      else
        printf "  \033[31m✗\033[0m  Invalid input: %s\n" "$input"
      fi
      ;;
  esac
  echo ""
}
