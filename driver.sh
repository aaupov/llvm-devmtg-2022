#!/bin/bash
BENCH_RUNS=5
USE_PERF=1

SCRIPT_DIR=$(dirname `realpath "$0"`)
LLVM_SRC=${LLVM_SOURCE:-https://github.com/llvm/llvm-project}

# Make tmpfs directory and cd into it
TMPDIR=`mktemp -d`
cd $TMPDIR
echo $TMPDIR

# Checkout LLVM repo at a known commit
git clone "$LLVM_SRC"
pushd llvm-project
# Trunk as of Oct 23, 2022
git checkout e98501e27ed9ae9ceeaf80eac84d408c2ce4cd72
popd

# Cmake configuration for benchmarking
CMAKE_ARGS="-S llvm-project/llvm -GNinja -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD=Native"
# Build different versions of Clang: baseline, +LTO, +PGO, +BOLT
COMMON_CMAKE_ARGS="-S llvm-project/llvm -GNinja -DCMAKE_BUILD_TYPE=Release
    -DLLVM_ENABLE_PROJECTS=bolt;clang;lld -DLLVM_TARGETS_TO_BUILD=Native
    -DBOOTSTRAP_LLVM_ENABLE_LLD=ON -DBOOTSTRAP_BOOTSTRAP_LLVM_ENABLE_LLD=ON
    -DLLVM_CCACHE_BUILD=ON"
# Baseline: two-stage Clang build
BASELINE_ARGS="$COMMON_CMAKE_ARGS -DCLANG_ENABLE_BOOTSTRAP=On
  -DCLANG_BOOTSTRAP_TARGETS=clang"
# ThinLTO: Two-stage + LTO Clang build
LTO_ARGS="$BASELINE_ARGS -DBOOTSTRAP_LLVM_ENABLE_LTO=Thin"
# Instrumentation PGO: Two-stage + PGO build
PGO_ARGS="$BASELINE_ARGS -DBOOTSTRAP_CLANG_BOOTSTRAP_TARGETS=clang
  -DCLANG_BOOTSTRAP_TARGETS=stage2-clang
  -C llvm-project/clang/cmake/caches/PGO.cmake"
# LTO+PGO: Two-stage + LTO + PGO
LTO_PGO_ARGS="-DPGO_INSTRUMENT_LTO=Thin $PGO_ARGS"

BOLT_CMAKE="llvm-project/clang/cmake/caches/BOLT.cmake"
BOLT_PGO_CMAKE="llvm-project/clang/cmake/caches/BOLT-PGO.cmake"
BOLT_PASSTHRU_ARGS="-DCLANG_BOOTSTRAP_CMAKE_ARGS=-C../../../../$BOLT_CMAKE
  -DCLANG_BOOTSTRAP_TARGETS=clang++-bolt"

BOLT_BASELINE_ARGS="$BASELINE_ARGS $BOLT_PASSTHRU_ARGS"
BOLT_LTO_ARGS="$LTO_ARGS $BOLT_PASSTHRU_ARGS"
BOLT_PGO_ARGS="$COMMON_CMAKE_ARGS -C $BOLT_PGO_CMAKE"
BOLT_LTO_PGO_ARGS="-DBOOTSTRAP_LLVM_ENABLE_LLD=ON -DPGO_INSTRUMENT_LTO=Thin $BOLT_PGO_ARGS"

build () {
    for cfg in BASELINE LTO PGO LTO_PGO
    do
        bcfg=BOLT_$cfg
        echo $bcfg
        args=${bcfg}_ARGS
        cmake -B $bcfg ${!args} |& tee ${bcfg}_build.log
        ninja -C $bcfg stage2-clang++-bolt |& tee -a ${bcfg}_build.log
    done
}

# Benchmark these versions of Clang using building Clang as a workload
# (with regular configuration specified by $CMAKE_ARGS)

bench () {
    cfg=$1
    hwname=$2
    RUNDIR=$3
    echo $cfg

    clang_dir=`dirname $(find $TMPDIR/BOLT_$cfg -name clang-bolt)`
    CC=$clang_dir/clang
    CXX=$clang_dir/clang++

    log=${cfg}_${hwname}_run

    for b in "" BOLT_
    do
        if [[ -n $b ]]; then
            CC=$CC-bolt
            CXX=$CXX-bolt
        fi
        rm -rf $RUNDIR/CMakeCache.txt $RUNDIR/CMakeFiles
        cmake -B $RUNDIR $CMAKE_ARGS -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX

        sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
            --service-type=exec --pty --uid=$USER \
            perf stat -r$BENCH_RUNS -o $b$log.txt \
            -e instructions,cycles,L1-icache-misses,iTLB-misses \
            --pre "ninja -C $RUNDIR clean" -- \
            ninja -C $RUNDIR clang
    done
}

run () {
    sudo bash -x $SCRIPT_DIR/cpuset.sh prepare $ALL_CPUS $SYS_CPUS $WORKLOAD_CPUS $WORKLOAD_OFFLINE

    RUNDIR=`mktemp -d`
    sudo mount -t tmpfs -o size=10g none $RUNDIR

    for cfg in BASELINE LTO PGO LTO_PGO
    do
        echo $1
        bench $cfg $1 $RUNDIR
    done

    sudo bash -x $SCRIPT_DIR/cpuset.sh undo $ALL_CPUS $SYS_CPUS $WORKLOAD_CPUS $WORKLOAD_OFFLINE
    sudo umount $RUNDIR
}

# Main entry point
build
for i in "$@"
do
    case "$i" in
        BDW)
            # Intel BDW E5-2680v4
            ALL_CPUS="0-55" \
                SYS_CPUS="0-13,28-41" \
                WORKLOAD_CPUS="14-27" \
                WORKLOAD_OFFLINE=$(seq 42 55) \
                run BDW
            ;;

        GLC)
            # Intel ADL i7-12700K
            CORE_CPUS="$(seq 0 15)"
            CORE_CPUS_SMT0=`seq 0 2 14 | paste -sd "," -` #"0,2,4,6,8,10,12,14"
            CORE_CPUS_SMT1=$(seq 1 2 15) # | paste -sd "," -` #"1,3,5,7,9,11,13,15"
            ATOM_CPUS="16-19"
            # Pin system slices to Atom CPUs, workload slice to Core, disable SMT
            ALL_CPUS="0-19" \
                SYS_CPUS="$ATOM_CPUS" \
                WORKLOAD_CPUS="$CORE_CPUS_SMT0" \
                WORKLOAD_OFFLINE="$CORE_CPUS_SMT1" \
                run GLC
            ;;

        GRT)
            # Intel ADL i7-12700K
            CORE_CPUS="0-15"
            ATOM_CPUS="16-19"
            # Pin system slices to Core, workload slice to Atom, don't disable anything
            ALL_CPUS="0-19" \
                SYS_CPUS="$ATOM_CPUS" \
                WORKLOAD_CPUS="$CORE_CPUS" \
                WORKLOAD_OFFLINE="" \
                run GRT
            ;;

        *)
            echo "Unknown target $i"
    esac
done
