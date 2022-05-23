/*******************************************************************************
 * Copyright 2022 Intel Corporation
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
#include "ir_utils.hpp"
#include <functional>
#include "sc_expr.hpp"
#include "sc_stmt.hpp"
#include "ssa_data.hpp"
#include <util/array_ref.hpp>
#include <util/weakptr_utils.hpp>

namespace sc {
void get_direct_dependency_of_expr(
        const expr &v, const std::function<void(array_ref<expr>)> &callback) {
    switch (v->node_type_) {
        case sc_expr_type::undef: assert(0 && "Unreachable"); break;
        case sc_expr_type::constant:
        case sc_expr_type::func_addr: break;
        case sc_expr_type::tensor:
        case sc_expr_type::var: {
            if (utils::is_uninitialized_weakptr(v->ssa_data_->owner_)) {
                // a var/tensor can be attached none of the define_node, which
                // means it is a parameter
                break;
            }
            stmt owner {v->ssa_data_->owner_.lock()};
            assert(owner.defined());
            auto init = owner.static_as<define>()->init_;
            if (owner.isa<define>() && init.defined()) {
                if (init.isa<var>()) {
                    callback({init});
                } else {
                    get_direct_dependency_of_expr(init, callback);
                }
            }
        } break;
        case sc_expr_type::cast: callback({v.static_as<cast>()->in_}); break;
        case sc_expr_type::add:
        case sc_expr_type::sub:
        case sc_expr_type::mul:
        case sc_expr_type::div:
        case sc_expr_type::mod: {
            auto val = v.static_as<binary>();
            callback({val->l_, val->r_});
        } break;
        case sc_expr_type::cmp_eq:
        case sc_expr_type::cmp_ne:
        case sc_expr_type::cmp_lt:
        case sc_expr_type::cmp_le:
        case sc_expr_type::cmp_gt:
        case sc_expr_type::cmp_ge: {
            auto val = v.static_as<cmp>();
            callback({val->l_, val->r_});
        } break;
        case sc_expr_type::logic_and:
        case sc_expr_type::logic_or: {
            auto val = v.static_as<logic>();
            callback({val->l_, val->r_});
        } break;
        case sc_expr_type::logic_not:
            callback(&v.static_as<logic_not>()->in_);
            break;
        case sc_expr_type::select: {
            auto val = v.static_as<select>();
            callback({val->cond_, val->l_, val->r_});
        } break;
        case sc_expr_type::indexing: {
            auto val = v.static_as<indexing>();
            callback(&val->ptr_);
            callback(val->idx_);
            if (val->mask_.defined()) { callback(&val->mask_); }
        } break;
        case sc_expr_type::call: {
            auto the_call = v.static_as<call>();
            if (auto ex
                    = std::dynamic_pointer_cast<expr_base>(the_call->func_)) {
                callback({expr(ex)});
            }
            callback(the_call->args_);
        } break;
        case sc_expr_type::tensorptr: {
            auto val = v.static_as<tensorptr>();
            callback(&val->base_->ptr_);
            callback(val->base_->idx_);
        } break;
        case sc_expr_type::intrin_call:
            callback(v.static_as<intrin_call>()->args_);
            break;
        case sc_expr_type::low_level_intrin:
            callback(v.static_as<low_level_intrin>()->args_);
            break;
        case sc_expr_type::ssa_phi:
            callback(v.static_as<ssa_phi>()->values_);
            break;
    }
}
} // namespace sc
