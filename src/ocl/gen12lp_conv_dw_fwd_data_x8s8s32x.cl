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

#include "ocl/ocl_math_utils.h"
#include "ocl/ocl_types.h"
#if WITH_ELTWISE || WITH_POST_SUM_ELTWISE
#include "ocl/ocl_post_ops.h"
#endif

#define KDHW_SIZE KD *KH *KW

uchar16 __attribute__((overloadable))
intel_sub_group_block_read_uc16(const __global uchar *p);
void __attribute__((overloadable))
intel_sub_group_block_write_uc16(__global uchar *p, uchar16 data);

__attribute__((intel_reqd_sub_group_size(SUB_GROUP_SIZE)))
__attribute__((reqd_work_group_size(LWS_0, LWS_1, LWS_2))) __kernel void
conv_dw_fwd_x8s8s32x_kernel(const __global uchar *src, const __global char *wei,
        const __global float *bias, __global DATA_T *dst, float alpha,
        float beta, float sum_scale, float scales) {

    const int osp = get_global_id(1);
    const int od = osp / (OW * OH);
    const int ohw = osp % (OW * OH);
    const int ow = (ohw % OW);
    const int oh = ohw / OW;
    const int g = get_group_id(0) * OC_BLOCK;
    const int mb = (get_global_id(2) / 4) * MB_BLOCK;
    const int mb_half = (get_global_id(2) % 4) * MB_BLOCK / 4;
    const int id = od * SD - PD;
    const int ih = oh * SH - PH;
    const int iw = ow * SW - PW;

    dst += mb * G * OD * OH * OW + g * OD * OH * OW * MB_BLOCK
            + (od * OH * OW + oh * OW + ow) * MB_BLOCK * OC_BLOCK
            + mb_half * OC_BLOCK;
    src += mb * G * ID * IH * IW + g * ID * IH * IW * MB_BLOCK
            + (id * IH * IW + ih * IW + iw) * MB_BLOCK * IC_BLOCK
            + mb_half * IC_BLOCK;
    wei += g * KDHW_SIZE;

    int8 S00 = 0;
    int8 S01 = 0;
    uchar16 A00, A10, A20, A30;

    __attribute__((opencl_unroll_hint)) for (int sp = 0;
                                             sp < KDHW_SIZE - KDHW_SIZE % 4;
                                             sp += 4) {
        const int4 s = {sp, sp + 1, sp + 2, sp + 3};
        const int4 kd = s / (KH * KW);
        const int4 kh = (s % (KH * KW)) / KH;
        const int4 kw = (s % (KH * KW)) % KH;
        const int4 src_index
                = (kd * (1 + DD) * IH * IW + kh * (1 + DH) * IW + kw * (1 + DW))
                * MB_BLOCK * IC_BLOCK;
        const int4 index = id + kd * (1 + DD) < 0 || id + kd * (1 + DD) >= ID
                || ih + kh * (1 + DH) < 0 || ih + kh * (1 + DH) >= IH
                || iw + kw * (1 + DW) < 0 || iw + kw * (1 + DW) >= IW;
        if (index.s0) {
            A00 = 0;
        } else {
            A00 = (intel_sub_group_block_read_uc16(
                    (const __global uchar *)(&src[src_index.s0])));
        }
        if (index.s1) {
            A10 = 0;
        } else {
            A10 = (intel_sub_group_block_read_uc16(
                    (const __global uchar *)(&src[src_index.s1])));
        }
        if (index.s2) {
            A20 = 0;
        } else {
            A20 = (intel_sub_group_block_read_uc16(
                    (const __global uchar *)(&src[src_index.s2])));
        }
        if (index.s3) {
            A30 = 0;
        } else {
            A30 = (intel_sub_group_block_read_uc16(
                    (const __global uchar *)(&src[src_index.s3])));
        }
        char8 W = as_char8(
                intel_sub_group_block_read_uc8((const __global uchar *)(wei)));
        char4 W1 = W.s0246;
        char4 W2 = W.s1357;
        S00.s0 = IMAD(
                (SRC_DATA4_T)(A00.s0, A10.s0, A20.s0, A30.s0), W1, S00.s0);
        S00.s1 = IMAD(
                (SRC_DATA4_T)(A00.s1, A10.s1, A20.s1, A30.s1), W2, S00.s1);
        S00.s2 = IMAD(
                (SRC_DATA4_T)(A00.s2, A10.s2, A20.s2, A30.s2), W1, S00.s2);
        S00.s3 = IMAD(
                (SRC_DATA4_T)(A00.s3, A10.s3, A20.s3, A30.s3), W2, S00.s3);
        S00.s4 = IMAD(
                (SRC_DATA4_T)(A00.s4, A10.s4, A20.s4, A30.s4), W1, S00.s4);
        S00.s5 = IMAD(
                (SRC_DATA4_T)(A00.s5, A10.s5, A20.s5, A30.s5), W2, S00.s5);
        S00.s6 = IMAD(
                (SRC_DATA4_T)(A00.s6, A10.s6, A20.s6, A30.s6), W1, S00.s6);
        S00.s7 = IMAD(
                (SRC_DATA4_T)(A00.s7, A10.s7, A20.s7, A30.s7), W2, S00.s7);
        S01.s0 = IMAD(
                (SRC_DATA4_T)(A00.s8, A10.s8, A20.s8, A30.s8), W1, S01.s0);
        S01.s1 = IMAD(
                (SRC_DATA4_T)(A00.s9, A10.s9, A20.s9, A30.s9), W2, S01.s1);
        S01.s2 = IMAD(
                (SRC_DATA4_T)(A00.sa, A10.sa, A20.sa, A30.sa), W1, S01.s2);
        S01.s3 = IMAD(
                (SRC_DATA4_T)(A00.sb, A10.sb, A20.sb, A30.sb), W2, S01.s3);
        S01.s4 = IMAD(
                (SRC_DATA4_T)(A00.sc, A10.sc, A20.sc, A30.sc), W1, S01.s4);
        S01.s5 = IMAD(
                (SRC_DATA4_T)(A00.sd, A10.sd, A20.sd, A30.sd), W2, S01.s5);
        S01.s6 = IMAD(
                (SRC_DATA4_T)(A00.se, A10.se, A20.se, A30.se), W1, S01.s6);
        S01.s7 = IMAD(
                (SRC_DATA4_T)(A00.sf, A10.sf, A20.sf, A30.sf), W2, S01.s7);
        wei += 4 * OC_BLOCK;
    }

    __attribute__((opencl_unroll_hint)) for (int sp = KDHW_SIZE - KDHW_SIZE % 4;
                                             sp < KDHW_SIZE; sp++) {
        const int kd = sp / (KH * KW);
        const int kh = (sp % (KH * KW)) / KH;
        const int kw = (sp % (KH * KW)) % KH;
        const int src_index
                = (kd * (1 + DD) * IH * IW + kh * (1 + DH) * IW + kw * (1 + DW))
                * MB_BLOCK * IC_BLOCK;
        const int index = id + kd * (1 + DD) < 0 || id + kd * (1 + DD) >= ID
                || ih + kh * (1 + DH) < 0 || ih + kh * (1 + DH) >= IH
                || iw + kw * (1 + DW) < 0 || iw + kw * (1 + DW) >= IW;
        if (index) {
            A00 = 0;
        } else {
            A00 = (intel_sub_group_block_read_uc16(
                    (const __global uchar *)(&src[src_index])));
        }
        const char2 W = as_char2(
                intel_sub_group_block_read_uc2((const __global uchar *)(wei)));
        const char W1 = W.s0;
        const char W2 = W.s1;
        S00.s0 += ((SRC_DATA_T)A00.s0) * W1;
        S00.s1 += ((SRC_DATA_T)A00.s1) * W2;
        S00.s2 += ((SRC_DATA_T)A00.s2) * W1;
        S00.s3 += ((SRC_DATA_T)A00.s3) * W2;
        S00.s4 += ((SRC_DATA_T)A00.s4) * W1;
        S00.s5 += ((SRC_DATA_T)A00.s5) * W2;
        S00.s6 += ((SRC_DATA_T)A00.s6) * W1;
        S00.s7 += ((SRC_DATA_T)A00.s7) * W2;
        S01.s0 += ((SRC_DATA_T)A00.s8) * W1;
        S01.s1 += ((SRC_DATA_T)A00.s9) * W2;
        S01.s2 += ((SRC_DATA_T)A00.sa) * W1;
        S01.s3 += ((SRC_DATA_T)A00.sb) * W2;
        S01.s4 += ((SRC_DATA_T)A00.sc) * W1;
        S01.s5 += ((SRC_DATA_T)A00.sd) * W2;
        S01.s6 += ((SRC_DATA_T)A00.se) * W1;
        S01.s7 += ((SRC_DATA_T)A00.sf) * W2;

        wei += OC_BLOCK;
    }
    float8 tmp00 = convert_float8(S00);
    float8 tmp01 = convert_float8(S01);

#define DO_ELTWISE() \
    do { \
        for (uint i = 0; i < 8; i++) { \
            tmp00[i] = fwd_eltwise(tmp00[i], alpha, beta); \
            tmp01[i] = fwd_eltwise(tmp01[i], alpha, beta); \
        } \
    } while (0)

#if WITH_BIAS
    float2 B = as_float2(
            intel_sub_group_block_read2((const __global uint *)&bias[g]));
    tmp00 = (tmp00 + B.s01010101) * scales;
    tmp01 = (tmp01 + B.s01010101) * scales;
#else
    tmp00 *= scales;
    tmp01 *= scales;
#endif

#if WITH_ELTWISE
    DO_ELTWISE();
#endif
#if WITH_SUM
    DATA16_T D00 = AS_DATA16_T(
            intel_sub_group_block_read_uc16((const __global uchar *)dst));
#if SUM_SCALE
    tmp00 += convert_float8(D00.s01234567);
    tmp01 += convert_float8(D00.s89abcdef);
#else // SUM_SCALE
    tmp00 += convert_float8(D00.s01234567) * sum_scale;
    tmp01 += convert_float8(D00.s89abcdef) * sum_scale;
#endif // SUM_SCALE
#endif // WITH_SUM
#if WITH_POST_SUM_ELTWISE
    DO_ELTWISE();
#endif

    const DATA16_T R0
            = (DATA16_T)(CONVERT_DATA8_T(tmp00), CONVERT_DATA8_T(tmp01));
    intel_sub_group_block_write_uc16((__global uchar *)dst, as_uchar16(R0));
}
