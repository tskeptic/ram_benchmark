#!/bin/bash

# RAM Performance Benchmark Script
# Runs multiple test variations and outputs results in JSONL format

set -euo pipefail

# Configuration
RESULTS_DIR="results"
TIMESTAMP_FORMAT="%Y%m%d_%H%M%S"
TEST_SIZES_MB=(100 500 1000 2000 4000)
TEST_PATTERNS=("sequential" "random" "mixed")
TEST_ITERATIONS=3

# Demo mode configuration (used when --demo flag is passed)
DEMO_SIZES_MB=(10)  # Just 10MB to test quickly
DEMO_PATTERNS=("sequential" "random" "mixed")
DEMO_ITERATIONS=1
DEMO_MODE=0  # Set to 1 when --demo is passed

# Temporary directory for test files. If RAM_BENCH_TMP_DIR env var is set it will be used.
# Otherwise the script prefers a RAM-backed path like /dev/shm. If running as root
# and no suitable RAM-backed path exists it will attempt to mount a tmpfs at
# /mnt/ram_benchmark. Fallback is /tmp with a warning (may be disk-backed).
TMP_DIR="${RAM_BENCH_TMP_DIR:-}"
MOUNTED_TMPFS=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

# Function to get RAM hardware information
get_ram_info() {
    local ram_info=""
    
    # Get memory information from /proc/meminfo
    local total_mem=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
    local available_mem=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')

    # Get memory clock information from multiple sources
    local memory_speed=""
    
    # Try dmidecode first (most reliable for RAM speed)
    if command -v dmidecode >/dev/null 2>&1; then
        memory_speed=$(sudo dmidecode -t memory 2>/dev/null | grep -E "Speed.*MHz|Configured Memory Speed.*MHz" | sed -E 's/.*[Ss]peed[^0-9]*([0-9]+)MHz.*/\1MHz/' | head -3 | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/  */ /g')
    fi
    
    # If dmidecode didn't work, try lshw with sudo
    if [[ -z "$memory_speed" ]] && command -v lshw >/dev/null 2>&1; then
        memory_speed=$(sudo lshw -class memory 2>/dev/null | grep -E "clock.*MHz|speed.*MHz" | grep -v "cache" | grep -E "[0-9]{4}MHz" | sed -E 's/.*clock: ([0-9]+)MHz.*/\1MHz/' | head -1 | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/  */ /g')
    fi
    
    # If still no luck, try /proc/cpuinfo for memory info
    if [[ -z "$memory_speed" ]]; then
        memory_speed=$(grep -i "memory\|ram" /proc/cpuinfo 2>/dev/null | head -2 | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/  */ /g')
    fi
    
    # Last resort: try to get from /sys/devices/system/memory
    if [[ -z "$memory_speed" ]]; then
        memory_speed=$(find /sys/devices/system/memory -name "speed" -exec cat {} \; 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/  */ /g')
    fi
    
    ram_info="\"total_memory_kb\": $total_mem, \"available_memory_kb\": $available_mem"

    if [[ -n "$memory_speed" ]]; then
        # Remove trailing whitespace
        memory_speed=$(echo "$memory_speed" | sed 's/[[:space:]]*$//')
        ram_info+=", \"memory_clock_info\": \"$memory_speed\""
    fi
    
    echo "$ram_info"
}

# Function to run memory benchmark test
run_memory_test() {
    local test_size_mb=$1
    local test_pattern=$2
    local iteration=$3
    local system_info=$4
    local test_timestamp=$5
    local test_size_bytes=$((test_size_mb * 1024 * 1024))
    
    log "Running test: ${test_size_mb}MB, pattern: ${test_pattern}, iteration: ${iteration}"
    
    # Create temporary file for testing (placed in chosen TMP_DIR)
    local temp_file="${TMP_DIR%/}/ram_benchmark_${test_size_mb}MB_${test_pattern}_${iteration}"
    
    # Initialize result object with system info
    local result="{\"timestamp\": \"$test_timestamp\", \"test_type\": \"memory\", \"test_size_mb\": $test_size_mb, \"test_pattern\": \"$test_pattern\", \"iteration\": $iteration, $system_info"
    
    # Test 1: Sequential Write
    local write_start=$(date +%s.%N)
    if [[ "$test_pattern" == "sequential" ]]; then
        dd if=/dev/zero of="$temp_file" bs=1M count=$test_size_mb 2>/dev/null
    elif [[ "$test_pattern" == "random" ]]; then
        dd if=/dev/urandom of="$temp_file" bs=1M count=$test_size_mb 2>/dev/null
    else  # mixed
        # Write half sequential, half random
        dd if=/dev/zero of="$temp_file" bs=1M count=$((test_size_mb/2)) 2>/dev/null
        dd if=/dev/urandom of="$temp_file" bs=1M seek=$((test_size_mb/2)) count=$((test_size_mb/2)) 2>/dev/null
    fi
    local write_end=$(date +%s.%N)
    local write_time=$(echo "$write_end - $write_start" | bc -l | awk '{printf "%.9f", $0}')
    local write_speed=$(echo "scale=2; $test_size_mb / $write_time" | bc -l | awk '{printf "%.2f", $0}')
    
    result+=", \"write_time_seconds\": $write_time, \"write_speed_mb_per_sec\": $write_speed"
    
    # Test 2: Sequential Read
    local read_start=$(date +%s.%N)
    dd if="$temp_file" of=/dev/null bs=1M 2>/dev/null
    local read_end=$(date +%s.%N)
    local read_time=$(echo "$read_end - $read_start" | bc -l | awk '{printf "%.9f", $0}')
    local read_speed=$(echo "scale=2; $test_size_mb / $read_time" | bc -l | awk '{printf "%.2f", $0}')
    
    result+=", \"read_time_seconds\": $read_time, \"read_speed_mb_per_sec\": $read_speed"
    
    # Test 3: Random Access Read (using fio if available, otherwise fallback)
    local random_read_time="null"
    local random_read_speed="null"
    
    if command -v fio >/dev/null 2>&1; then
        local fio_config="${TMP_DIR%/}/fio_config_${test_size_mb}MB_${test_pattern}_${iteration}"
        cat > "$fio_config" << EOF
[randomread]
filename=$temp_file
rw=randread
bs=4k
size=${test_size_mb}M
direct=1
ioengine=mmap
runtime=10
time_based=1
EOF
        local fio_output=$(fio "$fio_config" 2>/dev/null | grep -E "read:|IOPS|bw=" | tail -3)
        local fio_bw=$(echo "$fio_output" | grep "bw=" | sed 's/.*bw=\([0-9.]*[KMGT]*B/s\).*/\1/' | sed 's/KB/s/000/' | sed 's/MB/s/000000/' | sed 's/GB/s/000000000/' | sed 's/TB/s/000000000000/')
        if [[ -n "$fio_bw" ]]; then
            random_read_speed=$(echo "scale=2; $fio_bw / 1024 / 1024" | bc -l)
        fi
        rm -f "$fio_config"
    else
        # Fallback: simple random read test
        local random_read_start=$(date +%s.%N)
        for i in $(seq 1 100); do
            local offset=$((RANDOM % (test_size_mb * 1024 - 1024)))
            dd if="$temp_file" of=/dev/null bs=1k skip=$offset count=1 2>/dev/null
        done
        local random_read_end=$(date +%s.%N)
        random_read_time=$(echo "$random_read_end - $random_read_start" | bc -l | awk '{printf "%.9f", $0}')
        random_read_speed=$(echo "scale=2; 100 / $random_read_time" | bc -l | awk '{printf "%.2f", $0}')
    fi
    
    result+=", \"random_read_time_seconds\": $random_read_time, \"random_read_speed_mb_per_sec\": $random_read_speed"
    
    # Test 4: Memory bandwidth test (using simple operations)
    local bandwidth_start=$(date +%s.%N)
    local test_data_size=$((test_size_mb / 10))  # Use 10% of test size for bandwidth test
    local bandwidth_file="${TMP_DIR%/}/bandwidth_test_${test_size_mb}MB_${test_pattern}_${iteration}"
    
    # Create test data
    dd if=/dev/zero of="$bandwidth_file" bs=1M count=$test_data_size 2>/dev/null
    
    # Perform memory operations
    for i in $(seq 1 10); do
        cp "$bandwidth_file" "${bandwidth_file}.copy"
        mv "${bandwidth_file}.copy" "$bandwidth_file"
    done
    
    local bandwidth_end=$(date +%s.%N)
    local bandwidth_time=$(echo "$bandwidth_end - $bandwidth_start" | bc -l | awk '{printf "%.9f", $0}')
    local bandwidth_speed=$(echo "scale=2; ($test_data_size * 20) / $bandwidth_time" | bc -l | awk '{printf "%.2f", $0}')  # 20 = 10 iterations * 2 operations per iteration
    
    result+=", \"bandwidth_time_seconds\": $bandwidth_time, \"bandwidth_speed_mb_per_sec\": $bandwidth_speed"
    
    # Cleanup
    rm -f "$temp_file" "$bandwidth_file"
    
    result+="}"
    echo "$result"
}

# Function to run latency test
run_latency_test() {
    local test_size_mb=$1
    local iteration=$2
    local system_info=$3
    local test_timestamp=$4
    
    log "Running latency test: ${test_size_mb}MB, iteration: ${iteration}"
    
    local temp_file="${TMP_DIR%/}/latency_test_${test_size_mb}MB_${iteration}"
    local test_size_bytes=$((test_size_mb * 1024 * 1024))
    
    # Create test file
    dd if=/dev/zero of="$temp_file" bs=1M count=$test_size_mb 2>/dev/null
    
    local result="{\"timestamp\": \"$test_timestamp\", \"test_type\": \"latency\", \"test_size_mb\": $test_size_mb, \"iteration\": $iteration, $system_info"
    
    # Measure small read latencies
    local latency_times=()
    for i in $(seq 1 1000); do
        local offset=$((RANDOM % (test_size_mb * 1024 - 4)))
        local start=$(date +%s.%N)
        dd if="$temp_file" of=/dev/null bs=4 skip=$offset count=1 2>/dev/null
        local end=$(date +%s.%N)
        local latency=$(echo "$end - $start" | bc -l | awk '{printf "%.9f", $0}')
        latency_times+=($latency)
    done
    
    # Calculate statistics
    local total_latency=0
    for latency in "${latency_times[@]}"; do
        total_latency=$(echo "$total_latency + $latency" | bc -l | awk '{printf "%.9f", $0}')
    done
    local avg_latency=$(echo "scale=9; $total_latency / 1000" | bc -l | awk '{printf "%.9f", $0}')
    
    # Sort for median calculation
    IFS=$'\n' sorted_latencies=($(sort -n <<<"${latency_times[*]}"))
    unset IFS
    local median_latency=$(echo "${sorted_latencies[500]}" | awk '{printf "%.9f", $0}')  # Middle value
    
    result+=", \"avg_latency_seconds\": $avg_latency, \"median_latency_seconds\": $median_latency"
    
    # Cleanup
    rm -f "$temp_file"
    
    result+="}"
    echo "$result"
}

# Function to parse sysbench output
parse_sysbench_output() {
    local sysbench_output="$1"
    local prefix="$2"
    
    local total_time=$(echo "$sysbench_output" | grep "total time:" | awk '{print $3}' | sed 's/s$//')
    local transferred=$(echo "$sysbench_output" | grep "transferred" | awk '{print $1}')
    local operations=$(echo "$sysbench_output" | grep "total number of events:" | awk '{print $5}')
    local latency_avg=$(echo "$sysbench_output" | grep -A 5 "Latency (ms):" | grep "avg:" | awk '{print $2}')
    local latency_min=$(echo "$sysbench_output" | grep -A 5 "Latency (ms):" | grep "min:" | awk '{print $2}')
    local latency_max=$(echo "$sysbench_output" | grep -A 5 "Latency (ms):" | grep "max:" | awk '{print $2}')
    local latency_95th=$(echo "$sysbench_output" | grep -A 5 "Latency (ms):" | grep "95th percentile:" | awk '{print $3}')
    local throughput=$(echo "$sysbench_output" | grep "transferred" | awk '{print $4}' | sed 's/(//' | sed 's/MiB\/sec)//')
    
    local result=""
    if [[ -n "$total_time" ]]; then
        result+=", \"${prefix}_total_time_seconds\": $total_time"
    fi
    if [[ -n "$transferred" ]]; then
        result+=", \"${prefix}_transferred_mb\": $transferred"
    fi
    if [[ -n "$operations" ]]; then
        result+=", \"${prefix}_operations\": $operations"
    fi
    if [[ -n "$latency_avg" ]]; then
        result+=", \"${prefix}_latency_avg_ms\": $latency_avg"
    fi
    if [[ -n "$latency_min" ]]; then
        result+=", \"${prefix}_latency_min_ms\": $latency_min"
    fi
    if [[ -n "$latency_max" ]]; then
        result+=", \"${prefix}_latency_max_ms\": $latency_max"
    fi
    if [[ -n "$latency_95th" ]]; then
        result+=", \"${prefix}_latency_95th_ms\": $latency_95th"
    fi
    if [[ -n "$throughput" ]]; then
        result+=", \"${prefix}_throughput_mb_per_sec\": $throughput"
    fi
    
    echo "$result"
}

# Function to run a single sysbench test configuration
run_single_sysbench_test() {
    local test_size_mb=$1
    local iteration=$2
    local system_info=$3
    local test_timestamp=$4
    local block_size=$5
    local oper=$6
    local access_mode=$7
    local threads=$8
    local memory_total_size=$9
    
    if ! command -v sysbench >/dev/null 2>&1; then
        return
    fi
    
    local test_name="sb_${block_size}_${oper}_${access_mode}_t${threads}_${memory_total_size}"
    log "Running sysbench: block=${block_size}, oper=${oper}, mode=${access_mode}, threads=${threads}, memory-total-size=${memory_total_size}"
    
    local sysbench_output=$(sysbench memory \
        --memory-total-size=${memory_total_size} \
        --memory-block-size=${block_size} \
        --memory-oper=${oper} \
        --memory-access-mode=${access_mode} \
        --threads=${threads} \
        run 2>/dev/null)
    
    local result="{\"timestamp\": \"$test_timestamp\", \"test_type\": \"sysbench\", \"test_size_mb\": $test_size_mb, \"iteration\": $iteration, \"block_size\": \"$block_size\", \"operation\": \"$oper\", \"access_mode\": \"$access_mode\", \"threads\": $threads, \"memory_total_size\": \"$memory_total_size\", $system_info"
    
    local parsed_results=$(parse_sysbench_output "$sysbench_output" "sysbench")
    result+="$parsed_results"
    
    result+="}"
    echo "$result"
}

# Function to run enhanced sysbench memory test
run_sysbench_test() {
    local test_size_mb=$1
    local iteration=$2
    local system_info=$3
    local test_timestamp=$4
    local test_count_ref=$5  # Reference to test_count for progress updates
    
    log "Running enhanced sysbench test: ${test_size_mb}MB, iteration: ${iteration}"
    
    if ! command -v sysbench >/dev/null 2>&1; then
        warning "sysbench not available, skipping sysbench test"
        return
    fi
    
    # Test configurations
    local block_sizes=("1K" "1M" "1G")
    local operations=("write" "read")
    local access_modes=("seq" "rnd")
    local thread_counts=(1 10)
    
    # In demo mode, use smaller memory sizes
    local memory_total_sizes
    if [[ $DEMO_MODE -eq 1 ]]; then
        memory_total_sizes=("1G")
        block_sizes=("1K" "1M")  # Skip 1G blocks in demo mode
        thread_counts=(1)  # Only single-threaded in demo mode
    else
        memory_total_sizes=("16G" "160G")
    fi
    
    local sub_test_count=0
    local total_sub_tests=$((${#block_sizes[@]} * ${#operations[@]} * ${#access_modes[@]} * ${#thread_counts[@]} * ${#memory_total_sizes[@]}))
    
    # Run tests with different configurations and output each as separate result
    for memory_total_size in "${memory_total_sizes[@]}"; do
        for block_size in "${block_sizes[@]}"; do
            for oper in "${operations[@]}"; do
                for access_mode in "${access_modes[@]}"; do
                    for threads in "${thread_counts[@]}"; do
                        sub_test_count=$((sub_test_count + 1))
                        log "Progress: ${sub_test_count}/${total_sub_tests} for sysbench test"
                        
                        local single_result=$(run_single_sysbench_test "$test_size_mb" "$iteration" "$system_info" "$test_timestamp" "$block_size" "$oper" "$access_mode" "$threads" "$memory_total_size")
                        echo "$single_result"
                        
                        # Small delay between tests
                        sleep 0.1
                    done
                done
            done
        done
    done
}

# Main execution
main() {
    log "Starting RAM Performance Benchmark"
    local script_start_time=$(date +%s)
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --demo)
                DEMO_MODE=1
                log "Demo mode enabled - running minimal tests"
                TEST_SIZES_MB=("${DEMO_SIZES_MB[@]}")
                TEST_PATTERNS=("${DEMO_PATTERNS[@]}")
                TEST_ITERATIONS=$DEMO_ITERATIONS
                shift
                ;;
            *)
                error "Unknown argument: $1"
                echo "Usage: $0 [--demo]" >&2
                exit 1
                ;;
        esac
    done
    
    # Check dependencies
    if ! command -v bc >/dev/null 2>&1; then
        error "bc calculator is required but not installed. Please install it."
        exit 1
    fi
    
    # Get timestamps for file naming and test data
    local file_timestamp=$(date +"$TIMESTAMP_FORMAT")
    local test_timestamp=$(date -Iseconds)
    
    # Set up results directory and file
    mkdir -p "$RESULTS_DIR"
    local result_file="${RESULTS_DIR}/ram_benchmark_${file_timestamp}.jsonl"
    if [[ $DEMO_MODE -eq 1 ]]; then
        result_file="${RESULTS_DIR}/ram_benchmark_${file_timestamp}_demo.jsonl"
    fi
    
    # Get system information once
    log "Gathering system information..."
    local system_info=$(get_ram_info)

    # Select a RAM-backed temporary directory for test files
    if [[ -z "$TMP_DIR" ]]; then
        # compute maximum test size in MB
        local max_size_mb=0
        for s in "${TEST_SIZES_MB[@]}"; do
            if (( s > max_size_mb )); then
                max_size_mb=$s
            fi
        done

        # Available memory in KB
        local avail_kb=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
        local avail_mb=$((avail_kb / 1024))

        # Prefer /dev/shm if writable and has at least max_size_mb*2 MB free
        if [[ -d /dev/shm && -w /dev/shm ]]; then
            if (( avail_mb >= max_size_mb * 2 )); then
                TMP_DIR="/dev/shm"
                log "Using RAM-backed temp dir: $TMP_DIR (available ${avail_mb}MB)"
            else
                log "/dev/shm available but only ${avail_mb}MB free; required ~${max_size_mb}MB. Will attempt to mount tmpfs if possible."
            fi
        fi

        # If TMP_DIR still empty and running as root, try to mount a tmpfs
        if [[ -z "$TMP_DIR" && $(id -u) -eq 0 ]]; then
            local mount_point="/mnt/ram_benchmark"
            mkdir -p "$mount_point"
            # Mount with double the largest test size to be safe
            local mount_size_mb=$(( (max_size_mb * 2) + 100 ))
            if mountpoint -q "$mount_point"; then
                TMP_DIR="$mount_point"
            else
                if mount -t tmpfs -o size=${mount_size_mb}M tmpfs "$mount_point" 2>/dev/null; then
                    MOUNTED_TMPFS=1
                    TMP_DIR="$mount_point"
                    log "Mounted tmpfs at $mount_point with size ${mount_size_mb}M"
                else
                    warning "Failed to mount tmpfs at $mount_point. Falling back to /tmp if writable."
                fi
            fi
        fi

        # Final fallback: /tmp
        if [[ -z "$TMP_DIR" ]]; then
            TMP_DIR="/tmp"
            warning "No RAM-backed temp directory available; using $TMP_DIR (may be disk-backed). To force RAM-backed path set RAM_BENCH_TMP_DIR or run as root to allow tmpfs mount."
        fi
    else
        log "Using RAM_BENCH_TMP_DIR from environment: $TMP_DIR"
    fi

    # Ensure TMP_DIR exists and is writable
    mkdir -p "$TMP_DIR"
    if [[ ! -w "$TMP_DIR" ]]; then
        error "Temporary directory $TMP_DIR is not writable"
        exit 1
    fi

    # Cleanup mounted tmpfs on exit if we mounted it
    cleanup() {
        local rc=$?
        if [[ $MOUNTED_TMPFS -eq 1 ]]; then
            log "Unmounting tmpfs at /mnt/ram_benchmark"
            umount /mnt/ram_benchmark || warning "Failed to unmount /mnt/ram_benchmark"
            rmdir /mnt/ram_benchmark 2>/dev/null || true
        fi
        exit $rc
    }
    trap cleanup EXIT INT TERM
    
    # Initialize output file (empty, we'll append each result)
    > "$result_file"
    
    local test_count=0
    # Calculate total tests: memory tests + latency tests + enhanced sysbench tests
    # Enhanced sysbench: 3 block sizes × 2 operations × 2 access modes × 2 thread counts × 2 memory total sizes = 48 tests per size per iteration
    local enhanced_sysbench_tests_per_size=$((3 * 2 * 2 * 2 * 2))  # 48 tests
    # Note: sysbench tests now generate 48 separate results each, but we count them as 1 test group
    local total_tests=$((${#TEST_SIZES_MB[@]} * ${#TEST_PATTERNS[@]} * TEST_ITERATIONS + ${#TEST_SIZES_MB[@]} * TEST_ITERATIONS * 2 + ${#TEST_SIZES_MB[@]} * TEST_ITERATIONS))
    
    # Run memory tests
    for size_mb in "${TEST_SIZES_MB[@]}"; do
        for pattern in "${TEST_PATTERNS[@]}"; do
            for iteration in $(seq 1 $TEST_ITERATIONS); do
                test_count=$((test_count + 1))
                log "Progress: $test_count/$total_tests"
                
                local test_result=$(run_memory_test "$size_mb" "$pattern" "$iteration" "$system_info" "$test_timestamp")
                echo "$test_result" >> "$result_file"
                
                # Small delay to prevent system overload
                sleep 0.5
            done
        done
        
        # Run latency test for each size
        for iteration in $(seq 1 $TEST_ITERATIONS); do
            test_count=$((test_count + 1))
            log "Progress: $test_count/$total_tests"
            
            local latency_result=$(run_latency_test "$size_mb" "$iteration" "$system_info" "$test_timestamp")
            echo "$latency_result" >> "$result_file"
            
            sleep 0.5
        done
        
        # Run sysbench test for each size
        for iteration in $(seq 1 $TEST_ITERATIONS); do
            test_count=$((test_count + 1))
            log "Progress: $test_count/$total_tests"
            
            # Run sysbench test and capture all output lines
            while IFS= read -r sysbench_line; do
                if [[ -n "$sysbench_line" ]]; then
                    echo "$sysbench_line" >> "$result_file"
                fi
            done < <(run_sysbench_test "$size_mb" "$iteration" "$system_info" "$test_timestamp" "$test_count")
            
            sleep 0.5
        done
    done
    
    local script_end_time=$(date +%s)
    local script_duration=$((script_end_time - script_start_time))
    success "Benchmark completed! Results saved to: $result_file"
    log "Total tests run: $test_count"
    log "Total duration: ${script_duration} seconds"
    
    # Display summary
    local file_size
    if [[ -f "$result_file" ]]; then
        file_size=$(du -h "$result_file" | cut -f1)
    else
        file_size="0"
    fi
    log "Output file size: $file_size"
    
    if [[ $DEMO_MODE -eq 1 ]]; then
        log "Demo run completed. For full tests, run without --demo flag"
    fi
}

# Run main function
main "$@"