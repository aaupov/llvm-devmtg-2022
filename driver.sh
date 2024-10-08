#!/bin/bash
if [ -n $BENCH_FAST ]; then
  BENCH_RUNS=1
  BENCH_TARGET=not
else
  BENCH_RUNS=5
  BENCH_TARGET=clang
fi

SCRIPT_DIR=$(dirname `realpath "$0"`)
LLVM_SRC=${LLVM_SOURCE:-https://github.com/llvm/llvm-project}

# Make tmpfs directory and cd into it
TMPDIR=`mktemp -d`
cd $TMPDIR
echo $TMPDIR

git clone --no-local "$LLVM_SRC"

LL="llvm-project/llvm"
LCCC="llvm-project/clang/cmake/caches/"

# Cmake configuration for benchmarking
CMAKE_ARGS="-S ${LL} -GNinja -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD=Native"
# Build different versions of Clang: baseline, +LTO, +PGO, +BOLT
COMMON_CMAKE_ARGS="-S ${LL} -GNinja -DCMAKE_BUILD_TYPE=Release
    -DLLVM_ENABLE_PROJECTS=bolt;clang;lld -DLLVM_TARGETS_TO_BUILD=Native
    -DBOOTSTRAP_LLVM_ENABLE_LLD=ON -DBOOTSTRAP_BOOTSTRAP_LLVM_ENABLE_LLD=ON
    -DLLVM_CCACHE_BUILD=ON"
# Baseline: two-stage Clang build
BASELINE_ARGS="$COMMON_CMAKE_ARGS -DCLANG_ENABLE_BOOTSTRAP=On
  -DCLANG_BOOTSTRAP_TARGETS=clang"
# ThinLTO: Two-stage + LTO Clang build
LTO_ARGS="$BASELINE_ARGS -DBOOTSTRAP_LLVM_ENABLE_LTO=Thin"
# Base PGO flags
BASE_PGO_ARGS="$BASELINE_ARGS -DBOOTSTRAP_CLANG_BOOTSTRAP_TARGETS=clang
  -DCLANG_BOOTSTRAP_TARGETS=stage2-clang"
# Instrumentation PGO: Two-stage + PGO build, trained on hello-world
PGO_ARGS="${BASE_PGO_ARGS} -C ${LCCC}PGO.cmake"
# PGO with ThinLTO flag
BASE_LTO_PGO_ARGS="-DPGO_INSTRUMENT_LTO=Thin"
# LTO+PGO: Two-stage + LTO + PGO
LTO_PGO_ARGS="$BASE_LTO_PGO_ARGS $PGO_ARGS"
# CSSPGO: Two-stage + CSSPGO build, trained on LLVM
CSSPGO_ARGS="-DBOOTSTRAP_BOOTSTRAP_CLANG_PGO_TRAINING_DATA_SOURCE_DIR=${LL}
  ${BASE_PGO_ARGS} -C ${LCCC}CSSPGO.cmake"
# LTO+CSSPGO
LTO_CSSPGO_ARGS="$BASE_LTO_PGO_ARGS $CSSPGO_ARGS"

BOLT_PASSTHRU_ARGS="-DCLANG_BOOTSTRAP_CMAKE_ARGS=-C../../../../${LCCC}BOLT.cmake
  -DCLANG_BOOTSTRAP_TARGETS=clang-bolt"

BOLT_BASELINE_ARGS="$BASELINE_ARGS $BOLT_PASSTHRU_ARGS"
BOLT_LTO_ARGS="$LTO_ARGS $BOLT_PASSTHRU_ARGS"
BOLT_PGO_ARGS="$COMMON_CMAKE_ARGS -C ${LCCC}BOLT-PGO.cmake"
BOLT_LTO_PGO_ARGS="$BASE_LTO_PGO_ARGS $BOLT_PGO_ARGS"
BOLT_CSSPGO_ARGS="$COMMON_CMAKE_ARGS
  -DBOOTSTRAP_CLANG_PGO_TRAINING_DATA_SOURCE_DIR=$PWD/${LL}
  -C ${LCCC}BOLT-CSSPGO.cmake"
BOLT_LTO_CSSPGO_ARGS="$BASE_LTO_PGO_ARGS $BOLT_CSSPGO_ARGS"

CONFIGS=( BASELINE LTO PGO LTO_PGO CSSPGO LTO_CSSPGO )

build () {
    for cfg in ${CONFIGS[*]}
    do
        bcfg=BOLT_$cfg
        echo $bcfg
        args=${bcfg}_ARGS
        cmake -B $bcfg ${!args} |& tee ${bcfg}_build.log
        ninja -C $bcfg stage2-clang-bolt |& tee -a ${bcfg}_build.log
    done
}

# Benchmark these versions of Clang using building Clang as a workload
# (with regular configuration specified by $CMAKE_ARGS)

bench () {
    cfg=$1
    hwname=$2
    RUNDIR=$3
    echo $cfg

    clang_dir=`dirname $(find $TMPDIR/BOLT_$cfg -name clang-prebolt)`
    CC=$clang_dir/clang
    CXX=$clang_dir/clang++

    log=${cfg}_${hwname}_run

    for b in BOLT_ ""
    do
        if [[ -z $b ]]; then
            CC=$CC-prebolt
            CXX=$CXX-prebolt
        fi
        rm -rf $RUNDIR/CMakeCache.txt $RUNDIR/CMakeFiles
        cmake -B $RUNDIR $CMAKE_ARGS -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX

        sudo systemd-run --slice=workload.slice --same-dir --wait --collect \
            --service-type=exec --pty --uid=$USER \
            taskset -c $WORKLOAD_CPUS \
            perf stat -r$BENCH_RUNS -o $b$log.txt \
            -e instructions,cycles,L1-icache-misses,iTLB-misses \
            --pre "ninja -C $RUNDIR clean" -- \
            ninja -C $RUNDIR $BENCH_TARGET
    done
}

run () {
    sudo bash -x $SCRIPT_DIR/cpuset.sh prepare $ALL_CPUS $SYS_CPUS $WORKLOAD_CPUS $WORKLOAD_OFFLINE

    RUNDIR=`mktemp -d`
    sudo mount -t tmpfs -o size=10g none $RUNDIR

    for cfg in ${CONFIGS[*]}
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
                WORKLOAD_OFFLINE="42-55" \
                run BDW
            ;;

        # Intel ADL i7-12700K
        GLC)
            ALL_CPUS="0-19" \
                SYS_CPUS="0" \
                WORKLOAD_CPUS="2,4,6,8,10,12,14" \
                WORKLOAD_OFFLINE="1,3,5,7,9,11,13,15-19" \
                run GLC
            ;;

        GRT)
            ALL_CPUS="0-19" \
                SYS_CPUS="0-15" \
                WORKLOAD_CPUS="16-19" \
                WORKLOAD_OFFLINE="" \
                run GRT
            ;;

	ZEN1)
	    # AMD EPYC 7571
	    ALL_CPUS="0-15" \
	        SYS_CPUS="0,8" \
		WORKLOAD_CPUS="1-7" \
		WORKLOAD_OFFLINE=$(seq 9 15) \
		run ZEN1
	    ;;

	SKL)
	    # Intel Xeon 8124M
	    ALL_CPUS="0-35" \
		SYS_CPUS="0,18" \
		WORKLOAD_CPUS="1-17" \
		WORKLOAD_OFFLINE="19-35" \
		run SKL
	    ;;

  SKX)
      # Intel Xeon 6138
      ALL_CPUS="0-79" \
    SYS_CPUS="0,40" \
    WORKLOAD_CPUS="1-39" \
    WORKLOAD_OFFLINE="41-79" \
    run SKX
      ;;

	ICL)
	    # Intel Xeon 8375C
	    ALL_CPUS="0-63" \
		SYS_CPUS="0,32" \
		WORKLOAD_CPUS="1-31" \
		WORKLOAD_OFFLINE="33-63" \
		run ICL
	    ;;

	ZEN2)
	    # AMD EPYC 7R32
	    ALL_CPUS="0-95" \
		SYS_CPUS="0,48" \
		WORKLOAD_CPUS="1-37" \
		WORKLOAD_OFFLINE="49-95" \
		run ZEN2
	    ;;

	ZEN3)
	    # EPYC 7R13
	    ALL_CPUS="0-95" \
		SYS_CPUS="0,48" \
		WORKLOAD_CPUS="1-47" \
		WORKLOAD_OFFLINE="49-95" \
		run ZEN3
	    ;;

	IVB)
	    # Intel IVB i7-3770S
	    ALL_CPUS="0-7" \
	        SYS_CPUS="" \
		WORKLOAD_CPUS="0-3" \
		WORKLOAD_OFFLINE="4-7" \
		run IVB
	    ;;

        *)
            echo "Unknown target $i"
    esac
done
