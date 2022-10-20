#!/bin/bash
BENCH_WARMUP=1
BENCH_RUNS=3
USE_PERF=1

SCRIPT_DIR=$(dirname `realpath "$0"`)

prepare () {
    # Make tmpfs directory and cd into it
    TMPDIR=`mktemp -d`
    cd $TMPDIR
    echo $TMPDIR

    # Checkout LLVM repo at a known commit
    git clone --no-checkout --filter=blob:none https://github.com/llvm/llvm-project
    git -C llvm-project sparse-checkout set --cone
    # https://reviews.llvm.org/D136023
    git -C llvm-project checkout 076240fa062415b6470b79413559aff2bf5bf208
    git -C llvm-project sparse-checkout set bolt llvm clang lld
}

# Build different versions of Clang: baseline, +LTO, +PGO, +BOLT
CMAKE_ARGS='-S llvm-project/llvm -GNinja -DCMAKE_BUILD_TYPE=Release \
    "-DLLVM_ENABLE_PROJECTS=clang;lld" -DLLVM_ENABLE_LLD=ON'
COMMON_CMAKE_ARGS='-S llvm-project/llvm -GNinja -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_LLD=ON -DBOOTSTRAP_LLVM_ENABLE_LLD=ON \
    -DBOOTSTRAP_BOOTSTRAP_LLVM_ENABLE_LLD=ON \
    "-DLLVM_ENABLE_PROJECTS=bolt;clang;lld" -DLLVM_CCACHE_BUILD=ON \
    -DBOOTSTRAP_LLVM_CCACHE_BUILD=ON'
# Baseline: two-stage Clang build
BASELINE_ARGS="$COMMON_CMAKE_ARGS -DCLANG_ENABLE_BOOTSTRAP=On"
# ThinLTO: Two-stage + LTO Clang build
LTO_ARGS="$BASELINE_ARGS -DBOOTSTRAP_LLVM_ENABLE_LTO=Thin"
# Instrumentation PGO: Two-stage + PGO build
PGO_ARGS="$BASELINE_ARGS -C llvm-project/clang/cmake/caches/PGO.cmake -DCLANG_BOOTSTRAP_TARGETS=stage2-install-clang"
# LTO+PGO: Two-stage + LTO + PGO
LTO_PGO_ARGS="-DPGO_INSTRUMENT_LTO=Thin $PGO_ARGS"

BOLT_CMAKE="llvm-project/clang/cmake/caches/BOLT.cmake"
BOLT_PGO_CMAKE="llvm-project/clang/cmake/caches/BOLT-PGO.cmake"
BOLT_PASSTHRU_ARGS="-DCLANG_BOOTSTRAP_CMAKE_ARGS=-C../../../../$BOLT_CMAKE -DCLANG_BOOTSTRAP_TARGETS=clang++-bolt"
BOLT_PGO_CFG="-C $BOLT_PGO_CMAKE"

BOLT_BASELINE_ARGS="$BASELINE_ARGS $BOLT_PASSTHRU_ARGS"
BOLT_LTO_ARGS="$LTO_ARGS $BOLT_PASSTHRU_ARGS"
BOLT_PGO_ARGS="$BASELINE_ARGS $BOLT_PGO_CFG"
BOLT_LTO_PGO_ARGS="-DPGO_INSTRUMENT_LTO=Thin $BOLT_PGO_ARGS"

build () {
    # non-BOLT, then BOLT build
    for b in "" BOLT_
    do
        for cfg in BASELINE LTO PGO LTO_PGO
        do
            bcfg=$b$cfg
            echo $bcfg
            args=${bcfg}_ARGS
            cmake -B $bcfg ${!args} -DCMAKE_INSTALL_PREFIX=$bcfg/install |& tee $bcfg.log
            target="stage2-install-clang"
            if [[ -n $b ]]; then
                target="stage2-clang++-bolt"
            fi
            ninja -C $bcfg $target |& tee -a $bcfg.log
        done
    done
}

# Benchmark these versions of Clang using building Clang as a workload
# (with regular configuration specified by $CMAKE_ARGS)

bench () {
    cfg=$1
    hwname=$2
    echo $cfg

    RUNDIR=`mktemp -d`
    sudo mount -t tmpfs -o size=10g none $RUNDIR
    pushd $RUNDIR

    if [ $USE_PERF -eq 1 ]
    then
        sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
           --service-type=exec --pty --uid=$USER \
           perf stat -r$BENCH_RUNS -o ${cfg}_run_${hwname}.txt \
           -e instructions,cycles,L1-icache-misses,iTLB-misses -- \
            bash -c "rm -rf ${cfg}_run && cmake -B ${cfg}_run $CMAKE_ARGS \
            -DCMAKE_C_COMPILER=$TMPDIR/$cfg/install/bin/clang \
            -DCMAKE_CXX_COMPILER=$TMPDIR/$cfg/install/bin/clang++ && \
            ninja -C ${cfg}_run clang"
    else
        sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
            --service-type=exec --pty --uid=$USER \
        hyperfine --warmup $BENCH_WARMUP --runs $BENCH_RUNS \
            --export-json ${cfg}_run_${hwname}.json --show-output \
            --prepare "rm -rf ${cfg}_run && cmake -B ${cfg}_run $CMAKE_ARGS \
            -DCMAKE_C_COMPILER=$TMPDIR/$cfg/install/bin/clang \
            -DCMAKE_CXX_COMPILER=$TMPDIR/$cfg/install/bin/clang++" \
            "ninja -C ${cfg}_run clang"
    fi

    bcfg=BOLT_${cfg}
    echo $bcfg
    clang_bolt=`find $TMPDIR/$bcfg -name clang-bolt`
    clangxx_bolt=`find $TMPDIR/$bcfg -name clang++-bolt`
    if [ $USE_PERF -eq 1 ]
    then
        sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
           --service-type=exec --pty --uid=$USER \
           perf stat -r$BENCH_RUNS -o ${bcfg}_run_${hwname}.txt \
           -e instructions,cycles,L1-icache-misses,iTLB-misses -- \
            bash -c "rm -rf ${bcfg}_run && cmake -B ${bcfg}_run $CMAKE_ARGS \
            -DCMAKE_C_COMPILER=$clang_bolt \
            -DCMAKE_CXX_COMPILER=$clangxx_bolt && \
            ninja -C ${bcfg}_run clang"
    else
        sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
            --service-type=exec --pty --uid=$USER \
        hyperfine --warmup $BENCH_WARMUP --runs $BENCH_RUNS \
            --export-json ${bcfg}_run_${hwname}.json --show-output \
            --prepare "rm -rf ${bcfg}_run && cmake -B ${bcfg}_run $CMAKE_ARGS \
            -DCMAKE_C_COMPILER=$clang_bolt \
            -DCMAKE_CXX_COMPILER=$clangxx_bolt" \
            "ninja -C ${bcfg}_run clang"
    fi
    popd
    sudo umount $RUNDIR
}

run () {
    $SCRIPT_DIR/cpuset.sh prepare

    for cfg in BASELINE LTO PGO LTO_PGO
    do
        echo $1
        bench $cfg $1
    done

    $SCRIPT_DIR/cpuset.sh undo
}

# Main entry point
prepare
build
for i in "$@"
do
    case "$i" in
        BDW)
            # Intel BDW E5-2680v4
            export ALL_CPUS="0-55"
            SYS_CPUS="0-13,28-41" \
                WORKLOAD_CPUS="14-27,42-55" \
                WORKLOAD_OFFLINE=$(seq 42 55) \
                run BDW
            ;;

        GLC)
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
                run GLC
            ;;

        GRT)
            # Intel ADL i7-12700K
            export ALL_CPUS="0-19"
            CORE_CPUS="0-15"
            CORE_CPUS_SMT0=`seq 0 2 14 | paste -sd "," -` #"0,2,4,6,8,10,12,14"
            CORE_CPUS_SMT1=`seq 1 2 15 | paste -sd "," -` #"1,3,5,7,9,11,13,15"
            ATOM_CPUS="16-19"
            # Pin system slices to Core, workload slice to Atom, don't disable anything
            SYS_CPUS="$ATOM_CPUS" \
                WORKLOAD_CPUS="$CORE_CPUS" \
                WORKLOAD_OFFLINE="" \
                run GRT
            ;;

        *)
            echo "Unknown target $i"
    esac
done
