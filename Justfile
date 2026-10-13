set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

frontier:
    python3 scripts/next_work.py frontier

next:
    python3 scripts/next_work.py next

fmt:
    cargo fmt --all

build:
    cargo build --workspace --locked

check:
    python3 scripts/verify_toolchain.py
    python3 scripts/guardrail_registry.py --check
    python3 -m py_compile scripts/next_work.py scripts/verify_toolchain.py scripts/guardrail_registry.py scripts/local_ship.py scripts/trace.py tests/test_next_work.py tests/test_repository_contract.py tests/test_guardrail_registry.py tests/test_local_ship.py tests/test_trace.py tests/test_runtime_trace_bundle.py
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets --locked -- -D warnings

test:
    python3 -m unittest discover -s tests -p 'test_*.py'
    cargo test --workspace --locked
    cargo build -p pointer-input-ffi --locked
    cc -std=c11 -Wall -Wextra -Werror -Irust/ffi/include rust/ffi/tests/abi_contract.c -Ltarget/debug -lpointer_input_ffi -Wl,-rpath,"$PWD/target/debug" -o target/abi_contract
    target/abi_contract
    cc -std=c11 -Wall -Wextra -Werror -Imacos/Bridge/CPointerInput macos/Bridge/CPointerInput/test_trace_ring.c -o target/trace_ring_contract
    target/trace_ring_contract
    cc -std=c11 -Wall -Wextra -Werror -pthread -Imacos/Bridge/CPointerInput macos/Bridge/CPointerInput/test_observation_slot.c -o target/observation_slot_contract
    target/observation_slot_contract
    MMF_FFI_PROFILE=debug swift test --package-path macos

ci: check test build

local-candidate:
    python3 scripts/local_ship.py build

local-build:
    just ci
    just local-candidate

hooks-install:
    chmod +x .githooks/pre-commit .githooks/pre-push
    git config core.hooksPath .githooks
    @echo "Installed repository hooks from .githooks"

benchmark:
    cargo build -p pointer-input-ffi --release --locked
    MMF_FFI_PROFILE=release swift run -c release --package-path macos benchmark

benchmark-synthetic:
    cargo build -p pointer-input-ffi --release --locked
    MMF_FFI_PROFILE=release MMF_BENCHMARK_SYNTHETIC=1 swift run -c release --package-path macos benchmark

benchmark-ci:
    cargo build -p pointer-input-ffi --release --locked
    MMF_FFI_PROFILE=release MMF_BENCHMARK_CI=1 swift run -c release --package-path macos benchmark

smoke:
    cargo build -p pointer-input-ffi --locked
    MMF_FFI_PROFILE=debug swift run --package-path macos smoke

macos14-behavior:
    cargo build -p pointer-input-ffi --release --locked
    MMF_FFI_PROFILE=release swift run --package-path macos coherence-check

trace-tail:
    python3 scripts/trace.py tail

trace-export run_id="":
    python3 scripts/trace.py export {{run_id}}

benchmark-trace:
    MMF_TRACE=0 just benchmark
    MMF_TRACE=1 just benchmark

benchmark-trace-synthetic:
    MMF_TRACE=1 just benchmark-synthetic

benchmark-trace-ci:
    MMF_TRACE=1 just benchmark-ci
