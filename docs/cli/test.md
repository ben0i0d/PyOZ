# pyoz test

Build the module and run embedded inline tests.

## Usage

```bash
pyoz test [options]
```

## Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show individual test names and results |
| `-r, --release` | Build in release mode before testing |
| `-h, --help` | Show help message |

## How It Works

1. Builds the module (debug mode by default, release with `-r`)
2. Extracts the embedded test file from the compiled `.so`
3. Validates Python syntax with `py_compile`
4. Runs `python3 -m unittest` on the extracted file

Tests are defined inline in your Zig module using `pyoz.@"test"()` and `pyoz.testRaises()`. See the [Testing Guide](../guide/testing.md) for details on writing tests.

## Output

```bash
pyoz test
```

```
Building mymodule v0.1.0 (Debug)...
  Python 3.10 detected
  Module: src/lib.zig
  Using build.zig

Running tests...

....
----------------------------------------------------------------------
Ran 4 tests in 0.001s

OK
```

With `--verbose`:

```bash
pyoz test -v
```

```
Running tests...

test_add_handles_negatives (zig-out.lib.__pyoz_test.TestMymodule) ... ok
test_add_returns_correct_result (zig-out.lib.__pyoz_test.TestMymodule) ... ok
test_divide_by_zero_raises_valueerror (zig-out.lib.__pyoz_test.TestMymodule) ... ok
test_point_magnitude (zig-out.lib.__pyoz_test.TestMymodule) ... ok

----------------------------------------------------------------------
Ran 4 tests in 0.001s

OK
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed, syntax error in test code, or no tests found |

## No Tests Defined

If your module doesn't have a `.tests` field:

```
No tests found. Add .tests to your pyoz.module() config.
```

---

# pyoz bench

Build the module in release mode and run embedded benchmarks.

## Usage

```bash
pyoz bench [options]
```

## Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |

## How It Works

1. Builds the module in **release mode** (always, for accurate timing)
2. Extracts the embedded benchmark file from the compiled `.so`
3. Validates Python syntax with `py_compile`
4. Runs the benchmark script with `python3`

Each benchmark is timed over 100,000 iterations using Python's `timeit` module.

Benchmarks are defined inline in your Zig module using `pyoz.bench()`. See the [Testing Guide](../guide/testing.md) for details.

## Output

```bash
pyoz bench
```

```
Building mymodule v0.1.0 (Release)...
  Python 3.10 detected
  Module: src/lib.zig
  Using build.zig

Running benchmarks...

Benchmark Results:
------------------------------------------------------------
  add performance                            20,051,810 ops/s
  multiply performance                       20,268,969 ops/s
------------------------------------------------------------
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Benchmarks completed |
| 1 | Syntax error in benchmark code, build failure, or no benchmarks found |

## No Benchmarks Defined

If your module doesn't have a `.benchmarks` field:

```
No benchmarks found. Add .benchmarks to your pyoz.module() config.
```
