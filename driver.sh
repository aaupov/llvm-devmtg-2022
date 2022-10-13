#!/bin/bash
BUILD_WARMUP=0
BUILD_RUNS=1

BENCH_WARMUP=0
BENCH_RUNS=1

SCRIPT_DIR=$(dirname "$0")
# Make tmpfs directory and cd into it
TMPDIR=`mktemp -d -p /data`
#sudo mount -t tmpfs -o size=64g none $TMPDIR
cd $TMPDIR
echo $TMPDIR

# Checkout LLVM repo at a known commit (trunk as of 11 Oct 2022)
#git clone https://github.com/llvm/llvm-project
#git clone /data/llvm-project
#pushd llvm-project
#git checkout 41f5bbe18b5b162fe798b933deecc55f7cc29b92
#popd
ln -sf /data/llvm-project llvm-project

# Build different versions of Clang: baseline, +LTO, +PGO, +BOLT
COMMON_CMAKE_ARGS="-GNinja -DCMAKE_BUILD_TYPE=Release -S llvm-project/llvm -DLLVM_ENABLE_LLD=ON -DLLVM_ENABLE_PROJECTS=clang"
# Baseline: two-stage Clang build
BASELINE_ARGS="$COMMON_CMAKE_ARGS -DCLANG_ENABLE_BOOTSTRAP=On"
# ThinLTO: Two-stage + LTO Clang build
LTO_ARGS="$BASELINE_ARGS -DBOOTSTRAP_LLVM_ENABLE_LTO=Thin"
# Instrumentation PGO: Two-stage + PGO build
PGO_ARGS="$BASELINE_ARGS -C llvm-project/clang/cmake/caches/PGO.cmake"
# LTO+PGO: Two-stage + LTO + PGO
LTO_PGO_ARGS="$PGO_ARGS -DPGO_INSTRUMENT_LTO=Thin"

BOLT_CMAKE="llvm-project/clang/cmake/caches/BOLT.cmake"
BOLT_PASSTHRU_ARGS="-DCLANG_BOOTSTRAP_CMAKE_ARGS=\"-C $BOLT_CMAKE\""
BOLT_PGO_CFG="-DPGO_BUILD_CONFIGURATION=$BOLT_CMAKE"

BOLT_BASELINE_ARGS="$BASELINE_ARGS $BOLT_PASSTHRU_ARGS"
BOLT_LTO_ARGS="$LTO_ARGS $BOLT_PASSTHRU_ARGS"
BOLT_PGO_ARGS="$PGO_ARGS $BOLT_PGO_CFG"
BOLT_LTO_PGO_ARGS="$LTO_PGO_ARGS $BOLT_PGO_CFG"

for b in "" BOLT_
do
    for cfg in BASELINE LTO PGO LTO_PGO
    do
        echo $b$cfg
        args=${b}${cfg}_ARGS
        hyperfine --warmup $BUILD_WARMUP --runs $BUILD_RUNS --show-output \
            --export-json ${cfg}_build.json \
            --prepare "rm -rf $cfg && cmake -B $cfg ${!args}" \
            "ninja -C $cfg stage2"
    done
done

# Benchmark these versions of Clang using building Clang as a workload
# (with regular configuration specified by $COMMON_CMAKE_ARGS)

# Intel ADL i7-12700K
export ALL_CPUS="0-19"
CORE_CPUS="0-15"
CORE_CPUS_SMT0=`seq 0 2 14 | paste -sd "," -` #"0,2,4,6,8,10,12,14"
CORE_CPUS_SMT1=`seq 1 2 15 | paste -sd "," -` #"1,3,5,7,9,11,13,15"
ATOM_CPUS="16-19"

# Pin system slices to Atom CPUs, workload slice to Core, disable SMT
SYS_CPUS="$ATOM_CPUS" \
    WORKLOAD_CPUS="$CORE_CPUS_SMT0" \
    WORKLOAD_OFFLINE="$CORE_CPUS_SMT1" \
    $SCRIPT_DIR/cpuset.sh prepare

for cfg in BASELINE LTO PGO LTO_PGO
do
    echo $cfg
    sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
        --service-type=exec --pty --uid=$USER \
    hyperfine --warmup $BENCH_WARMUP --runs $BENCH_RUNS \
        --export-json ${cfg}_run_glc.json --show-output \
        --prepare "rm -rf ${cfg}_run && cmake -B ${cfg}_run $COMMON_CMAKE_ARGS \
        -DCMAKE_C_COMPILER=$TMPDIR/$cfg/bin/clang \
        -DCMAKE_CXX_COMPILER=$TMPDIR/$cfg/bin/clang++" \
        "ninja -C ${cfg}_run clang"

    bcfg=BOLT_${cfg}
    echo $bcfg
    sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
        --service-type=exec --pty --uid=$USER \
    hyperfine --warmup $BENCH_WARMUP --runs $BENCH_RUNS \
        --export-json ${bcfg}_run_glc.json --show-output \
        --prepare "rm -rf ${bcfg}_run && cmake -B ${bcfg}_run $COMMON_CMAKE_ARGS \
        -DCMAKE_C_COMPILER=$TMPDIR/$bcfg/bin/clang-bolt \
        -DCMAKE_CXX_COMPILER=$TMPDIR/$bcfg/bin/clang++-bolt" \
        "ninja -C ${bcfg}_run clang"
done

SYS_CPUS="$ATOM_CPUS" \
    WORKLOAD_CPUS="$CORE_CPUS_SMT0" \
    WORKLOAD_OFFLINE="$CORE_CPUS_SMT1" \
    $SCRIPT_DIR/cpuset.sh undo

# Pin system slices to Core, workload slice to Atom, don't disable anything
SYS_CPUS="$ATOM_CPUS" \
    WORKLOAD_CPUS="$CORE_CPUS" \
    WORKLOAD_OFFLINE="" \
    $SCRIPT_DIR/cpuset.sh prepare

for cfg in BASELINE LTO PGO LTO_PGO
do
    echo $cfg
    sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
        --service-type=exec --pty --uid=$USER \
    hyperfine --warmup $BENCH_WARMUP --runs $BENCH_RUNS \
        --export-json ${cfg}_run_grt.json --show-output \
        --prepare "rm -rf ${cfg}_run && cmake -B ${cfg}_run $COMMON_CMAKE_ARGS \
        -DCMAKE_C_COMPILER=$TMPDIR/${cfg}/bin/clang \
        -DCMAKE_CXX_COMPILER=$TMPDIR/${cfg}/bin/clang++" \
        "ninja -C ${cfg}_run clang"

    bcfg=BOLT_${cfg}
    echo $bcfg
    sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
        --service-type=exec --pty --uid=$USER \
    hyperfine --warmup $BENCH_WARMUP --runs $BENCH_RUNS \
        --export-json ${bcfg}_run_grt.json --show-output \
        --prepare "rm -rf ${bcfg}_run && cmake -B ${bcfg}_run $COMMON_CMAKE_ARGS \
        -DCMAKE_C_COMPILER=$TMPDIR/${bcfg}/bin/clang-bolt \
        -DCMAKE_CXX_COMPILER=$TMPDIR/${bcfg}/bin/clang++-bolt" \
        "ninja -C ${bcfg}_run clang"
done

SYS_CPUS="$ATOM_CPUS" \
    WORKLOAD_CPUS="$CORE_CPUS" \
    WORKLOAD_OFFLINE="" \
    $SCRIPT_DIR/cpuset.sh undo
