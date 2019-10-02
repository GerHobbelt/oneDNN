/*******************************************************************************
* Copyright 2017-2018 Intel Corporation
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*******************************************************************************/

#include <assert.h>
#include "dnnl.h"
#include <unordered_set>

#include "dnnl_common.hpp"
#include "dnnl_memory.hpp"

// Engine kind used to run DNNL primitives for testing
dnnl_engine_kind_t engine_tgt_kind = dnnl_cpu;

// Engine used to run DNNL primitives for testing
dnnl_engine_t engine_tgt;

// Stream for target engine
dnnl_stream_t stream_tgt;

args_t &args_t::set(int arg, const dnn_mem_t &mem) {
    args_.push_back(std::make_pair(arg, &mem));
    return *this;
}

// Unmap before passing the memory to execute
void execute_unmap_args(
        const args_t &args, std::vector<dnnl_exec_arg_t> &dnnl_args) {
    dnnl_args.resize(args.size());
    for (int i = 0; i < args.size(); ++i) {
        if (args.dnn_mem(i).is_mapped()) args.dnn_mem(i).unmap();

        dnnl_args[i].arg = args.arg(i);
        dnnl_args[i].memory = args.dnn_mem(i).m_;
    }
}

// Map the memory back after execute
void execute_map_args(const args_t &args) {
    for (int i = 0; i < args.size(); ++i)
        if (!args.dnn_mem(i).is_mapped()) args.dnn_mem(i).map();
}

#if DNNL_GPU_RUNTIME == DNNL_RUNTIME_OCL
static bool is_gpu_sim() {
    static const char *sim_env = getenv("DNNL_GPU_SIM");
    static bool _is_sim = sim_env && atoi(sim_env) == 1;
    return _is_sim;
}

static bool is_gpu_perf_sim() {
    static const char *sim_perf_env = getenv("DNNL_GPU_PERF_SIM");
    static bool _is_perf_sim = sim_perf_env && atoi(sim_perf_env) == 1;
    return _is_perf_sim;
}

static std::unordered_set<dnn_mem_t *> dnn_mem_objects;

void register_dnn_mem_object(dnn_mem_t *mem) {
    dnn_mem_objects.insert(mem);
}

void unregister_dnn_mem_object(dnn_mem_t *mem) {
    dnn_mem_objects.erase(mem);
}
void destroy_dnn_mem_objects() {
    std::vector<dnn_mem_t *> to_destroy;
    for (auto *mem : dnn_mem_objects)
        to_destroy.push_back(mem);

    for (auto *mem : to_destroy)
        mem->~dnn_mem_t();
}
#endif

dnnl_status_t execute_and_wait(
        dnnl_primitive_t prim, dnnl_stream_t stream, const args_t &args) {

    std::vector<dnnl_exec_arg_t> dnnl_args;
    execute_unmap_args(args, dnnl_args);

#if DNNL_GPU_RUNTIME == DNNL_RUNTIME_OCL
    dnnl_primitive_kind_t prim_kind = dnnl_undefined_primitive;

    if (is_gpu_sim()) {
        const_dnnl_primitive_desc_t pd;
        DNN_SAFE_V(dnnl_primitive_get_primitive_desc(prim, &pd));

        DNN_SAFE_V(dnnl_primitive_desc_query(
                pd, dnnl_query_primitive_kind, 0, &prim_kind));

        // Skip reorders during performance simulation
        if (prim_kind == dnnl_reorder && is_gpu_perf_sim()) return dnnl_success;
    }
#endif

    dnnl_status_t status = dnnl_primitive_execute(
            prim, stream, (int)dnnl_args.size(), dnnl_args.data());
    if (status != dnnl_success) return status;
    status = dnnl_stream_wait(stream);
    if (status != dnnl_success) return status;

#if DNNL_GPU_RUNTIME == DNNL_RUNTIME_OCL
    // Handle simulation
    if (is_gpu_sim()) {
        int nargs = (int)dnnl_args.size();

        // Stop execution on the first non-reorder primitive.
        // Assume that simulation should be done for this primitive.
        if (prim_kind != dnnl_reorder) {
            // Query the run number and verbosity level
            const char *sim_run_env = getenv("DNNL_GPU_SIM_RUN");
            const char *sim_verbose_env = getenv("DNNL_GPU_SIM_VERBOSE");
            const int sim_run = !sim_run_env ? -1 : atoi(sim_run_env);
            const int sim_verbose = atoi(sim_verbose_env);

            // Destroy library objects and exit from benchdnn for the following cases:
            // - Performance simulation
            // - First run of functional simulation
            if (sim_run != 1) {
                if (sim_verbose > 0)
                    printf("== benchdnn_sim: Destroying objects...\n");

                DNN_SAFE_V(dnnl_primitive_destroy(prim));

                destroy_dnn_mem_objects();

                DNN_SAFE_V(dnnl_engine_destroy(engine_tgt));
                DNN_SAFE_V(dnnl_stream_destroy(stream_tgt));

                exit(0);
            } else {
                // Handle second run of functional simulation

                // Keep unique memory objects
                std::set<dnnl_memory_t> uniq_mems;
                for (int i = 0; i < nargs; ++i)
                    uniq_mems.insert(dnnl_args[i].memory);

                // Sort memory objects according to their "simulation" IDs
                std::map<int, dnnl_memory_t> sorted_mems;
                for (auto mem : uniq_mems)
                    sorted_mems[dnnl_memory_get_sim_id(mem)] = mem;

                // Load memory contents from binaries
                std::string aub_file(getenv("DNNL_GPU_SIM_AUB_FILE"));
                aub_file.resize(aub_file.length() - strlen(".aub"));
                int ctr = 0;
                for (auto &kv : sorted_mems) {
                    dnnl_memory_t mem = kv.second;
                    std::ostringstream fname;
                    fname << aub_file << std::setfill('0') << std::setw(3)
                          << ctr << ".bin";
                    std::ifstream in(fname.str(), std::ios::binary);
                    assert(in.good());
                    {
                        const dnnl_memory_desc_t *md;
                        DNN_SAFE_V(dnnl_memory_get_memory_desc(mem, &md));
                        size_t sz = dnnl_memory_desc_get_size(md);

                        if (sim_verbose > 0)
                            printf("== benchdnn_sim: Load memory object from "
                                   "%s, "
                                   "size: %lld\n",
                                    fname.str().c_str(), (long long)sz);

                        void *ptr;
                        dnnl_memory_map_data(mem, &ptr);
                        in.read((char *)ptr, sz);
                        dnnl_memory_unmap_data(mem, ptr);
                    }
                    ++ctr;
                }
            }
        }
    }
#endif

    execute_map_args(args);
    return dnnl_success;
}

inline bool should_stop(const benchdnn_timer_t &t) {
    const bool stop = false
            || (fix_times_per_prb && t.times() >= fix_times_per_prb)
            || (!fix_times_per_prb && t.total_ms() >= max_ms_per_prb
                    && t.times() >= min_times_per_prb);
    return stop;
}

inline int measure_perf_individual(benchdnn_timer_t &t, dnnl_primitive_t prim,
        std::vector<dnnl_exec_arg_t> &dnnl_args) {
    t.reset();
    while (true) {
        DNN_SAFE(dnnl_primitive_execute(prim, stream_tgt, (int)dnnl_args.size(),
                         dnnl_args.data()),
                WARN);
        t.stamp();
        if (should_stop(t)) break;
    }
    return OK;
}

inline int measure_perf_aggregate(benchdnn_timer_t &t, dnnl_primitive_t prim,
        std::vector<dnnl_exec_arg_t> &dnnl_args) {
    const int max_batch_times = 10000;

    // Warm-up run
    t.reset();
    DNN_SAFE(dnnl_primitive_execute(
                     prim, stream_tgt, (int)dnnl_args.size(), dnnl_args.data()),
            WARN);
    DNN_SAFE(dnnl_stream_wait(stream_tgt), WARN);
    t.stamp();

    int cur_batch_times
            = fix_times_per_prb ? fix_times_per_prb : min_times_per_prb;
    --cur_batch_times;

    while (true) {
        for (int i = 0; i < cur_batch_times; i++) {
            DNN_SAFE(dnnl_primitive_execute(prim, stream_tgt,
                             (int)dnnl_args.size(), dnnl_args.data()),
                    WARN);
        }
        DNN_SAFE(dnnl_stream_wait(stream_tgt), WARN);
        t.stamp(cur_batch_times);

        if (should_stop(t)) break;

        // Adjust cur_batch_times after the first batch run
        if (t.times() == cur_batch_times + 1) {
            double ms_min = t.ms(benchdnn_timer_t::min);
            // Heuristic: try to use ~5 batch runs for the whole benchmark
            int batch_times_heuristic = (ms_min == 0.0)
                    ? INT_MAX
                    : MAX2(1,
                            (int)((max_ms_per_prb - t.total_ms()) / ms_min
                                    / 5));
            cur_batch_times = MIN2(max_batch_times, batch_times_heuristic);
        }
    }
    return OK;
}

int measure_perf(benchdnn_timer_t &t, dnnl_primitive_t prim, args_t &args) {
    int ret = OK;
    if (bench_mode & PERF) {
        std::vector<dnnl_exec_arg_t> dnnl_args;
        execute_unmap_args(args, dnnl_args);

        // For CPU: measure indiividual iterations
        // For GPU: measure iterations in batches to hide driver overhead
        if (engine_tgt_kind == dnnl_cpu)
            ret = measure_perf_individual(t, prim, dnnl_args);
        else
            ret = measure_perf_aggregate(t, prim, dnnl_args);

        if (ret == OK) execute_map_args(args);
    }
    return ret;
}
