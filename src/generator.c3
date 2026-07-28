module nina::generator;

import llvm;

import nina::util;
import nina::debug;
import nina::scope;
import nina::types;
import nina::lookup;
import nina::highlighter;

import std::collections::list;
import std::io;
import std::os;

fn Generator* create(CompileContext* context) {
    Generator* generator = alloc::new(context.alloc, Generator);

    String mod = context.trees.get(context.current_file).mod_node.path.path_node.path!!;

    generator.module_name = mod;
    generator.scope       = scope::create(context.alloc);
    generator.llvm_module = context.modules.get(context.current_file)!!;

    if (!context.args.no_debug) {
        String flag_name = "Debug Info Version";
        llvm::add_module_flag(
            generator.llvm_module,
            LLVMModuleFlagBehavior.MODULE_FLAG_BEHAVIOR_WARNING,
            (CChar*)flag_name.ptr,
            flag_name.len,
            llvm::value_as_metadata(llvm::const_int(llvm::int_32_type(), llvm::debug_metadata_version(), llvm::FALSE))
        );
    }

    generator.llvm_builder = llvm::create_builder();

    String file = context.current_file.to_path(context.alloc).basename().copy(context.alloc)!!;
    String path = context.current_file.trim_right(file);

    if (!context.args.no_debug) {
        generator.llvm_debug_builder = llvm::create_di_builder(generator.llvm_module);
        generator.llvm_debug_file    = llvm::di_builder_create_file(
            generator.llvm_debug_builder,
            (CChar*)file.ptr,
            (CUInt)file.len,
            (CChar*)path.ptr,
            (CUInt)path.len
        );

        llvm::di_builder_create_compile_unit(
            generator.llvm_debug_builder,
            LLVMDWARFSourceLanguage.DWARF_SOURCE_LANGUAGE_C99,
            generator.llvm_debug_file,
            "nina", 4,
            llvm::FALSE,
            "", 0,
            0,
            "", 0,
            LLVMDWARFEmissionKind.DWARF_EMISSION_FULL,
            0,
            llvm::FALSE,
            llvm::FALSE,
            "", 0,
            "", 0
        );
    }

    return generator;
}

fn void generate(Generator* generator, CompileContext* context) {
    generate_node(generator, context, context.trees.get(context.current_file))!!;
    emit(generator, context);
}

fn void* generate_node(Generator* generator, CompileContext* context, Node* node, void* data = null) {
    switch (node.type) {
    case NodeType.MOD:                generate_mod(generator, context, node);
    case NodeType.FUNCTION:           generate_function(generator, context, node);
    case NodeType.RET:                generate_ret(generator, context, node, data);
    case NodeType.INT:         return generate_int(generator, context, node, data);
    case NodeType.EXT:                generate_ext(generator, context, node);
    case NodeType.CALL:        return generate_call(generator, context, node);
    case NodeType.BOOL:        return generate_bool(generator, context, node);
    case NodeType.STRING:      return generate_string(generator, context, node, data);
    case NodeType.BIN:         return generate_bin(generator, context, node, data);
    case NodeType.IDENT:       return generate_ident(generator, context, node);
    case NodeType.VARIABLE:    return generate_variable(generator, context, node);
    case NodeType.USE:                generate_use(generator, context, node);
    case NodeType.ACCESS:      return generate_access(generator, context, node, data);
    case NodeType.UNARY:       return generate_unary(generator, context, node, data);
    case NodeType.IF:                 generate_if(generator, context, node, data);
    case NodeType.STRUCT:             generate_struct(generator, context, node);
    case NodeType.INIT:        return generate_init(generator, context, node);
    case NodeType.REFERENCE:   return generate_reference(generator, context, node, data);
    case NodeType.DEREFERENCE: return generate_dereference(generator, context, node, data);
    case NodeType.SUFFIX:      return generate_suffix(generator, context, node);
    case NodeType.ASSIGN:             generate_assign(generator, context, node);
    case NodeType.NULL:        return generate_null(generator, context, node);
    case NodeType.WHILE:              generate_while(generator, context, node, data);
    case NodeType.REAL:        return generate_real(generator, context, node);
    case NodeType.CHAR:        return generate_char(generator, context, node);
    case NodeType.SWITCH:             generate_switch(generator, context, node, data);
    case NodeType.BREAK:              generate_break(generator, context, node);
    case NodeType.INDEX:       return generate_index(generator, context, node);
    case NodeType.ARRAY:       return generate_array(generator, context, node);
    case NodeType.TRAP:               generate_trap(generator, context, node);
    case NodeType.CAST:        return generate_cast(generator, context, node, data);
    case NodeType.SLICE:       return generate_slice(generator, context, node);
    case NodeType.CONST:       break;
    default:
        highlighter::panic("Missing generator function for type '%s'", node.type);
    }

    return null;
}

fn void generate_mod(Generator* generator, CompileContext* context, Node* node) {
    foreach (Node* statement : node.mod_node.statements) {
        generate_node(generator, context, statement);
    }
}

fn void generate_function(Generator* generator, CompileContext* context, Node* node) {
    String        name          = node.function_node.name.ident_node.name;
    FunctionInfo* function_info = lookup::get_function_info(context, name);
    LLVMTypeRef   type          = lookup::get(context, function_info.node.function_node.type, generator.scope, generator).llvm_type;

    LLVMTypeRef  llvm_function_type  = function_info.llvm_type;
    LLVMValueRef llvm_function_value = function_info.llvm_value;

    function_info = scope::add_function(
        generator.scope,
        context.alloc,
        name,
        generator.module_name,
        context.current_file,
        node,
        llvm_function_type,
        llvm_function_value
    );

    debug::add_function(generator, context, node, llvm_function_value);

    generator.scope = scope::create(context.alloc, generator.scope);

    LLVMBasicBlockRef entry = llvm::append_basic_block(llvm_function_value, "entry");
    llvm::position_builder_at_end(generator.llvm_builder, entry);

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    foreach (CUInt index, Node* parameter : node.function_node.parameters) {
        String       parameter_name       = parameter.parameter_node.name.ident_node.name;
        LLVMTypeRef  llvm_parameter_type  = lookup::get(context, parameter, generator.scope, generator).llvm_type;
        LLVMValueRef llvm_parameter_value = llvm::get_param(function_info.llvm_value, index);

        LLVMValueRef alloca = llvm::build_alloca(generator.llvm_builder, llvm_parameter_type, "");
        llvm::build_store(generator.llvm_builder, llvm_parameter_value, alloca);

        scope::add_variable(generator.scope, context.alloc, parameter_name, parameter, llvm_parameter_type, alloca);
        debug::add_parameter(generator, context, parameter, llvm_function_value, llvm_parameter_value, index);
    }

    bool returned = generate_compound(generator, context, node.function_node.statements, type);

    generator.scope = generator.scope.parent;

    if (!returned && lookup::get(context, node, generator.scope, generator).type_name == "void")
    {
        llvm::build_ret_void(generator.llvm_builder);
    }

    if (!llvm::get_basic_block_terminator(llvm::get_insert_block(generator.llvm_builder))) {
        llvm::build_unreachable(generator.llvm_builder);
    }
}

fn void generate_ret(Generator* generator, CompileContext* context, Node* node, void* data) {
    Node* value = node.ret_node.value;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    if (value) {
        llvm::build_ret(generator.llvm_builder, generate_node(generator, context, value, data));
    } else {
        llvm::build_ret_void(generator.llvm_builder);
    }
}

fn LLVMValueRef generate_int(Generator* generator, CompileContext* context, Node* node, void* data) {
    LLVMTypeRef int_type = context.lookup.get("int").llvm_type!!;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    if (data) {
        int_type = data;
    }

    return create_int(int_type, node.int_node.number.to_uint())!!;
}

fn void generate_ext(Generator* generator, CompileContext* context, Node* node) => @pool() {
    String        name          = node.ext_node.name.ident_node.name;
    FunctionInfo* function_info = lookup::get_function_info(context, name);

    LLVMTypeRef  llvm_function_type  = function_info.llvm_type;
    LLVMValueRef llvm_function_value = function_info.llvm_value;

    scope::add_function(
        generator.scope,
        context.alloc,
        name,
        generator.module_name,
        context.current_file,
        node,
        llvm_function_type,
        llvm_function_value
    );

    // debug::add_function(generator, context, node, llvm_function_value, false);
}

fn LLVMValueRef generate_call(Generator* generator, CompileContext* context, Node* node) => @pool() {
    String        name          = node.call_node.name.path_node.path;
    FunctionInfo* function_info = lookup::get_function_info(context, name);
    
    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    List{LLVMValueRef} arguments;
    arguments.init(context.alloc);

    foreach (int i, Node* argument : node.call_node.arguments) {
        Node* parameter_type = null;
        switch (function_info.node.type) {
        case NodeType.FUNCTION:
            if (i >= function_info.node.function_node.parameters.len()) {
                break;
            }

            parameter_type = function_info.node.function_node.parameters[i];
        case NodeType.EXT:
            if (i >= function_info.node.ext_node.parameters.len()) {
                break;
            }

            parameter_type = function_info.node.ext_node.parameters[i];
        default:
            highlighter::panic("Unreachable");
        }

        LLVMValueRef argument_value = generate_node(generator, context, argument, (parameter_type && parameter_type.parameter_node.type)
            ? (void*)lookup::get(context, parameter_type.parameter_node.type, generator.scope, generator).llvm_type
            : null);

        if (parameter_type && parameter_type.parameter_node.type) {
            LLVMTypeRef expected_type = lookup::get(context, parameter_type.parameter_node.type, generator.scope, generator).llvm_type;
            LLVMTypeRef actual_type   = llvm::type_of(argument_value);

            if (llvm::get_type_kind(expected_type) == LLVMTypeKind.INTEGER_TYPE_KIND &&
                llvm::get_type_kind(actual_type) == LLVMTypeKind.INTEGER_TYPE_KIND &&
                llvm::get_int_type_width(expected_type) != llvm::get_int_type_width(actual_type)) {

                if (llvm::get_int_type_width(expected_type) > llvm::get_int_type_width(actual_type)) {
                    argument_value = llvm::build_s_ext(generator.llvm_builder, argument_value, expected_type, "");
                } else {
                    argument_value = llvm::build_trunc(generator.llvm_builder, argument_value, expected_type, "");
                }
            }
        }

        if (parameter_type && parameter_type.parameter_node.type.type_node.name.path_node.path == "any") {
            LookupElement argument_type_element = lookup::get(context, argument, generator.scope, generator);
            if (argument_type_element.type_name != "any") {
                TypeInfo* argument_type_info = lookup::get_type_info(context, argument_type_element.type_name);
                argument_value = make_any(generator, context, argument_value, argument_type_info);
            }
        }

        arguments.push(argument_value);
    }

    if (llvm::is_function_var_arg(function_info.llvm_type))
    {
        arguments.push(llvm::const_null(llvm::pointer_type(llvm::int_8_type(), 0)));
    }

    return llvm::build_call_2(
        generator.llvm_builder,
        function_info.llvm_type,
        function_info.llvm_value,
        arguments.to_array(context.alloc),
        (CUInt)arguments.len(),
        ""
    );
}

fn LLVMValueRef generate_bool(Generator* generator, CompileContext* context, Node* node) {
    LLVMTypeRef bool_type = context.lookup.get("bool").llvm_type!!;
    CULongLong  value     = node.bool_node.value == "true" ? 1 : 0;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    return llvm::const_int(bool_type, value, llvm::FALSE);
}

fn LLVMValueRef generate_string(Generator* generator, CompileContext* context, Node* node, void* data) {
    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    LLVMValueRef bytes_const  = llvm::const_string((CChar*)node.string_node.string.ptr, node.string_node.string.len, llvm::FALSE);
    LLVMTypeRef  bytes_type   = llvm::type_of(bytes_const);
    LLVMValueRef bytes_global = llvm::add_global(generator.llvm_module, bytes_type, "");

    llvm::set_initializer(bytes_global, bytes_const);
    llvm::set_global_constant(bytes_global, llvm::TRUE);
    llvm::set_linkage(bytes_global, LLVMLinkage.PRIVATE_LINKAGE);
    llvm::set_unnamed_addr(bytes_global, llvm::TRUE);

    if (data && llvm::get_type_kind((LLVMTypeRef)data) == LLVMTypeKind.POINTER_TYPE_KIND) {
        return bytes_global;
    }

    LLVMTypeRef  string_type         = context.lookup.get("String").llvm_type!!;
    LLVMValueRef len_const           = llvm::const_int(llvm::int_32_type(), node.string_node.string.len, llvm::FALSE);
    LLVMValueRef[2] fields           = { bytes_global, len_const };
    LLVMValueRef string_struct_const = llvm::const_named_struct(string_type, &fields, 2);

    LLVMValueRef global = llvm::add_global(generator.llvm_module, string_type, "");
    llvm::set_initializer(global, string_struct_const);
    llvm::set_global_constant(global, llvm::TRUE);
    llvm::set_linkage(global, LLVMLinkage.PRIVATE_LINKAGE);
    llvm::set_unnamed_addr(global, llvm::TRUE);

    return llvm::build_load_2(generator.llvm_builder, string_type, global, "");
}

fn LLVMValueRef generate_bin(Generator* generator, CompileContext* context, Node* node, void* data) {
    LLVMValueRef  left      = generate_node(generator, context, node.bin_node.left, data);
    LLVMValueRef  right     = generate_node(generator, context, node.bin_node.right, data);
    LookupElement left_data = lookup::get(context, node.bin_node.left, generator.scope);
    String        type      = left_data.type_group;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    switch (node.bin_node.operator.type) {
    case TokenType.PLUS:
        if (type == "pointer") {
            LLVMValueRef gep_base;
            String       element_type_name;

            if (left_data.type_name.ends_with("[]")) {
                gep_base           = llvm::build_extract_value(generator.llvm_builder, left, 0, "");
                element_type_name  = left_data.type_name[:left_data.type_name.len - 2];
            } else {
                gep_base           = left;
                element_type_name  = left_data.type_name[:left_data.type_name.len - 1];
            }

            TypeInfo* element_type_info = lookup::get_type_info(context, element_type_name);

            return llvm::build_gep2(generator.llvm_builder, element_type_info.llvm_type, gep_base, &right, 1, "");
        }

        if (llvm::type_of(left) != llvm::type_of(right)) {
            if (llvm::get_int_type_width(llvm::type_of(left)) < llvm::get_int_type_width(llvm::type_of(right))) {
                left = llvm::build_s_ext(generator.llvm_builder, left, llvm::type_of(right), "");
            } else {
                right = llvm::build_s_ext(generator.llvm_builder, right, llvm::type_of(left), "");
            }
        }

        return llvm::build_add(generator.llvm_builder, left, right, "");
    case TokenType.MINUS:
        if (type == "pointer") {
            LLVMValueRef gep_base;
            String       element_type_name;

            if (left_data.type_name.ends_with("[]")) {
                gep_base           = llvm::build_extract_value(generator.llvm_builder, left, 0, "");
                element_type_name  = left_data.type_name[:left_data.type_name.len - 2];
            } else {
                gep_base           = left;
                element_type_name  = left_data.type_name[:left_data.type_name.len - 1];
            }

            TypeInfo* element_type_info = lookup::get_type_info(context, element_type_name);

            LLVMValueRef neg_right = llvm::build_neg(generator.llvm_builder, right, "");

            return llvm::build_gep2(generator.llvm_builder, element_type_info.llvm_type, gep_base, &neg_right, 1, "");
        }

        if (llvm::type_of(left) != llvm::type_of(right)) {
            if (llvm::get_int_type_width(llvm::type_of(left)) < llvm::get_int_type_width(llvm::type_of(right))) {
                left = llvm::build_s_ext(generator.llvm_builder, left, llvm::type_of(right), "");
            } else {
                right = llvm::build_s_ext(generator.llvm_builder, right, llvm::type_of(left), "");
            }
        }

        if (type == "real") {
            return llvm::build_f_sub(generator.llvm_builder, left, right, "");
        }

        return llvm::build_sub(generator.llvm_builder, left, right, "");
    case TokenType.ASTERISK:
        return llvm::build_mul(generator.llvm_builder, left, right, "");
    case TokenType.SLASH:
        if (type == "real") {
            return llvm::build_f_div(generator.llvm_builder, left, right, "");
        }

        return llvm::build_s_div(generator.llvm_builder, left, right, "");
    case TokenType.AMP:
        return llvm::build_and(generator.llvm_builder, left, right, "");
    case TokenType.PIPE:
        return llvm::build_or(generator.llvm_builder, left, right, "");
    case TokenType.CARET:
        return llvm::build_xor(generator.llvm_builder, left, right, "");
    case TokenType.SHL:
        return llvm::build_shl(generator.llvm_builder, left, right, "");
    case TokenType.SHR:
        return llvm::build_a_shr(generator.llvm_builder, left, right, "");
    case TokenType.RANGLE:
    case TokenType.LANGLE:
    case TokenType.LTE:
    case TokenType.IS_EQUAL:
    case TokenType.NOT_EQUAL:
    case TokenType.GTE:
        if (type == "real") {
            LLVMRealPredicate pred;
            switch (node.bin_node.operator.type) {
            case TokenType.RANGLE:    pred = LLVMRealPredicate.REAL_OGT;
            case TokenType.LANGLE:    pred = LLVMRealPredicate.REAL_OLT;
            case TokenType.LTE:       pred = LLVMRealPredicate.REAL_OLE;
            case TokenType.IS_EQUAL:  pred = LLVMRealPredicate.REAL_OEQ;
            case TokenType.NOT_EQUAL: pred = LLVMRealPredicate.REAL_ONE;
            case TokenType.GTE:       pred = LLVMRealPredicate.REAL_OGE;
            default:
                highlighter::panic();
            }
            return llvm::build_f_cmp(generator.llvm_builder, pred, left, right, "");
        }

        if (type == "string") {
            LLVMValueRef eq = build_string_eq(generator, context, left, right);
            if (node.bin_node.operator.type == TokenType.NOT_EQUAL) {
                return llvm::build_not(generator.llvm_builder, eq, "");
            }
            return eq;
        }

        LLVMTypeRef left_type  = llvm::type_of(left);
        LLVMTypeRef right_type = llvm::type_of(right);

        if (left_type != right_type) {
            if (llvm::get_int_type_width(left_type) < llvm::get_int_type_width(right_type)) {
                left = llvm::build_s_ext(generator.llvm_builder, left, right_type, "");
            } else {
                right = llvm::build_s_ext(generator.llvm_builder, right, left_type, "");
            }
        }

        LLVMIntPredicate pred;
        switch (node.bin_node.operator.type) {
        case TokenType.RANGLE:    pred = LLVMIntPredicate.INT_SGT;
        case TokenType.LANGLE:    pred = LLVMIntPredicate.INT_SLT;
        case TokenType.LTE:       pred = LLVMIntPredicate.INT_SLE;
        case TokenType.IS_EQUAL:  pred = LLVMIntPredicate.INT_EQ;
        case TokenType.NOT_EQUAL: pred = LLVMIntPredicate.INT_NE;
        case TokenType.GTE:       pred = LLVMIntPredicate.INT_SGE;
        default:
            highlighter::panic();
        }

        return llvm::build_i_cmp(generator.llvm_builder, pred, left, right, "");
    case TokenType.OR:
        return llvm::build_or(generator.llvm_builder, left, right, "");
    case TokenType.AND:
        return llvm::build_and(generator.llvm_builder, left, right, "");
    default:
        highlighter::panic("Missing generate_bin case for operator type '%s'", node.bin_node.operator.type);
    }
}

fn LLVMValueRef generate_ident(Generator* generator, CompileContext* context, Node* node) {
    VariableInfo* variable_info = scope::get_variable(generator.scope, node.ident_node.name);

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    if (node.ident_node.name.starts_with("$$")) {
        return get_builtin(context, node.ident_node.name);
    }

    if (!variable_info) {
        ConstInfo* const_info = get_or_declare_const(generator, context, node.ident_node.name);
        return llvm::build_load_2(generator.llvm_builder, const_info.llvm_type, const_info.llvm_value, "");
    }

    return llvm::build_load_2(generator.llvm_builder, variable_info.llvm_type, variable_info.llvm_value, "");
}

fn LLVMValueRef generate_variable(Generator* generator, CompileContext* context, Node* node) {
    String       name        = node.variable_node.name.path_node.path;
    LLVMTypeRef  llvm_type   = lookup::get(context, node, generator.scope, generator).llvm_type;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    LLVMValueRef llvm_alloca = llvm::build_alloca(generator.llvm_builder, llvm_type, (CChar*)name.ptr);
    
    if (node.variable_node.value) {
        LLVMValueRef llvm_value = generate_node(generator, context, node.variable_node.value, (void*)llvm_type);
        llvm::build_store(generator.llvm_builder, llvm_value, llvm_alloca);
    } else {
        if (lookup::get(context, node, generator.scope, generator).type_group == "pointer") {
            llvm::build_store(generator.llvm_builder, llvm::const_null(llvm_type), llvm_alloca);
        }
    }

    scope::add_variable(generator.scope, context.alloc, name, node, llvm_type, llvm_alloca);

    return llvm_alloca;
}

fn bool generate_compound(Generator* generator, CompileContext* context, NodeList statements, void* data)
{
    bool returned;
    foreach (int index, Node* statement : statements) {
        if (returned) {
            continue;
        }

        if (statement.type == NodeType.RET && index != statements.len() - 1) {
            returned = true;
        }

        generate_node(generator, context, statement, data);
    }

    return returned;
}

fn LLVMValueRef generate_access(Generator* generator, CompileContext* context, Node* node, void* data) => @pool() {
    Node*  path = node.access_node.name;
    String name = path.path_node.path;

    if (scope::has_import(generator.scope, name)) {
        DString full_name;
        full_name.tinit();

        String function_name;

        Node* next = node;
        Node* last = null;
        while (next) {
            switch (next.type) {
            case NodeType.ACCESS:
                full_name.append(next.access_node.name.ident_node.name);
                full_name.append(".");

                last = next;
                next = next.access_node.next;
            case NodeType.CALL:
                full_name.append(next.call_node.name.ident_node.name);
                function_name = next.call_node.name.ident_node.name;

                last = next;
                next = null;
            default:
                highlighter::panic();
            }
        }

        String short_module_name = full_name.str_view().strip_suffix(string::tformat(".%s", function_name));
        String resolved_module   = scope::get_import(generator.scope, short_module_name);

        if (resolved_module == "") {
            highlighter::error(context, context.current_file, node.range.from, node.range.to, "Could not find module '%s', did you forget to import it?", short_module_name);
        }

        DString resolved_full_name;
        resolved_full_name.tinit();
        resolved_full_name.append(resolved_module);
        resolved_full_name.append(".");
        resolved_full_name.append(function_name);

        switch (last.type) {
        case NodeType.CALL:
            FunctionInfo* function_info = lookup::get_function_info(context, resolved_full_name.str_view());
            List{LLVMValueRef} arguments;
            arguments.init(context.alloc);

            foreach (int i, Node* argument : last.call_node.arguments) {
                Node* parameter_type = null;
                switch (function_info.node.type) {
                case NodeType.FUNCTION:
                    if (i < function_info.node.function_node.parameters.len()) {
                        parameter_type = function_info.node.function_node.parameters[i];
                    }
                case NodeType.EXT:
                    if (i < function_info.node.ext_node.parameters.len()) {
                        parameter_type = function_info.node.ext_node.parameters[i];
                        if (!parameter_type.parameter_node.type) {
                            parameter_type = null;
                        }
                    }
                default:
                    highlighter::panic("Unreachable");
                }

                LLVMValueRef argument_value = generate_node(generator, context, argument, (parameter_type && parameter_type.parameter_node.type)
                    ? (void*)lookup::get(context, parameter_type.parameter_node.type, generator.scope, generator).llvm_type
                    : null);

                if (parameter_type && parameter_type.parameter_node.type) {
                    LLVMTypeRef expected_type = lookup::get(context, parameter_type.parameter_node.type, generator.scope, generator).llvm_type;
                    LLVMTypeRef actual_type   = llvm::type_of(argument_value);

                    if (llvm::get_type_kind(expected_type) == LLVMTypeKind.INTEGER_TYPE_KIND &&
                        llvm::get_type_kind(actual_type) == LLVMTypeKind.INTEGER_TYPE_KIND &&
                        llvm::get_int_type_width(expected_type) != llvm::get_int_type_width(actual_type)) {

                        if (llvm::get_int_type_width(expected_type) > llvm::get_int_type_width(actual_type)) {
                            argument_value = llvm::build_s_ext(generator.llvm_builder, argument_value, expected_type, "");
                        } else {
                            argument_value = llvm::build_trunc(generator.llvm_builder, argument_value, expected_type, "");
                        }
                    }
                }

                if (parameter_type && parameter_type.parameter_node.type.type_node.name.path_node.path == "any") {
                    LookupElement argument_type_element = lookup::get(context, argument, generator.scope, generator);
                    if (argument_type_element.type_name != "any") {
                        TypeInfo* argument_type_info = lookup::get_type_info(context, argument_type_element.type_name);
                        argument_value = make_any(generator, context, argument_value, argument_type_info);
                    }
                }

                arguments.push(argument_value);
            }

            if (llvm::is_function_var_arg(function_info.llvm_type))
            {
                arguments.push(llvm::const_null(llvm::pointer_type(llvm::int_8_type(), 0)));
            }

            LLVMValueRef callee = get_or_declare_function(generator, context, function_info);

            return llvm::build_call_2(
                generator.llvm_builder,
                function_info.llvm_type,
                callee,
                arguments.to_array(context.alloc),
                (CUInt)arguments.len(),
                ""
            );
        default:
            highlighter::panic();
        }
    }

    if (scope::has_variable(generator.scope, name)) {
        VariableInfo* variable_info = scope::get_variable(generator.scope, name);

        LookupElement base;
        if (scope::has_narrowed_type(generator.scope, name)) {
            base = scope::get_narrowed_type(generator.scope, name);
        } else {
            base = lookup::get(context, variable_info.node, generator.scope, generator);
        }

        LLVMValueRef instance_ptr = variable_info.llvm_value;
        LLVMValueRef current_value;

        Node* next = node.access_node.next;

        while (next) {
            String field_name;
            Node*  after;

            switch (next.type) {
            case NodeType.IDENT:
                field_name = next.ident_node.name;
                after      = null;
            case NodeType.ACCESS:
                field_name = next.access_node.name.ident_node.name;
                after      = next.access_node.next;
            default:
                highlighter::panic();
            }

            if (base.type_name.ends_with("[]") || base.type_name == "String") {
                if (field_name == "len") {
                    if (after) {
                        highlighter::panic("Cannot access field on 'int'");
                    }
                    LLVMValueRef slice_value = llvm::build_load_2(generator.llvm_builder, base.llvm_type, instance_ptr, "");
                    return llvm::build_extract_value(generator.llvm_builder, slice_value, 1, "");
                }
                if (field_name == "ptr") {
                    if (after) {
                        highlighter::panic("Cannot access field on 'char*'");
                    }
                    LLVMValueRef slice_value = llvm::build_load_2(generator.llvm_builder, base.llvm_type, instance_ptr, "");
                    return llvm::build_extract_value(generator.llvm_builder, slice_value, 0, "");
                }
            }

            if (field_name.starts_with("$")) {
                current_value = get_reflection_value(generator, context, base, field_name, instance_ptr, data);

                if (after) {
                    if (field_name == "$data") {
                        instance_ptr = current_value;
                    } else {
                        base = { .type_name = "int", .type_group = "integer" };
                    }
                } else {
                    /*
                    if (field_name == "$data") {
                        TypeInfo* target_type = lookup::get_type_info(context, base.type_name);
                        current_value = llvm::build_load_2(generator.llvm_builder, target_type.llvm_type, current_value, "");
                    }
                    */

                    return current_value;
                }

                next = after;
                continue;
            }

            String base_group = base.type_group;
            String type_name  = base.type_name;

            if (base_group == "pointer") {
                type_name = type_name[:type_name.len - 1];

                instance_ptr = llvm::build_load_2(generator.llvm_builder, base.llvm_type, instance_ptr, "");
            }

            TypeInfo* type_info = lookup::get_type_info(context, type_name);
            NodeList  fields    = lookup::get_type_fields(context, type_info, generator.scope);

            uint  field_index = 0;
            Node* field_node;
            foreach (uint i, Node* field : fields) {
                if (field.parameter_node.name.ident_node.name == field_name) {
                    field_index = i;
                    field_node  = field;
                    break;
                }
            }

            if (!field_node) {
                highlighter::panic("Could not find field '%s' on type '%s'", field_name, type_name);
            }

            LookupElement field_element = lookup::get(context, field_node, generator.scope, generator);
            LLVMValueRef  field_ptr     = llvm::build_struct_gep2(generator.llvm_builder, type_info.llvm_type, instance_ptr, field_index, "");

            if (after) {
                instance_ptr = field_ptr;
                base         = field_element;
            } else {
                return llvm::build_load_2(generator.llvm_builder, field_element.llvm_type, field_ptr, "");
            }

            next = after;
        }
    } else if (lookup::get_type_info(context, name)) {
        TypeInfo*     type_info = lookup::get_type_info(context, name);

        LLVMTypeKind type_kind = llvm::get_type_kind(type_info.llvm_type);
        String type_group;

        switch (type_kind) {
        case LLVMTypeKind.INTEGER_TYPE_KIND:
            type_group = llvm::get_int_type_width(type_info.llvm_type) == 1 ? "boolean" : "integer";
        case LLVMTypeKind.POINTER_TYPE_KIND:
            type_group = "pointer";
        case LLVMTypeKind.STRUCT_TYPE_KIND:
            type_group = "struct";
        default:
            type_group = "";
        }

        LookupElement base = { .llvm_type = type_info.llvm_type, .type_name = type_info.name, .type_group = type_group };

        LLVMValueRef current_value;

        Node* next = node.access_node.next;

        while (next) {
            String field_name;
            Node*  after;

            switch (next.type) {
            case NodeType.IDENT:
                field_name = next.ident_node.name;
                after      = null;
            case NodeType.ACCESS:
                field_name = next.access_node.name.ident_node.name;
                after      = next.access_node.next;
            default:
                highlighter::panic();
            }

            current_value = get_reflection_value(generator, context, base, field_name);

            if (after) {
                base = { .type_name = "int", .type_group = "integer" };
            } else {
                return current_value;
            }

            next = after;
        }

    }

    highlighter::panic("Unreachable");
}

fn LLVMValueRef generate_unary(Generator* generator, CompileContext* context, Node* node, void* data) {
    LLVMValueRef llvm_value = generate_node(generator, context, node.unary_node.node, data);
    LLVMValueRef llvm_type  = lookup::get(context, node.unary_node.node, generator.scope, generator).llvm_type;

    switch (node.unary_node.operator.type) {
    case TokenType.MINUS:
        if (lookup::get(context, node, generator.scope, generator).type_group == "integer") {
            LLVMTypeRef int_type = data ? (LLVMTypeRef)data : context.lookup.get("int").llvm_type!!;
            
            return llvm::build_mul(generator.llvm_builder, llvm_value, create_int(int_type, -1), "");
        }
        
        LLVMTypeRef real_type = context.lookup.get("real").llvm_type!!;

        return llvm::build_f_mul(generator.llvm_builder, llvm_value, llvm::const_real(real_type, -1), "");
    case TokenType.PLUS:
        return llvm_value;
    case TokenType.BANG:
        if (lookup::get(context, node.unary_node.node, generator.scope, generator).type_group == "pointer") {
            LLVMValueRef null_ptr = llvm::const_null(llvm_type);
            
            return llvm::build_i_cmp(generator.llvm_builder, LLVMIntPredicate.INT_EQ, llvm_value, null_ptr, "");
        }
        
        return llvm::build_not(generator.llvm_builder, llvm_value, "");
    case TokenType.TILDA:
        return llvm::build_not(generator.llvm_builder, llvm_value, "");
    default:
        highlighter::panic();
    }
}

fn void generate_if(Generator* generator, CompileContext* context, Node* node, void* data) {
    @todo("create build_condition function");

    LLVMValueRef condition = generate_node(generator, context, node.if_node.condition);

    LLVMTypeRef condition_type = llvm::type_of(condition);
    if (llvm::get_type_kind(condition_type) == LLVMTypeKind.POINTER_TYPE_KIND) {
        LLVMValueRef null_ptr = llvm::const_null(condition_type);
        condition = llvm::build_i_cmp(generator.llvm_builder, LLVMIntPredicate.INT_NE, condition, null_ptr, "");
    }

    LLVMBasicBlockRef current_block = llvm::get_insert_block(generator.llvm_builder);
    LLVMValueRef      llvm_function = llvm::get_basic_block_parent(current_block);

    LLVMBasicBlockRef then_block = llvm::append_basic_block(llvm_function, "");
    LLVMBasicBlockRef else_block = llvm::append_basic_block(llvm_function, "");
    LLVMBasicBlockRef end_block  = llvm::append_basic_block(llvm_function, "");

    llvm::build_cond_br(generator.llvm_builder, condition, then_block, else_block);

    // -- THEN --
    generator.scope = scope::create(context.alloc, generator.scope);

    String narrowed_var;
    String narrowed_type;
    if (util::try_get_typeid_narrowing(node.if_node.condition, &narrowed_var, &narrowed_type)) {
        TypeInfo*   type_info = lookup::get_type_info(context, narrowed_type);
        LLVMTypeRef llvm_type  = type_info.llvm_type;
        String      type_group;

        switch (llvm::get_type_kind(llvm_type)) {
        case LLVMTypeKind.INTEGER_TYPE_KIND:
            type_group = llvm::get_int_type_width(llvm_type) == 1 ? "boolean" : "integer";
        case LLVMTypeKind.POINTER_TYPE_KIND:
            type_group = "pointer";
        case LLVMTypeKind.STRUCT_TYPE_KIND:
            type_group = "struct";
        default:
            highlighter::panic();
        }

        scope::add_narrowed_type(generator.scope, narrowed_var, {
            .llvm_type  = llvm_type,
            .type_name  = type_info.name,
            .type_group = type_group
        });
    }

    llvm::position_builder_at_end(generator.llvm_builder, then_block);

    generate_compound(generator, context, node.if_node.then_statements, data);

    LLVMBasicBlockRef then_end_block = llvm::get_insert_block(generator.llvm_builder);
    if (!llvm::get_basic_block_terminator(then_end_block)) {
        llvm::build_br(generator.llvm_builder, end_block);
    }

    generator.scope = generator.scope.parent;

    llvm::position_builder_at_end(generator.llvm_builder, else_block);
    if (node.if_node.else_if)
    {
        // -- ELSE IF --
        generate_node(generator, context, node.if_node.else_if, data);

        LLVMBasicBlockRef else_end_block = llvm::get_insert_block(generator.llvm_builder);
        if (!llvm::get_basic_block_terminator(else_end_block)) {
            llvm::build_br(generator.llvm_builder, end_block);
        }
    } else
    {
        // -- ELSE --
        generator.scope = scope::create(context.alloc, generator.scope);

        generate_compound(generator, context, node.if_node.else_statements, data);

        LLVMBasicBlockRef else_end_block = llvm::get_insert_block(generator.llvm_builder);
        if (!llvm::get_basic_block_terminator(else_end_block)) {
            llvm::build_br(generator.llvm_builder, end_block);
        }

        generator.scope = generator.scope.parent;
    }

    llvm::position_builder_at_end(generator.llvm_builder, end_block);
}

fn void generate_struct(Generator* generator, CompileContext* context, Node* node) => @pool() {
    String    name      = node.call_node.name.path_node.path;
    TypeInfo* type_info = lookup::get_type_info(context, name);

    List{LLVMTypeRef} fields;
    fields.tinit();

    foreach(Node* field : node.struct_node.fields)
    {
        fields.push(lookup::get(context, field.parameter_node.type, generator.scope, generator).llvm_type);
    }

    LLVMTypeRef llvm_struct_type = type_info.llvm_type;
    llvm::struct_set_body(llvm_struct_type, fields.to_array(context.alloc), (CUInt)fields.len(), llvm::FALSE);
}

fn LLVMValueRef generate_init(Generator* generator, CompileContext* context, Node* node) => @pool() {
    String name      = node.init_node.name.path_node.path;
    String full_name = string::tformat("%s.%s", generator.module_name, name);

    List{LLVMValueRef} arguments;
    arguments.tinit();

    bool constant = true;
    foreach (Node* argument : node.init_node.arguments) {
        LLVMValueRef argument_llvm_value = generate_node(generator, context, argument);
        arguments.push(argument_llvm_value);

        if (!llvm::is_constant(argument_llvm_value)) {
            constant = false;
        }
    }

    TypeInfo*   type_info   = lookup::get_type_info(context, name);
    LLVMTypeRef struct_type = type_info.llvm_type;

    if (constant) {
        return llvm::const_named_struct(struct_type, arguments.to_array(context.alloc), (CUInt)arguments.len());
    }

    LLVMValueRef instance = llvm::build_alloca(generator.llvm_builder, struct_type, "");
    foreach (uint i, LLVMValueRef argument : arguments)
    {
        LLVMValueRef field_ptr = llvm::build_struct_gep2(generator.llvm_builder, struct_type, instance, i, "");
        llvm::build_store(generator.llvm_builder, argument, field_ptr);
    }

    return llvm::build_load_2(generator.llvm_builder, struct_type, instance, "");
}

fn LLVMValueRef generate_reference(Generator* generator, CompileContext* context, Node* node, void* data) {
    Node* inner = node.reference_node.node;

    if (inner.type == NodeType.IDENT) {
        VariableInfo* variable_info = scope::get_variable(generator.scope, inner.ident_node.name);

        return variable_info.llvm_value;
    }

    LLVMValueRef llvm_value = generate_node(generator, context, inner, data);
    LLVMTypeRef  llvm_type  = lookup::get(context, inner, generator.scope, generator).llvm_type;
    LLVMValueRef alloca     = llvm::build_alloca(generator.llvm_builder, llvm_type, "");

    llvm::build_store(generator.llvm_builder, llvm_value, alloca);

    return alloca;
}

fn LLVMValueRef generate_dereference(Generator* generator, CompileContext* context, Node* node, void* data) {
    LLVMValueRef  llvm_value = generate_node(generator, context, node.dereference_node.node, data);
    LookupElement inner_data = lookup::get(context, node.dereference_node.node, generator.scope, generator);

    String    element_type_name = inner_data.type_name[:inner_data.type_name.len - 1];
    TypeInfo* element_type_info = lookup::get_type_info(context, element_type_name);

    return llvm::build_load_2(generator.llvm_builder, element_type_info.llvm_type, llvm_value, "");
}

fn LLVMValueRef generate_suffix(Generator* generator, CompileContext* context, Node* node) {
    LLVMValueRef target_ptr;
    LLVMTypeRef  llvm_type;
    String       base_group;

    if (node.suffix_node.node.type == NodeType.IDENT) {
        String        name          = node.suffix_node.node.ident_node.name;
        VariableInfo* variable_info = scope::get_variable(generator.scope, name);
        LookupElement type_data     = lookup::get(context, node.suffix_node.node, generator.scope, generator);

        target_ptr = variable_info.llvm_value;
        llvm_type  = type_data.llvm_type;
        base_group = type_data.type_group;
    } else if (node.suffix_node.node.type == NodeType.ACCESS) {
        Node*         access_node    = node.suffix_node.node;
        String        name           = access_node.access_node.name.path_node.path;
        VariableInfo* variable_info  = scope::get_variable(generator.scope, name);
        LookupElement var_type_data  = lookup::get(context, variable_info.node, generator.scope, generator);
        String        access_group   = var_type_data.type_group;
        String        type_name      = var_type_data.type_name;

        if (access_group == "pointer") {
            type_name = type_name[:type_name.len - 1];
        }

        TypeInfo* type_info    = lookup::get_type_info(context, type_name);
        LLVMValueRef instance_ptr = variable_info.llvm_value;

        if (access_group == "pointer") {
            LLVMTypeRef ptr_llvm_type = var_type_data.llvm_type;

            instance_ptr = llvm::build_load_2(generator.llvm_builder, ptr_llvm_type, instance_ptr, "");
        }

        String   field_name = access_node.access_node.next.ident_node.name;
        NodeList fields      = lookup::get_type_fields(context, type_info, generator.scope);

        uint  field_index = 0;
        Node* field_node;
        foreach (uint i, Node* field : fields) {
            if (field.parameter_node.name.ident_node.name == field_name) {
                field_index = i;
                field_node = field;
                break;
            }
        }

        llvm_type  = lookup::get(context, field_node, generator.scope, generator).llvm_type;
        target_ptr = llvm::build_struct_gep2(generator.llvm_builder, type_info.llvm_type, instance_ptr, field_index, "");
        base_group = lookup::get(context, field_node, generator.scope, generator).type_group;
    } else {
        highlighter::panic("generate_suffix only supports IDENT and ACCESS for now");
    }

    LLVMValueRef old_value = llvm::build_load_2(generator.llvm_builder, llvm_type, target_ptr, "");
    LLVMValueRef new_value;

    switch (node.suffix_node.operator.type) {
    case TokenType.PLUS:
        if (base_group == "pointer") {
            LookupElement suffix_type_data = lookup::get(context, node.suffix_node.node, generator.scope, generator);
            String        elem_type_name   = suffix_type_data.type_name[:suffix_type_data.type_name.len - 1];
            TypeInfo*     elem_type_info    = lookup::get_type_info(context, elem_type_name);
            LLVMValueRef  one               = create_int(llvm::int_type(32), 1);

            new_value = llvm::build_gep2(generator.llvm_builder, elem_type_info.llvm_type, old_value, &one, 1, "");
        } else {
            LLVMValueRef one = create_int(llvm::int_type(32), 1);

            new_value = llvm::build_add(generator.llvm_builder, old_value, one, "");
        }
    case TokenType.MINUS:
        if (base_group == "pointer") {
            LookupElement suffix_type_data = lookup::get(context, node.suffix_node.node, generator.scope, generator);
            String        elem_type_name   = suffix_type_data.type_name[:suffix_type_data.type_name.len - 1];
            TypeInfo*     elem_type_info    = lookup::get_type_info(context, elem_type_name);
            LLVMValueRef  neg_one           = create_int(llvm::int_type(32), -1);

            new_value = llvm::build_gep2(generator.llvm_builder, elem_type_info.llvm_type, old_value, &neg_one, 1, "");
        } else {
            LLVMValueRef one = llvm::const_int(llvm_type, 1, llvm::FALSE);

            new_value = llvm::build_sub(generator.llvm_builder, old_value, one, "");
        }
    case TokenType.BANG:
        new_value = llvm::build_not(generator.llvm_builder, old_value, "");
    default:
        highlighter::panic();
    }

    llvm::build_store(generator.llvm_builder, new_value, target_ptr);

    return old_value;
}

fn LLVMValueRef generate_assign(Generator* generator, CompileContext* context, Node* node) {
    LLVMValueRef target_ptr;
    LLVMTypeRef  target_type;
    Node*        target = node.assign_node.node;

    if (target.type == NodeType.IDENT) {
        VariableInfo* variable_info = scope::get_variable(generator.scope, target.ident_node.name);

        target_ptr  = variable_info.llvm_value;
        target_type = variable_info.llvm_type;
    } else if (target.type == NodeType.ACCESS) {
        String        name          = target.access_node.name.path_node.path;
        VariableInfo* variable_info = scope::get_variable(generator.scope, name);
        LookupElement base          = lookup::get(context, variable_info.node, generator.scope, generator);

        LLVMValueRef instance_ptr = variable_info.llvm_value;

        Node* next = target.access_node.next;

        while (next) {
            String field_name;
            Node*  after;

            switch (next.type) {
            case NodeType.IDENT:
                field_name = next.ident_node.name;
                after      = null;
            case NodeType.ACCESS:
                field_name = next.access_node.name.ident_node.name;
                after      = next.access_node.next;
            default:
                highlighter::panic();
            }

            String base_group = base.type_group;
            String type_name  = base.type_name;

            if (base_group == "pointer") {
                type_name = type_name[:type_name.len - 1];
                instance_ptr = llvm::build_load_2(generator.llvm_builder, base.llvm_type, instance_ptr, "");
            }

            TypeInfo* type_info = lookup::get_type_info(context, type_name);
            NodeList  fields     = lookup::get_type_fields(context, type_info, generator.scope);

            uint  field_index = 0;
            Node* field_node;
            foreach (uint i, Node* field : fields) {
                if (field.parameter_node.name.ident_node.name == field_name) {
                    field_index = i;
                    field_node  = field;
                    break;
                }
            }

            LookupElement field_element = lookup::get(context, field_node, generator.scope, generator);
            LLVMValueRef  field_ptr     = llvm::build_struct_gep2(generator.llvm_builder, type_info.llvm_type, instance_ptr, field_index, "");

            if (after) {
                instance_ptr = field_ptr;
                base         = field_element;
            } else {
                target_ptr  = field_ptr;
                target_type = field_element.llvm_type;
            }

            next = after;
        }
    } else if (target.type == NodeType.DEREFERENCE) {
        target_ptr  = generate_node(generator, context, target.dereference_node.node);
        target_type = lookup::get(context, target.dereference_node.node, generator.scope, generator).llvm_type;
    } else if (target.type == NodeType.INDEX) {
        LLVMValueRef  target_value = generate_node(generator, context, target.index_node.target);
        LookupElement target_data  = lookup::get(context, target.index_node.target, generator.scope, generator);

        String element_type_name = target_data.type_name.ends_with("[]")
            ? target_data.type_name[:target_data.type_name.len - 2]
            : target_data.type_name[:target_data.type_name.len - 1];

        TypeInfo* element_type_info = lookup::get_type_info(context, element_type_name);

        LLVMValueRef index_value = generate_node(generator, context, target.index_node.index);

        LLVMValueRef data_ptr;
        if (target_data.type_name.ends_with("[]")) {
            data_ptr = llvm::build_extract_value(generator.llvm_builder, target_value, 0, "");

            LLVMValueRef len_value = llvm::build_extract_value(generator.llvm_builder, target_value, 1, "");

            emit_bounds_check(generator, context, index_value, len_value, (uint)target.range.from.line);
        } else {
            data_ptr = target_value;
        }

        target_ptr  = llvm::build_gep2(generator.llvm_builder, element_type_info.llvm_type, data_ptr, &index_value, 1, "");
        target_type = element_type_info.llvm_type;
    } else {
        highlighter::panic("generate_assign only supports IDENT, ACCESS, DEREFERENCE, and INDEX for now");
    }

    LLVMValueRef value = generate_node(generator, context, node.assign_node.expr, (void*)target_type);

    LLVMTypeRef value_type = llvm::type_of(value);

    if (target_type != value_type
        && llvm::get_type_kind(target_type) == LLVMTypeKind.INTEGER_TYPE_KIND
        && llvm::get_type_kind(value_type) == LLVMTypeKind.INTEGER_TYPE_KIND) {
        if (llvm::get_int_type_width(value_type) > llvm::get_int_type_width(target_type)) {
            value = llvm::build_trunc(generator.llvm_builder, value, target_type, "");
        } else {
            value = llvm::build_s_ext(generator.llvm_builder, value, target_type, "");
        }
    }

    llvm::build_store(generator.llvm_builder, value, target_ptr);

    return value;
}

fn LLVMValueRef generate_null(Generator* generator, CompileContext* context, Node* node) {
    return llvm::const_null(llvm::pointer_type(llvm::int_8_type(), 0));
}

fn void generate_while(Generator* generator, CompileContext* context, Node* node, void* data) {
    LLVMValueRef condition = generate_node(generator, context, node.while_node.expr);

    LLVMBasicBlockRef current_block = llvm::get_insert_block(generator.llvm_builder);
    LLVMValueRef      llvm_function = llvm::get_basic_block_parent(current_block);

    LLVMBasicBlockRef then_block = llvm::append_basic_block(llvm_function, "");
    LLVMBasicBlockRef end_block  = llvm::append_basic_block(llvm_function, "");

    llvm::build_cond_br(generator.llvm_builder, condition, then_block, end_block);
    llvm::position_builder_at_end(generator.llvm_builder, then_block);

    generator.scope = scope::create(context.alloc, generator.scope);
    generate_compound(generator, context, node.while_node.statements, data);
    
    LLVMValueRef new_condition = generate_node(generator, context, node.while_node.expr);
    llvm::build_cond_br(generator.llvm_builder, new_condition, then_block, end_block);

    generator.scope = generator.scope.parent;

    llvm::position_builder_at_end(generator.llvm_builder, end_block);
}

fn void generate_use(Generator* generator, CompileContext* context, Node* node) {
    String path = node.use_node.path.path_node.path;

    scope::add_import(generator.scope, path);
}

fn LLVMValueRef generate_real(Generator* generator, CompileContext* context, Node* node) {
    LLVMTypeRef real_type = context.lookup.get("real").llvm_type!!;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    return llvm::const_real(real_type, node.real_node.real.to_double())!!;
}

fn LLVMValueRef generate_char(Generator* generator, CompileContext* context, Node* node) {
    LLVMTypeRef char_type = context.lookup.get("char").llvm_type!!;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    return llvm::const_int(char_type, (ulong)node.char_node.character[0], llvm::TRUE);
}

fn void generate_switch(Generator* generator, CompileContext* context, Node* node, void* data) {
    LLVMValueRef  subject      = generate_node(generator, context, node.switch_node.expr);
    LookupElement subject_data = lookup::get(context, node.switch_node.expr, generator.scope);

    LLVMBasicBlockRef current_block = llvm::get_insert_block(generator.llvm_builder);
    LLVMValueRef      llvm_function = llvm::get_basic_block_parent(current_block);

    LLVMBasicBlockRef end_block = llvm::append_basic_block(llvm_function, "");

    generator.break_targets.push(end_block);

    LLVMBasicBlockRef next_check_block = current_block;

    foreach (Node* case_node : node.switch_node.cases) {
        switch (case_node.type) {
        case NodeType.CASE:
            llvm::position_builder_at_end(generator.llvm_builder, next_check_block);

            LLVMValueRef case_value = generate_node(generator, context, case_node.case_node.expr);
            LLVMValueRef cmp;
            if (subject_data.type_group == "string") {
                cmp = build_string_eq(generator, context, subject, case_value);
            } else {
                cmp = llvm::build_i_cmp(generator.llvm_builder, LLVMIntPredicate.INT_EQ, subject, case_value, "");
            }

            LLVMBasicBlockRef case_block = llvm::append_basic_block(llvm_function, "");
            LLVMBasicBlockRef else_check_block = llvm::append_basic_block(llvm_function, "");

            llvm::build_cond_br(generator.llvm_builder, cmp, case_block, else_check_block);

            llvm::position_builder_at_end(generator.llvm_builder, case_block);

            generator.scope = scope::create(context.alloc, generator.scope);

            String narrowed_var;
            String narrowed_type;
            if (util::try_get_typeid_narrowing_switch(node.switch_node.expr, case_node.case_node.expr, &narrowed_var, &narrowed_type)) {
                TypeInfo*   type_info = lookup::get_type_info(context, narrowed_type);
                LLVMTypeRef llvm_type = type_info.llvm_type;
                String      type_group;

                switch (llvm::get_type_kind(llvm_type)) {
                case LLVMTypeKind.INTEGER_TYPE_KIND:
                    type_group = llvm::get_int_type_width(llvm_type) == 1 ? "boolean" : "integer";
                case LLVMTypeKind.POINTER_TYPE_KIND:
                    type_group = "pointer";
                case LLVMTypeKind.STRUCT_TYPE_KIND:
                    type_group = "struct";
                case LLVMTypeKind.DOUBLE_TYPE_KIND:
                    type_group = "real";
                default:
                    highlighter::panic();
                }

                scope::add_narrowed_type(generator.scope, narrowed_var, {
                    .llvm_type  = llvm_type,
                    .type_name  = type_info.name,
                    .type_group = type_group
                });
            }

            generate_compound(generator, context, case_node.case_node.statements, data);

            LLVMBasicBlockRef case_end_block = llvm::get_insert_block(generator.llvm_builder);
            if (!llvm::get_basic_block_terminator(case_end_block)) {
                llvm::build_br(generator.llvm_builder, end_block);
            }

            generator.scope = generator.scope.parent;

            next_check_block = else_check_block;
        case NodeType.DEFAULT:
            llvm::position_builder_at_end(generator.llvm_builder, next_check_block);

            generator.scope = scope::create(context.alloc, generator.scope);
            generate_compound(generator, context, case_node.default_node.statements, data);

            LLVMBasicBlockRef default_end_block = llvm::get_insert_block(generator.llvm_builder);
            if (!llvm::get_basic_block_terminator(default_end_block)) {
                llvm::build_br(generator.llvm_builder, end_block);
            }

            generator.scope = generator.scope.parent;
        default:
            highlighter::panic();
        }
    }

    llvm::position_builder_at_end(generator.llvm_builder, next_check_block);
    if (!llvm::get_basic_block_terminator(next_check_block)) {
        llvm::build_br(generator.llvm_builder, end_block);
    }

    generator.break_targets.pop()!!;

    llvm::position_builder_at_end(generator.llvm_builder, end_block);
}

fn void generate_break(Generator* generator, CompileContext* context, Node* node) {
    LLVMBasicBlockRef target = generator.break_targets[generator.break_targets.len() - 1];
    llvm::build_br(generator.llvm_builder, target);
}

fn LLVMValueRef generate_index(Generator* generator, CompileContext* context, Node* node) {
    LookupElement target_data = lookup::get(context, node.index_node.target, generator.scope, generator);

    String element_type_name;
    if (target_data.type_name.ends_with("[]")) {
        element_type_name = target_data.type_name[:target_data.type_name.len - 2];
    } else if (target_data.type_name.ends_with("]")) {
        sz bracket_pos = target_data.type_name.rindex_of("[")!!;
        element_type_name = target_data.type_name[:bracket_pos];
    } else {
        element_type_name = target_data.type_name[:target_data.type_name.len - 1];
    }

    TypeInfo* element_type_info = lookup::get_type_info(context, element_type_name);
    LLVMValueRef index_value = generate_node(generator, context, node.index_node.index);

    if (target_data.type_name.ends_with("[]")) {
        LLVMValueRef target_value = generate_node(generator, context, node.index_node.target);
        LLVMValueRef data_ptr = llvm::build_extract_value(generator.llvm_builder, target_value, 0, "");
        LLVMValueRef len_value = llvm::build_extract_value(generator.llvm_builder, target_value, 1, "");

        emit_bounds_check(generator, context, index_value, len_value, (uint)node.range.from.line);

        LLVMValueRef target_ptr = llvm::build_gep2(generator.llvm_builder, element_type_info.llvm_type, data_ptr, &index_value, 1, "");

        debug::set_location(generator, context, node.range.from.line, node.range.from.column);
        return llvm::build_load_2(generator.llvm_builder, element_type_info.llvm_type, target_ptr, "");
    }

    if (target_data.type_name.ends_with("]")) {
        Node* target_node = node.index_node.target;

        LLVMValueRef array_ptr;

        if (target_node.type == NodeType.IDENT) {
            VariableInfo* variable_info = scope::get_variable(generator.scope, target_node.ident_node.name);
            array_ptr = variable_info.llvm_value;
        } else if (target_node.type == NodeType.ACCESS) {
            Node*  path = target_node.access_node.name;
            String name = path.path_node.path;

            VariableInfo* variable_info = scope::get_variable(generator.scope, name);

            LookupElement base;
            if (scope::has_narrowed_type(generator.scope, name)) {
                base = scope::get_narrowed_type(generator.scope, name);
            } else {
                base = lookup::get(context, variable_info.node, generator.scope, generator);
            }

            LLVMValueRef instance_ptr = variable_info.llvm_value;
            Node* next = target_node.access_node.next;

            while (next) {
                String field_name;
                Node*  after;

                switch (next.type) {
                case NodeType.IDENT:
                    field_name = next.ident_node.name;
                    after      = null;
                case NodeType.ACCESS:
                    field_name = next.access_node.name.ident_node.name;
                    after      = next.access_node.next;
                default:
                    highlighter::panic();
                }

                String base_group = base.type_group;
                String type_name  = base.type_name;

                if (base_group == "pointer") {
                    type_name = type_name[:type_name.len - 1];
                    instance_ptr = llvm::build_load_2(generator.llvm_builder, base.llvm_type, instance_ptr, "");
                }

                TypeInfo* type_info = lookup::get_type_info(context, type_name);
                NodeList  fields    = lookup::get_type_fields(context, type_info, generator.scope);

                uint  field_index = 0;
                Node* field_node;
                foreach (uint i, Node* field : fields) {
                    if (field.parameter_node.name.ident_node.name == field_name) {
                        field_index = i;
                        field_node  = field;
                        break;
                    }
                }

                if (!field_node) {
                    highlighter::panic("Could not find field '%s' on type '%s'", field_name, type_name);
                }

                LookupElement field_element = lookup::get(context, field_node, generator.scope, generator);
                LLVMValueRef  field_ptr     = llvm::build_struct_gep2(generator.llvm_builder, type_info.llvm_type, instance_ptr, field_index, "");

                instance_ptr = field_ptr;
                base         = field_element;
                next         = after;
            }

            array_ptr = instance_ptr;
        } else {
            highlighter::panic("Indexing a fixed-size array only supports plain identifiers or field access for now");
        }

        TypeInfo* array_type_info = lookup::get_type_info(context, target_data.type_name);

        LLVMValueRef[2] gep_indices = { create_int(llvm::int_32_type(), 0), index_value };
        LLVMValueRef target_ptr = llvm::build_gep2(generator.llvm_builder, array_type_info.llvm_type, array_ptr, &gep_indices, 2, "");

        debug::set_location(generator, context, node.range.from.line, node.range.from.column);
        return llvm::build_load_2(generator.llvm_builder, element_type_info.llvm_type, target_ptr, "");
    }

    LLVMValueRef target_value = generate_node(generator, context, node.index_node.target);
    LLVMValueRef target_ptr = llvm::build_gep2(generator.llvm_builder, element_type_info.llvm_type, target_value, &index_value, 1, "");

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);
    return llvm::build_load_2(generator.llvm_builder, element_type_info.llvm_type, target_ptr, "");
}

fn LLVMValueRef generate_array(Generator* generator, CompileContext* context, Node* node) {
    LookupElement array_data   = lookup::get(context, node, generator.scope, generator);
    String        element_name = array_data.type_name[:array_data.type_name.len - 2];
    TypeInfo*     element_info  = lookup::get_type_info(context, element_name);
    LLVMTypeRef   element_type  = element_info.llvm_type;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    uint        count       = (uint)node.array_node.values.len();
    LLVMTypeRef backing_type = llvm::array_type(element_type, count);
    LLVMValueRef backing     = llvm::build_alloca(generator.llvm_builder, backing_type, "");

    foreach (uint i, Node* value : node.array_node.values) {
        LLVMValueRef value_llvm = generate_node(generator, context, value);

        LLVMValueRef[2] indices = { create_int(llvm::int_32_type(), 0), create_int(llvm::int_32_type(), i) };
        LLVMValueRef element_ptr = llvm::build_gep2(generator.llvm_builder, backing_type, backing, &indices, 2, "");

        llvm::build_store(generator.llvm_builder, value_llvm, element_ptr);
    }

    LLVMTypeRef  slice_type  = array_data.llvm_type;
    LLVMValueRef slice_value = llvm::get_undef(slice_type);

    slice_value = llvm::build_insert_value(generator.llvm_builder, slice_value, backing, 0, "");
    slice_value = llvm::build_insert_value(generator.llvm_builder, slice_value, create_int(llvm::int_32_type(), count), 1, "");

    return slice_value;
}

fn LLVMValueRef generate_trap(Generator* generator, CompileContext* context, Node* node) {
    LLVMTypeRef  trap_fn_type = llvm::function_type(llvm::void_type(), null, 0, llvm::FALSE);
    LLVMValueRef trap_fn      = llvm::get_named_function(generator.llvm_module, "llvm.trap");

    if (trap_fn == null) {
        trap_fn = llvm::add_function(generator.llvm_module, "llvm.trap", trap_fn_type);
    }

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    llvm::build_call_2(generator.llvm_builder, trap_fn_type, trap_fn, null, 0, "");

    return llvm::build_unreachable(generator.llvm_builder);
}

fn LLVMValueRef generate_cast(Generator* generator, CompileContext* context, Node* node, void* data) {
    LookupElement to = lookup::get(context, node.cast_node.type, generator.scope, generator);

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    if (is_data_field_access(node.cast_node.node)) {
        LLVMValueRef ptr_val = generate_node(generator, context, node.cast_node.node, null);
        return llvm::build_load_2(generator.llvm_builder, to.llvm_type, ptr_val, "");
    }

    LookupElement from = lookup::get(context, node.cast_node.node, generator.scope, generator);

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    if (from.type_name.ends_with("[N]") && to.type_name.ends_with("[]")) {
        Node* array_node = node.cast_node.node;

        LLVMValueRef array_ptr;
        if (array_node.type == NodeType.IDENT) {
            VariableInfo* variable_info = scope::get_variable(generator.scope, array_node.ident_node.name);
            array_ptr = variable_info.llvm_value;
        } else {
            highlighter::panic("Array-to-slice cast only supports plain identifiers for now");
        }

        uint array_len = (uint)llvm::get_array_length(from.llvm_type);

        LLVMTypeRef  slice_type  = to.llvm_type;
        LLVMValueRef slice_value = llvm::get_undef(slice_type);

        slice_value = llvm::build_insert_value(generator.llvm_builder, slice_value, array_ptr, 0, "");
        slice_value = llvm::build_insert_value(generator.llvm_builder, slice_value, create_int(llvm::int_32_type(), array_len), 1, "");

        return slice_value;
    }

    LLVMValueRef value = generate_node(generator, context, node.cast_node.node, data);

    if (from.type_group == "pointer" && to.type_group == "pointer") {
        return llvm::build_pointer_cast(generator.llvm_builder, value, to.llvm_type, "");
    }

    if (from.type_group == "real" && to.type_group == "integer") {
        return llvm::build_fp_to_si(generator.llvm_builder, value, to.llvm_type, "");
    }

    if (from.type_group == "integer" && to.type_group == "real") {
        return llvm::build_si_to_fp(generator.llvm_builder, value, to.llvm_type, "");
    }

    if ((from.type_group == "integer" || from.type_group == "boolean" || from.type_group == "character" || from.type_group == "long") &&
        (to.type_group   == "integer" || to.type_group   == "boolean" || to.type_group   == "character" || to.type_group   == "long")) {
        CUInt from_width = llvm::get_int_type_width(from.llvm_type);
        CUInt to_width   = llvm::get_int_type_width(to.llvm_type);

        if (from_width < to_width) {
            return llvm::build_s_ext(generator.llvm_builder, value, to.llvm_type, "");
        }

        if (from_width > to_width) {
            return llvm::build_trunc(generator.llvm_builder, value, to.llvm_type, "");
        }

        return value;
    }

    if (from.type_group == "real" && to.type_group == "real") {
        return value;
    }

    if (from.type_name == "char*" && to.type_name == "String") {
        LLVMValueRef func = llvm::get_basic_block_parent(llvm::get_insert_block(generator.llvm_builder));

        LLVMBasicBlockRef entry_block = llvm::get_insert_block(generator.llvm_builder);
        LLVMBasicBlockRef loop_block  = llvm::append_basic_block(func, "strlen.loop");
        LLVMBasicBlockRef done_block  = llvm::append_basic_block(func, "strlen.done");

        LLVMValueRef entry_ptr = value;

        llvm::build_br(generator.llvm_builder, loop_block);
        llvm::position_builder_at_end(generator.llvm_builder, loop_block);

        LLVMValueRef ptr_phi = llvm::build_phi(generator.llvm_builder, llvm::pointer_type(llvm::int_8_type(), 0), "");
        LLVMValueRef len_phi = llvm::build_phi(generator.llvm_builder, llvm::int_32_type(), "");

        LLVMValueRef[1] entry_ptr_vals = { entry_ptr };
        LLVMBasicBlockRef[1] entry_ptr_blocks = { entry_block };
        llvm::add_incoming(ptr_phi, &entry_ptr_vals, &entry_ptr_blocks, 1);

        LLVMValueRef[1] entry_len_vals = { create_int(llvm::int_32_type(), 0) };
        LLVMBasicBlockRef[1] entry_len_blocks = { entry_block };
        llvm::add_incoming(len_phi, &entry_len_vals, &entry_len_blocks, 1);

        LLVMValueRef byte_val = llvm::build_load_2(generator.llvm_builder, llvm::int_8_type(), ptr_phi, "");
        LLVMValueRef is_null  = llvm::build_i_cmp(generator.llvm_builder, LLVMIntPredicate.INT_EQ, byte_val, create_int(llvm::int_8_type(), 0), "");

        LLVMValueRef[1] gep_indices = { create_int(llvm::int_32_type(), 1) };
        LLVMValueRef next_ptr = llvm::build_gep2(generator.llvm_builder, llvm::int_8_type(), ptr_phi, &gep_indices, 1, "");
        LLVMValueRef next_len = llvm::build_add(generator.llvm_builder, len_phi, create_int(llvm::int_32_type(), 1), "");

        LLVMBasicBlockRef loop_end_block = llvm::get_insert_block(generator.llvm_builder);

        llvm::build_cond_br(generator.llvm_builder, is_null, done_block, loop_block);

        LLVMValueRef[1] loop_ptr_vals = { next_ptr };
        LLVMBasicBlockRef[1] loop_ptr_blocks = { loop_end_block };
        llvm::add_incoming(ptr_phi, &loop_ptr_vals, &loop_ptr_blocks, 1);

        LLVMValueRef[1] loop_len_vals = { next_len };
        LLVMBasicBlockRef[1] loop_len_blocks = { loop_end_block };
        llvm::add_incoming(len_phi, &loop_len_vals, &loop_len_blocks, 1);

        llvm::position_builder_at_end(generator.llvm_builder, done_block);

        LLVMTypeRef  string_type  = to.llvm_type;
        LLVMValueRef string_value = llvm::get_undef(string_type);

        string_value = llvm::build_insert_value(generator.llvm_builder, string_value, entry_ptr, 0, "");
        string_value = llvm::build_insert_value(generator.llvm_builder, string_value, len_phi, 1, "");

        return string_value;
    }

    if (from.type_name == "char[]" && to.type_name == "String") {
        LLVMValueRef slice_slot = llvm::build_alloca(generator.llvm_builder, from.llvm_type, "");
        llvm::build_store(generator.llvm_builder, value, slice_slot);

        LLVMValueRef ptr_gep = llvm::build_struct_gep2(generator.llvm_builder, from.llvm_type, slice_slot, 0, "");
        LLVMValueRef len_gep = llvm::build_struct_gep2(generator.llvm_builder, from.llvm_type, slice_slot, 1, "");

        LLVMValueRef slice_ptr = llvm::build_load_2(generator.llvm_builder, llvm::pointer_type(llvm::int_8_type(), 0), ptr_gep, "");
        LLVMValueRef slice_len = llvm::build_load_2(generator.llvm_builder, llvm::int_32_type(), len_gep, "");

        LLVMTypeRef  string_type  = to.llvm_type;
        LLVMValueRef string_value = llvm::get_undef(string_type);

        string_value = llvm::build_insert_value(generator.llvm_builder, string_value, slice_ptr, 0, "");
        string_value = llvm::build_insert_value(generator.llvm_builder, string_value, slice_len, 1, "");

        return string_value;
    }

    highlighter::panic("Unsupported cast from '%s' to '%s'", from.type_name, to.type_name);
}

fn LLVMValueRef generate_slice(Generator* generator, CompileContext* context, Node* node) {
    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    LookupElement target_data = lookup::get(context, node.slice_node.target, generator.scope, generator);
    LookupElement result_data = lookup::get(context, node, generator.scope, generator);

    LLVMValueRef target_value = generate_node(generator, context, node.slice_node.target);
    LLVMValueRef from_value   = generate_node(generator, context, node.slice_node.index);
    LLVMValueRef to_value     = generate_node(generator, context, node.slice_node.offset);

    LLVMValueRef base_ptr;
    if (target_data.type_name.ends_with("[]")) {
        base_ptr = llvm::build_extract_value(generator.llvm_builder, target_value, 0, "");
    } else {
        base_ptr = target_value;
    }

    LLVMTypeRef elem_type = result_data.llvm_type;

    LLVMValueRef[1] gep_indices = { from_value };
    LLVMValueRef sliced_ptr = llvm::build_gep2(generator.llvm_builder, elem_type, base_ptr, &gep_indices, 1, "");
    LLVMValueRef sliced_len = llvm::build_sub(generator.llvm_builder, to_value, from_value, "");

    LLVMTypeRef  slice_type  = result_data.llvm_type;
    LLVMValueRef slice_value = llvm::get_undef(slice_type);

    slice_value = llvm::build_insert_value(generator.llvm_builder, slice_value, sliced_ptr, 0, "");
    slice_value = llvm::build_insert_value(generator.llvm_builder, slice_value, sliced_len, 1, "");

    return slice_value;
}

fn LLVMValueRef generate_const(Generator* generator, CompileContext* context, Node* node) {
    String      name      = node.const_node.name.path_node.path;
    LLVMTypeRef llvm_type = lookup::get(context, node, generator.scope, generator).llvm_type;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    LLVMValueRef llvm_alloca = llvm::build_alloca(generator.llvm_builder, llvm_type, (CChar*)name.ptr);
    
    if (node.variable_node.value) {
        LLVMValueRef llvm_value = generate_node(generator, context, node.variable_node.value, (void*)llvm_type);
        llvm::build_store(generator.llvm_builder, llvm_value, llvm_alloca);
    } else {
        if (lookup::get(context, node, generator.scope, generator).type_group == "pointer") {
            llvm::build_store(generator.llvm_builder, llvm::const_null(llvm_type), llvm_alloca);
        }
    }

    scope::add_variable(generator.scope, context.alloc, name, node, llvm_type, llvm_alloca);

    return llvm_alloca;
}

fn LLVMValueRef get_or_declare_function(Generator* generator, CompileContext* context, FunctionInfo* function_info) {
    String name;

    switch (function_info.node.type) {
    case NodeType.FUNCTION:
        String pure_name = function_info.node.function_node.name.ident_node.name;

        if (pure_name == "main") {
            name = pure_name;
        } else {
            name = string::format(context.alloc, "%s.%s", function_info.mod, pure_name);
        }
    case NodeType.EXT:
        name = function_info.node.ext_node.name.ident_node.name;
    default:
        highlighter::panic("Unreachable");
    }

    LLVMValueRef existing = llvm::get_named_function(generator.llvm_module, (CChar*)name.ptr);
    if (existing != null) {
        return existing;
    }

    return llvm::add_function(generator.llvm_module, (CChar*)name.ptr, function_info.llvm_type);
}

fn ConstInfo* get_or_declare_const(Generator* generator, CompileContext* context, String name) {
    String module_name    = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
    String qualified_name = string::format(context.alloc, "%s.%s", module_name, name);

    ConstInfo* info = context.registry.constants.get(qualified_name)!!;
    if (!info.llvm_value) {
        LLVMValueRef llvm_value = generate_node(generator, context, info.node.const_node.value, (void*)info.llvm_type);

        info.llvm_value = llvm::add_global(generator.llvm_module, info.llvm_type, (CChar*)info.name.ptr);
        llvm::set_initializer(info.llvm_value, llvm_value);
        llvm::set_global_constant(info.llvm_value, llvm::TRUE);
        llvm::set_linkage(info.llvm_value, LLVMLinkage.PRIVATE_LINKAGE);
    }

    return info;
}

fn LLVMValueRef build_string_eq(Generator* generator, CompileContext* context, LLVMValueRef lhs, LLVMValueRef rhs) {
    LLVMBuilderRef builder = generator.llvm_builder;

    if (llvm::get_type_kind(llvm::type_of(rhs)) == LLVMTypeKind.POINTER_TYPE_KIND) {
        rhs = llvm::build_load_2(builder, llvm::type_of(lhs), rhs, "");
    }

    LLVMValueRef lhs_ptr = llvm::build_extract_value(builder, lhs, 0, "");
    LLVMValueRef lhs_len = llvm::build_extract_value(builder, lhs, 1, "");
    LLVMValueRef rhs_ptr = llvm::build_extract_value(builder, rhs, 0, "");
    LLVMValueRef rhs_len = llvm::build_extract_value(builder, rhs, 1, "");

    LLVMTypeRef i32_type = llvm::int_32_type();
    LLVMTypeRef i1_type  = llvm::int_1_type();
    LLVMTypeRef i8_type  = llvm::int_8_type();

    LLVMValueRef len_eq = llvm::build_i_cmp(builder, LLVMIntPredicate.INT_EQ, lhs_len, rhs_len, "");

    LLVMValueRef function = llvm::get_basic_block_parent(llvm::get_insert_block(builder));

    LLVMBasicBlockRef loop_cond = llvm::append_basic_block(function, "streq.cond");
    LLVMBasicBlockRef loop_body = llvm::append_basic_block(function, "streq.body");
    LLVMBasicBlockRef mismatch  = llvm::append_basic_block(function, "streq.mismatch");
    LLVMBasicBlockRef done      = llvm::append_basic_block(function, "streq.done");

    LLVMBasicBlockRef entry_block = llvm::get_insert_block(builder);
    llvm::build_cond_br(builder, len_eq, loop_cond, mismatch);

    llvm::position_builder_at_end(builder, loop_cond);
    LLVMValueRef index = llvm::build_phi(builder, i32_type, "");
    LLVMValueRef in_bounds = llvm::build_i_cmp(builder, LLVMIntPredicate.INT_ULT, index, lhs_len, "");
    llvm::build_cond_br(builder, in_bounds, loop_body, done);

    llvm::position_builder_at_end(builder, loop_body);
    LLVMValueRef lhs_elem_ptr = llvm::build_in_bounds_gep2(builder, i8_type, lhs_ptr, &index, 1, "");
    LLVMValueRef rhs_elem_ptr = llvm::build_in_bounds_gep2(builder, i8_type, rhs_ptr, &index, 1, "");
    LLVMValueRef lhs_byte     = llvm::build_load_2(builder, i8_type, lhs_elem_ptr, "");
    LLVMValueRef rhs_byte     = llvm::build_load_2(builder, i8_type, rhs_elem_ptr, "");
    LLVMValueRef byte_eq      = llvm::build_i_cmp(builder, LLVMIntPredicate.INT_EQ, lhs_byte, rhs_byte, "");
    LLVMValueRef next_index   = llvm::build_add(builder, index, create_int(i32_type, 1), "");
    llvm::build_cond_br(builder, byte_eq, loop_cond, mismatch);

    LLVMValueRef[] index_incoming_values  = { create_int(i32_type, 0), next_index };
    LLVMBasicBlockRef[] index_incoming_blocks = { entry_block, loop_body };
    llvm::add_incoming(index, index_incoming_values, index_incoming_blocks, 2);

    llvm::position_builder_at_end(builder, mismatch);
    llvm::build_br(builder, done);

    llvm::position_builder_at_end(builder, done);
    LLVMValueRef result = llvm::build_phi(builder, i1_type, "");
    LLVMValueRef[] result_incoming_values  = { create_int(i1_type, 1), create_int(i1_type, 0) };
    LLVMBasicBlockRef[] result_incoming_blocks = { loop_cond, mismatch };
    llvm::add_incoming(result, result_incoming_values, result_incoming_blocks, 2);

    return result;
}

fn LLVMValueRef create_int(LLVMTypeRef int_type, ulong value) {
    return llvm::const_int(int_type, (CULongLong)value, llvm::TRUE);
}

fn LLVMValueRef get_reflection_value(Generator* generator, CompileContext* context, LookupElement base, String field_name, LLVMValueRef instance_ptr = null, void* data = null) {
    switch (field_name) {
    case "$size":
        int size = lookup::get_type_size(context, generator.scope, base);

        return create_int(lookup::get_type_info(context, "int").llvm_type, (ulong)size);
    case "$typeid":
        if (base.type_name == "any" && instance_ptr) {
            LLVMTypeRef  any_type = lookup::get_type_info(context, "any").llvm_type;
            LLVMValueRef any_val  = llvm::build_load_2(generator.llvm_builder, any_type, instance_ptr, "");
            LLVMValueRef desc_ptr = llvm::build_extract_value(generator.llvm_builder, any_val, 1, "");
            LLVMValueRef desc_val = llvm::build_load_2(generator.llvm_builder, llvm::int_64_type(), desc_ptr, "");

            return llvm::build_trunc(generator.llvm_builder, desc_val, llvm::int_32_type(), "");
        }

        int type_id = 5381;

        foreach (char c : base.type_name) {
            type_id = ((type_id << 5) + type_id) + c;
        }

        return create_int(lookup::get_type_info(context, "int").llvm_type, (ulong)type_id);
    case "$data":
        LLVMTypeRef  any_type = lookup::get_type_info(context, "any").llvm_type;
        LLVMValueRef any_val  = llvm::build_load_2(generator.llvm_builder, any_type, instance_ptr, "");
        LLVMValueRef ptr_val  = llvm::build_extract_value(generator.llvm_builder, any_val, 0, "");

        if (data) {
            LLVMTypeRef expected_type = (LLVMTypeRef)data;
            return llvm::build_load_2(generator.llvm_builder, expected_type, ptr_val, "");
        }

        return ptr_val;
    case "$typekind":
        if (base.type_name == "any" && instance_ptr) {
            LLVMTypeRef  any_type = lookup::get_type_info(context, "any").llvm_type;
            LLVMValueRef any_val  = llvm::build_load_2(generator.llvm_builder, any_type, instance_ptr, "");
            LLVMValueRef desc_ptr = llvm::build_extract_value(generator.llvm_builder, any_val, 1, "");
            LLVMValueRef desc_val = llvm::build_load_2(generator.llvm_builder, llvm::int_64_type(), desc_ptr, "");
            LLVMValueRef shifted  = llvm::build_l_shr(generator.llvm_builder, desc_val, create_int(llvm::int_64_type(), 32), "");

            return llvm::build_trunc(generator.llvm_builder, shifted, llvm::int_32_type(), "");
        }

        int kind = -1;
        switch (llvm::get_type_kind(base.llvm_type)) {
        case LLVMTypeKind.STRUCT_TYPE_KIND:
            kind = 0;
        case LLVMTypeKind.POINTER_TYPE_KIND:
            kind = 1;
        }

        return create_int(lookup::get_type_info(context, "int").llvm_type, (ulong)kind);
    default:
        highlighter::panic("'%s' unhandled", field_name);
    }
}

fn LLVMValueRef get_builtin(CompileContext* context, String field_name) {
    switch (field_name) {
    case "$$STRUCT":
        return create_int(lookup::get_type_info(context, "int").llvm_type, 0);
    case "$$POINTER":
        return create_int(lookup::get_type_info(context, "int").llvm_type, 1);
    default:
        highlighter::panic("'%s' unhandled", field_name);
    }
}

fn LLVMValueRef make_any(Generator* generator, CompileContext* context, LLVMValueRef value, TypeInfo* value_type_info) {
    LLVMValueRef slot = llvm::build_alloca(generator.llvm_builder, value_type_info.llvm_type, "");
    llvm::build_store(generator.llvm_builder, value, slot);

    int type_id = 5381;
    foreach (char c : value_type_info.name) {
        type_id = ((type_id << 5) + type_id) + c;
    }

    int kind = -1;
    switch (llvm::get_type_kind(value_type_info.llvm_type)) {
    case LLVMTypeKind.STRUCT_TYPE_KIND:
        kind = 0;
    case LLVMTypeKind.POINTER_TYPE_KIND:
        kind = 1;
    }

    ulong combined = ((ulong)(uint)kind << 32) | (uint)type_id;

    LLVMValueRef desc_global;
    if (!context.registry.type_ids.has_key(value_type_info.name)) {
        LLVMTypeRef i64_type = llvm::int_64_type();
        desc_global = llvm::add_global(generator.llvm_module, i64_type, "");

        llvm::set_initializer(desc_global, create_int(i64_type, combined));
        llvm::set_global_constant(desc_global, llvm::TRUE);
        llvm::set_unnamed_addr(desc_global, llvm::TRUE);
        llvm::set_linkage(desc_global, LLVMLinkage.PRIVATE_LINKAGE);

        context.registry.type_ids.set(value_type_info.name, desc_global);
    } else {
        desc_global = context.registry.type_ids.get(value_type_info.name)!!;
    }

    LLVMTypeRef  any_type = lookup::get_type_info(context, "any").llvm_type;
    LLVMValueRef any_val  = llvm::get_undef(any_type);

    any_val = llvm::build_insert_value(generator.llvm_builder, any_val, slot, 0, "");
    any_val = llvm::build_insert_value(generator.llvm_builder, any_val, desc_global, 1, "");

    return any_val;
}

fn bool is_data_field_access(Node* node) {
    if (node.type != NodeType.ACCESS) {
        return false;
    }

    Node* next = node.access_node.next;
    while (next && next.type == NodeType.ACCESS) {
        next = next.access_node.next;
    }

    return next && next.type == NodeType.IDENT && next.ident_node.name == "$data";
}

fn void emit_bounds_check(Generator* generator, CompileContext* context, LLVMValueRef index_value, LLVMValueRef len_value, uint line) {
    FunctionInfo* function_info = lookup::get_function_info(context, "std.core.builtin.bounds_check");
    LLVMValueRef  callee        = get_or_declare_function(generator, context, function_info);

    LLVMValueRef file_value = generate_file_string(generator, context);

    LLVMValueRef file_ptr_value = llvm::build_extract_value(generator.llvm_builder, file_value, 0, "");
    LLVMValueRef file_len_value = llvm::build_extract_value(generator.llvm_builder, file_value, 1, "");

    LLVMValueRef line_value = create_int(llvm::int_32_type(), line);

    LLVMValueRef[5] arguments = { index_value, len_value, file_ptr_value, file_len_value, line_value };

    llvm::build_call_2(generator.llvm_builder, function_info.llvm_type, callee, &arguments, 5, "");
}

fn LLVMValueRef generate_file_string(Generator* generator, CompileContext* context) {
    String file = context.current_file;

    LLVMValueRef bytes_const  = llvm::const_string((CChar*)file.ptr, file.len, llvm::FALSE);
    LLVMTypeRef  bytes_type   = llvm::type_of(bytes_const);
    LLVMValueRef bytes_global = llvm::add_global(generator.llvm_module, bytes_type, "");

    llvm::set_initializer(bytes_global, bytes_const);
    llvm::set_global_constant(bytes_global, llvm::TRUE);
    llvm::set_linkage(bytes_global, LLVMLinkage.PRIVATE_LINKAGE);
    llvm::set_unnamed_addr(bytes_global, llvm::TRUE);

    LLVMTypeRef  string_type = context.lookup.get("String").llvm_type!!;
    LLVMValueRef len_const   = llvm::const_int(llvm::int_32_type(), file.len, llvm::FALSE);
    LLVMValueRef[2] fields   = { bytes_global, len_const };

    return llvm::const_named_struct(string_type, &fields, 2);
}

fn void emit(Generator* generator, CompileContext* context) {
    if (!context.args.no_debug) {
        llvm::di_builder_finalize(generator.llvm_debug_builder);
    }

    CChar*        target_triple = llvm::get_default_target_triple();
    LLVMTargetRef target;

    llvm::initialize_x86_target_info();
    llvm::initialize_x86_target();
    llvm::initialize_x86_target_mc();
    llvm::initialize_x86_asm_parser();
    llvm::initialize_x86_asm_printer();

    CChar* error = null;
    if (llvm::get_target_from_triple(target_triple, &target, &error) != 0) {
        io::eprintn((ZString)error);
        os::exit(1);
    }

    llvm::set_target(generator.llvm_module, target_triple);

    LLVMTargetMachineRef target_machine = llvm::create_target_machine(
        target,
        target_triple,
        "generic",
        "+avx2",
        LLVMCodeGenOptLevel.CODE_GEN_LEVEL_DEFAULT,
        LLVMRelocMode.RELOC_DEFAULT,
        LLVMCodeModel.CODE_MODEL_DEFAULT
    );

    LLVMTargetDataRef data_layout     = llvm::create_target_data_layout(target_machine);
    CChar*            data_layout_str = llvm::copy_string_rep_of_target_data(data_layout);

    llvm::set_data_layout(generator.llvm_module, data_layout_str);
    llvm::dispose_target_data(data_layout);

    if (context.args.emit_ir) {
        if (llvm::print_module_to_file(generator.llvm_module, (CChar*)string::format(context.alloc, "out/ir/%s.ll", generator.module_name), &error) != 0) {
            io::eprintn((ZString)error);
            llvm::dispose_message(error);
        }
    }

    CChar* verify_error = null;
    if (llvm::verify_module(generator.llvm_module, LLVMVerifierFailureAction.PRINT_MESSAGE_ACTION, &verify_error) != 0) {
        io::eprintn((ZString)verify_error);
        io::eprintfn("module: %s", generator.module_name);
        llvm::dispose_message(verify_error);
        os::exit(1);
    }

    if (llvm::target_machine_emit_to_file(target_machine, generator.llvm_module, (CChar*)string::format(context.alloc, "out/obj/%s.o", generator.module_name), LLVMCodeGenFileType.OBJECT_FILE, &error))
    {
        io::eprintfn("Failed to emit object file: %s", (ZString)error);
        llvm::dispose_message(error);
        os::exit(1);
    }
}

fn void free(Generator* generator, CompileContext* context) {
    scope::free(generator.scope);

    llvm::dispose_module(generator.llvm_module);
    llvm::dispose_builder(generator.llvm_builder);
}
