/*******************************************************************************
* Copyright 2019 Intel Corporation
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

#include "ocl/ocl_types.h"

#define CONCAt2(a, b) a##b
#define CONCAT2(a, b) CONCAt2(a, b)

#define OFF(dim, idx) \
    (dim % CONCAT2(DATA_B, idx)) * CONCAT2(DATA_SB, idx) \
            + (dim / CONCAT2(DATA_B, idx)) * CONCAT2(DATA_S, idx)

#if SOFTMAX_AXIS_IDX == 0
#define DATA_OFF(dim0, dim1, dim2, softmax_dim) \
    OFF(softmax_dim, 0) + OFF(dim0, 1) + OFF(dim1, 2) + OFF(dim2, 3)
#elif SOFTMAX_AXIS_IDX == 1
#define DATA_OFF(dim0, dim1, dim2, softmax_dim) \
    OFF(dim0, 0) + OFF(softmax_dim, 1) + OFF(dim1, 2) + OFF(dim2, 3)
#elif SOFTMAX_AXIS_IDX == 2
#define DATA_OFF(dim0, dim1, dim2, softmax_dim) \
    OFF(dim0, 0) + OFF(dim1, 1) + OFF(softmax_dim, 2) + OFF(dim2, 3)
#elif SOFTMAX_AXIS_IDX == 3
#define DATA_OFF(dim0, dim1, dim2, softmax_dim) \
    OFF(dim0, 0) + OFF(dim1, 1) + OFF(dim2, 2) + OFF(softmax_dim, 3)
#else
#error unsupported softmax dimension
#endif

#if FWD_KERNEL
__attribute__((reqd_work_group_size(GROUP_SIZE, 1, 1)))
__attribute__((intel_reqd_sub_group_size(SUB_GROUP_SIZE)))

__kernel void
ref_softmax_fwd_generic(__global DATA_T *src, __global DATA_T *dst) {

    const int dim[] = {
            get_global_id(0) / GROUP_SIZE, get_global_id(1), get_global_id(2)};
    int local_id = get_local_id(0);

    // SOFTMAX_AXIS is the size of axis around which softmax operation is
    // performed

    // begin and end indices calculated according to thread's id
    int begin = local_id * (SOFTMAX_AXIS / GROUP_SIZE);
    int end = (local_id == GROUP_SIZE - 1)
            ? SOFTMAX_AXIS
            : (local_id + 1) * (SOFTMAX_AXIS / GROUP_SIZE);

    // initializing max_ to first value of subgroup
    int start_idx = DATA_OFF(dim[0], dim[1], dim[2], begin);
    DEF_ACC_DATA_T max_ = TO_DEF_ACC_DATA_T(src[start_idx]);
    DEF_ACC_DATA_T denom_ = DATA_ZERO;

    // finding max value for each sub_group
    for (int i = begin; i < end; ++i) {
        size_t data_off = DATA_OFF(dim[0], dim[1], dim[2], i);
        DEF_ACC_DATA_T temp = TO_DEF_ACC_DATA_T(src[data_off]);
        max_ = temp > max_ ? temp : max_;
    }

    // reduce using work_group_reduce if no. of subgroups > 1, for e.g.
    // if group_size is 32, there will be 2 sub-groups (size of each sub-group
    // is 16 which is an optimal value)
#if GROUP_SIZE == SUB_GROUP_SIZE
    max_ = sub_group_reduce_max(max_);
#else
    max_ = work_group_reduce_max(max_);
#endif

    // updating dst tensor and accumulating denom for last step
    for (int i = begin; i < end; ++i) {
        size_t data_off = DATA_OFF(dim[0], dim[1], dim[2], i);
        DEF_ACC_DATA_T temp = TO_DEF_ACC_DATA_T(src[data_off]);
        dst[data_off] = TO_DATA_T(exp(temp - max_));
        denom_ += TO_DEF_ACC_DATA_T(dst[data_off]);
    }

#if GROUP_SIZE == SUB_GROUP_SIZE
    denom_ = sub_group_reduce_add(denom_);
#else
    denom_ = work_group_reduce_add(denom_);
#endif

    for (int i = begin; i < end; ++i) {
        size_t data_off = DATA_OFF(dim[0], dim[1], dim[2], i);
        DEF_ACC_DATA_T temp = TO_DEF_ACC_DATA_T(dst[data_off]);
        dst[data_off] = TO_DATA_T(temp / denom_);
    }
}

#endif

__kernel void ref_softmax_bwd_generic(__global DATA_T *dst,
        __global DATA_T *diff_src, __global DATA_T *diff_dst) {
    const int dim[] = {get_global_id(0), get_global_id(1), get_global_id(2)};

    DEF_ACC_DATA_T sbr = 0.f;
    for (int i = 0; i < SOFTMAX_AXIS; ++i) {
        size_t idx = DATA_OFF(dim[0], dim[1], dim[2], i);
        DEF_ACC_DATA_T g_temp = TO_DEF_ACC_DATA_T(diff_dst[idx]);
        DEF_ACC_DATA_T y_temp = TO_DEF_ACC_DATA_T(dst[idx]);
        sbr += g_temp * y_temp;
    }

    for (int i = 0; i < SOFTMAX_AXIS; ++i) {
        size_t idx = DATA_OFF(dim[0], dim[1], dim[2], i);
        DEF_ACC_DATA_T inner_data = TO_DEF_ACC_DATA_T(diff_dst[idx]) - sbr;
        diff_src[idx] = TO_DATA_T(TO_DEF_ACC_DATA_T(dst[idx]) * inner_data);
    }
}
