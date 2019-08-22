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

#include "jit_gen12hp_u8s8s32x_1x1_convolution.hpp"
#include "ocl_stream.hpp"

namespace dnnl {
namespace impl {
namespace ocl {

template <data_type_t dst_type>
status_t jit_gen12hp_u8s8s32x_1x1_convolution_fwd_t<dst_type>::execute_forward(
        const exec_ctx_t &ctx) const {
    auto &src = CTX_IN_STORAGE(DNNL_ARG_SRC);
    auto &weights = CTX_IN_STORAGE(DNNL_ARG_WEIGHTS);
    auto &bias = CTX_IN_STORAGE(DNNL_ARG_BIAS);
    auto &dst = CTX_OUT_STORAGE(DNNL_ARG_DST);

    const auto &jcp = ker_->jcp;
    auto *compute_stream
            = utils::downcast<compute::compute_stream_t *>(ctx.stream());

    compute::kernel_arg_list_t arg_list;
    arg_list.set(0, src);
    arg_list.set(1, weights);
    arg_list.set(2, bias);
    arg_list.set(3, dst);
    arg_list.set(4, jcp.eltwise.alpha);
    arg_list.set(5, jcp.eltwise.beta);
    arg_list.set(6, jcp.sum_scale);

    float scales = pd()->attr()->output_scales_.scales_[0];
    arg_list.set(7, scales);

    auto nd_range = compute::nd_range_t(jcp.gws_d, jcp.lws_d);
    status_t status = compute_stream->parallel_for(nd_range, kernel_, arg_list);

    return status;
}

using namespace data_type;

template struct jit_gen12hp_u8s8s32x_1x1_convolution_fwd_t<s8>;
template struct jit_gen12hp_u8s8s32x_1x1_convolution_fwd_t<u8>;

} // namespace ocl
} // namespace impl
} // namespace dnnl
