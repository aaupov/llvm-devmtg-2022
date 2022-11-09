# llvm-devmtg-2022
Artifacts for 2022 US LLVM Developer Meeting presentation

# Prerequisites
- Linux x86_64 (BOLT instrumentation limitation at the moment)
- ccache (to cache first-stage builds across configurations)
- perf: ```sudo apt-get install linux-tools-`uname -r` ```
  - Allow perf sampling:
  - Add `kernel.perf_event_paranoid = -1` to /etc/sysctl.conf
  - `sudo sysctl -p`
- [LLVM build prerequisites](https://llvm.org/docs/GettingStarted.html#software):
    CMake, Ninja, Python, etc
- 8 GB RAM or more
- 8 physical cores to run the full benchmark in reasonable time.
    4 cores is the barest minimum but the benchmarking can take ~10h.

# Launch instructions
```
git clone https://github.com/aaupov/llvm-devmtg-2022
cd llvm-devmtg-2022
bash -x ./driver.sh <XXX> |& tee log.txt
```
Where `<XXX>` is an arch name, one of `BDW GLC GRT ZEN1`.
Note that your CPU needs to match the specified arch exactly by the core count
and thread topology. Check the driver to make sure it's specified correctly, and
make changes if needed.

Follow instructions at https://llvm.org/docs/Benchmarking.html#linux to find out
SMT pairs that need to be disabled for the benchmark.


If you have a local up-to-date LLVM checkout, you can save time by providing the
repo to the script:
```
LLVM_SOURCE=/path/to/llvm-project bash -x ./driver.sh <XXX> |& tee log.txt
```

# Results
The results would be located in the temporary folder of the run (which is not
deleted automatically), which is printed in the beginning of the script.

Naming scheme: $CONFIG_$ARCH_run.txt, e.g.
`BASELINE_GLC_run.txt` or `BOLT_PGO_GRT_run.txt`
