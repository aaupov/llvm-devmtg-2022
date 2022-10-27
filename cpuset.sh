#!/bin/bash
# cpuset
# This script implements benchmarking tips from https://llvm.org/docs/Benchmarking.html
SYS_SLICES="machine.slice system.slice user.slice"
WORKLOAD="workload.slice"
CMD=$1
ALL_CPUS=$2
SYS_CPUS=$3
WORKLOAD_CPUS=$4
shift 4
WORKLOAD_OFFLINE=$@

echo "SYS_CPUS: $SYS_CPUS"
echo "WORKLOAD_CPUS: $WORKLOAD_CPUS"
echo "WORKLOAD_OFFLINE: $WORKLOAD_OFFLINE"

case $CMD in
    'list')
        # Print current CPU allocation per slice
        for i in $SYS_SLICES $WORKLOAD
        do
            printf "$i: "
            cat /sys/fs/cgroup/$i/cpuset.cpus
        done

        ;;
    'prepare')
        # Assign SYS_CPUS to SYS_SLICES
        for i in $SYS_SLICES
        do
            echo -e $SYS_CPUS > /sys/fs/cgroup/$i/cpuset.cpus
        done

        # Assign CPUs to cpuset
        echo -e $WORKLOAD_CPUS > /sys/fs/cgroup/$WORKLOAD/cpuset.cpus

        # Set DVFS governor to performance
        for i in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
        do
            echo performance > $i
        done

        # Take CPUs offline
        chcpu -d $WORKLOAD_OFFLINE

        # Disable ASLR
        echo 0 > /proc/sys/kernel/randomize_va_space

        # Disable Turbo
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo

        ;;
    'undo')
        # Assign ALL_CPUS to all slices
        for i in $SYS_SLICES $WORKLOAD
        do
            echo -e $ALL_CPUS > /sys/fs/cgroup/$i/cpuset.cpus
        done

        # Take CPUs online
        chcpu -e $ALL_CPUS

        # Re-enable ASLR
        echo 1 > /proc/sys/kernel/randomize_va_space

        # Re-enable Turbo
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo

        # Set DVFS governor to powersave
        for i in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
        do
            echo powersave > $i
        done

        ;;

    *)
        echo "Usage: $0 [list|prepare|undo]"
        ;;
esac
