# lib/utils/snapshot.zsh
# System state snapshot utilities for before/after comparison

mac_ops_take_snapshot() {
  local disk_usage_pct disk_available mem_total mem_used

  # Get disk usage percentage
  disk_usage_pct=$(mac_ops_get_disk_usage) || disk_usage_pct="0"

  # Get available disk bytes
  disk_available=$(mac_ops_get_disk_available) || disk_available="0"

  # Get total memory
  mem_total=$(sysctl -n hw.memsize 2>/dev/null) || mem_total="0"

  # Get used memory from vm_stat
  mem_used=$(mac_ops_parse_vm_stat) || mem_used="0"

  print -- "$disk_usage_pct $disk_available $mem_used $mem_total"
}

# Helper function to parse vm_stat and calculate used memory
mac_ops_parse_vm_stat() {
  local page_size active wired speculative compressor vm_output

  # Get vm_stat output
  vm_output=$(vm_stat 2>/dev/null) || return 1
  [[ -z "$vm_output" ]] && return 1

  # Extract page size from first line (format: "Mach Virtual Memory Statistics: (page size of XXXX bytes)")
  page_size=$(print -- "$vm_output" | head -1 | grep -oE '[0-9]+' | tail -1) || return 1
  [[ -z "$page_size" ]] && return 1

  # Extract page counts from vm_stat output
  active=$(print -- "$vm_output" | grep "Pages active:" | awk '{print $NF}' | tr -d '.') || active="0"
  wired=$(print -- "$vm_output" | grep "Pages wired down:" | awk '{print $NF}' | tr -d '.') || wired="0"
  speculative=$(print -- "$vm_output" | grep "Pages speculative:" | awk '{print $NF}' | tr -d '.') || speculative="0"
  compressor=$(print -- "$vm_output" | grep "Pages occupied by compressor:" | awk '{print $NF}' | tr -d '.') || compressor="0"

  # Calculate used memory: (active + wired + speculative + compressor) * page_size
  print -- $(( (active + wired + speculative + compressor) * page_size ))
}
