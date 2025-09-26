# RAM Performance Benchmark

This repository contains a simple shell script to run RAM/file-backed memory performance tests and produce JSONL-formatted results.

File: `ram_benchmark.sh`

## What it does

- Runs a set of memory/file I/O tests for different sizes and access patterns.
- Produces JSONL output (`results_ram_benchmark.jsonl` by default), one JSON object per test result.
- Attempts to gather system/RAM information (from `/proc/meminfo`, `dmidecode`, `lshw`, etc.) and embeds this metadata in each result.
- Optionally runs enhanced tests with `sysbench` and `fio` (if installed) for deeper metrics.

Important note: The script now prefers a RAM-backed temporary directory and will try to ensure tests run in RAM when possible.

- If you set the `RAM_BENCH_TMP_DIR` environment variable, the script will use that directory for all temporary test files.
- Otherwise the script prefers `/dev/shm` when it has sufficient free space for the configured tests.
- If you run the script as root and no suitable RAM-backed path exists, it will attempt to mount a tmpfs at `/mnt/ram_benchmark` sized to hold the tests.
- If none of the above are possible the script will fall back to `/tmp` and print a warning (this may be disk-backed).

To explicitly force a RAM-backed path, export the environment variable before running, for example:

```bash
export RAM_BENCH_TMP_DIR=/dev/shm
./ram_benchmark.sh
```

Running as root allows the script to mount a tmpfs automatically if needed.

## Prerequisites

- bash (script is POSIX-ish bash)
- `bc` (required)
- `dd` (coreutils)
- Optional but recommended for richer data:
  - `jq` (for viewing JSON output)
  - `sysbench` (enhanced memory tests)
  - `fio` (random access tests)
  - `dmidecode` and/or `lshw` (for hardware/RAM metadata; may require `sudo`)

Install on Debian/Ubuntu, for example:

```bash
sudo apt update
sudo apt install bc coreutils jq sysbench fio dmidecode lshw -y
```

## Configuration

Open `ram_benchmark.sh` and edit the configuration block at the top of the file. The key variables are:

- `OUTPUT_FILE` – path to the output JSONL file (default `results_ram_benchmark.jsonl`).
- `TEST_SIZES_MB` – array of test sizes in megabytes (default `(100 500 1000 2000 4000)`).
- `TEST_PATTERNS` – access patterns: `sequential`, `random`, `mixed` (default `("sequential" "random" "mixed")`).
- `TEST_ITERATIONS` – how many iterations to run per size/pattern (default `3`).

To change behavior, edit these variables directly in the script. The script does not currently accept command-line flags.

## How to run

Make the script executable and run it:

```bash
chmod +x ram_benchmark.sh
./ram_benchmark.sh
```

If you want `dmidecode`/`lshw` to return detailed data you may need to run with `sudo`:

```bash
sudo ./ram_benchmark.sh
```

Be aware the script performs large writes/reads and will run for longer with bigger sizes or more iterations.

## Output

The script appends one JSON object per test to `results_ram_benchmark.jsonl` (JSON Lines). Each line is a standalone JSON object describing a single test or sub-test. Typical fields you will see include:

- `timestamp` — ISO8601 time when the test started
- `test_type` — (e.g. `latency`, `sysbench`, or omitted for the default memory tests)
- `test_size_mb`, `test_pattern`, `iteration` — the test parameters
- `write_time_seconds`, `write_speed_mb_per_sec`
- `read_time_seconds`, `read_speed_mb_per_sec`
- `random_read_time_seconds`, `random_read_speed_mb_per_sec`
- `bandwidth_time_seconds`, `bandwidth_speed_mb_per_sec`
- `avg_latency_seconds`, `median_latency_seconds` — for latency tests
- `memory_details`, `memory_clock_info`, `total_memory_kb`, `available_memory_kb` — system metadata (may be absent if tools are unavailable)

Example: view first 3 results nicely:

```bash
head -n 3 results_ram_benchmark.jsonl | jq .
```

Compute a simple aggregated average read speed (best-effort):

```bash
jq -s 'map(select(.read_speed_mb_per_sec != null)) | map(.read_speed_mb_per_sec) | add/length' results_ram_benchmark.jsonl
```

## Recommendations & notes

The script attempts to pick a RAM-backed temp directory automatically (see notes above). To force a specific RAM-backed location set the `RAM_BENCH_TMP_DIR` environment variable (for example `export RAM_BENCH_TMP_DIR=/dev/shm`) or run the script as root so it can mount a tmpfs at `/mnt/ram_benchmark`.
- The script uses `dd` to create test files, so results depend on filesystem caching and the underlying device; interpreting the results as "pure RAM bandwidth" depends on where temporary files are stored (RAM vs disk).
- `sysbench` and `fio` provide more controlled measurements; install them if you need more accurate or comparable results.
- Running many large tests may consume CPU and I/O and take a long time. Start with a smaller `TEST_SIZES_MB` and fewer `TEST_ITERATIONS` for a quick smoke test.

## Troubleshooting

- Error: `bc: command not found` — install `bc` (see Prerequisites).
- No `dmidecode` output — try running the script with `sudo`.
- Very low speeds — check whether the chosen temporary directory is disk-backed. If the script printed a warning about falling back to `/tmp`, try running with `RAM_BENCH_TMP_DIR=/dev/shm` or run as root to allow the script to mount a tmpfs at `/mnt/ram_benchmark`.

## Future improvements (suggestions)

- Add CLI flags to override config without editing the script.
- Add an option to specify the temp directory (e.g. `TMP_DIR=/dev/shm`).
- Produce a summarized JSON or CSV report in addition to JSONL.

## License

MIT-style: feel free to reuse and modify.
