module nina::generator;

import llvm;

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

fn void* generate_node(Generator* generator, CompileContext* context, Node* node) {
    switch (node.type) {
    case NodeType.MOD:                generate_mod(generator, context, node);
    case NodeType.FUNCTION:           generate_function(generator, context, node);
    case NodeType.RET:                generate_ret(generator, context, node);
    case NodeType.INT:         return generate_int(generator, context, node);
    case NodeType.EXT:                generate_ext(generator, context, node);
    case NodeType.CALL:        return generate_call(generator, context, node);
    case NodeType.BOOL:        return generate_bool(generator, context, node);
    case NodeType.STRING:      return generate_string(generator, context, node);
    case NodeType.BIN:         return generate_bin(generator, context, node);
    case NodeType.IDENT:       return generate_ident(generator, context, node);
    case NodeType.VARIABLE:    return generate_variable(generator, context, node);
    case NodeType.USE:                generate_use(generator, context, node);
    case NodeType.ACCESS:      return generate_access(generator, context, node);
    case NodeType.UNARY:       return generate_unary(generator, context, node);
    case NodeType.IF:                 generate_if(generator, context, node);
    case NodeType.STRUCT:             generate_struct(generator, context, node);
    case NodeType.INIT:        return generate_init(generator, context, node);
    case NodeType.REFERENCE:   return generate_reference(generator, context, node);
    case NodeType.DEREFERENCE: return generate_dereference(generator, context, node);
    case NodeType.SUFFIX:      return generate_suffix(generator, context, node);
    case NodeType.ASSIGN:             generate_assign(generator, context, node);
    case NodeType.NULL:        return generate_null(generator, context, node);
    case NodeType.WHILE:              generate_while(generator, context, node);
    case NodeType.REAL:        return generate_real(generator, context, node);
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

    foreach (CUInt index, Node* parameter : node.function_node.parameters) {
        String       parameter_name       = parameter.parameter_node.name.ident_node.name;
        LLVMTypeRef  llvm_parameter_type  = lookup::get(context, parameter, generator.scope, generator).llvm_type;
        LLVMValueRef llvm_parameter_value = llvm::get_param(function_info.llvm_value, index);

        LLVMValueRef alloca = llvm::build_alloca(generator.llvm_builder, llvm_parameter_type, "");
        llvm::build_store(generator.llvm_builder, llvm_parameter_value, alloca);

        scope::add_variable(generator.scope, context.alloc, parameter_name, parameter, llvm_parameter_type, alloca);
        debug::add_parameter(generator, context, parameter, llvm_function_value, llvm_parameter_value, index);
    }

    bool returned = generate_compound(generator, context, node.function_node.statements);

    generator.scope = generator.scope.parent;

    if (!returned && lookup::get(context, node, generator.scope, generator).type_name == "void")
    {
        llvm::build_ret_void(generator.llvm_builder);
    }

    llvm::build_unreachable(generator.llvm_builder);
}

fn void generate_ret(Generator* generator, CompileContext* context, Node* node) {
    Node* value = node.ret_node.value;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    if (value) {
        llvm::build_ret(generator.llvm_builder, generate_node(generator, context, value));
    } else {
        llvm::build_ret_void(generator.llvm_builder);
    }
}

fn LLVMValueRef generate_int(Generator* generator, CompileContext* context, Node* node) {
    LLVMTypeRef int_type = context.lookup.get("int").llvm_type!!;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    // if (data) {
    //     Node* parameter_type = data;
    //     if (!parameter_type.parameter_node.vaarg) {
    //         int_type = lookup::get_llvm_type(context, parameter_type, generator.scope);
    //     }
    // }

    return create_int(int_type, node.int_node.number.to_int())!!;
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

        arguments.push(generate_node(generator, context, argument));
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

fn LLVMValueRef generate_string(Generator* generator, CompileContext* context, Node* node) {
    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    LLVMValueRef bytes_const  = llvm::const_string((CChar*)node.string_node.string.ptr, node.string_node.string.len, llvm::FALSE);
    LLVMTypeRef  bytes_type   = llvm::type_of(bytes_const);
    LLVMValueRef bytes_global = llvm::add_global(generator.llvm_module, bytes_type, "");

    llvm::set_initializer(bytes_global, bytes_const);
    llvm::set_global_constant(bytes_global, llvm::TRUE);
    llvm::set_linkage(bytes_global, LLVMLinkage.PRIVATE_LINKAGE);
    llvm::set_unnamed_addr(bytes_global, llvm::TRUE);

    LLVMTypeRef  string_type         = context.lookup.get("String").llvm_type!!;
    LLVMValueRef len_const           = llvm::const_int(llvm::int_32_type(), node.string_node.string.len, llvm::FALSE);
    LLVMValueRef[2] fields           = { bytes_global, len_const };
    LLVMValueRef string_struct_const = llvm::const_named_struct(string_type, &fields, 2);

    LLVMValueRef global = llvm::add_global(generator.llvm_module, string_type, "");
    llvm::set_initializer(global, string_struct_const);
    llvm::set_global_constant(global, llvm::TRUE);
    llvm::set_linkage(global, LLVMLinkage.PRIVATE_LINKAGE);
    llvm::set_unnamed_addr(global, llvm::TRUE);

    @todo("revert to returning the String struct once reflection exists for String.ptr");
    // return global;
    return bytes_global;
}

fn LLVMValueRef generate_bin(Generator* generator, CompileContext* context, Node* node) {
    LLVMValueRef  left      = generate_node(generator, context, node.bin_node.left);
    LLVMValueRef  right     = generate_node(generator, context, node.bin_node.right);
    LookupElement left_data = lookup::get(context, node.bin_node.left, generator.scope);
    String        type      = left_data.type_group;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    switch (node.bin_node.operator.type) {
    case TokenType.PLUS:
        if (type == "pointer") {
            String    element_type_name = left_data.type_name[:left_data.type_name.len - 1];
            TypeInfo* element_type_info  = lookup::get_type_info(context, element_type_name);

            return llvm::build_gep2(generator.llvm_builder, element_type_info.llvm_type, left, &right, 1, "");
        }

        return llvm::build_add(generator.llvm_builder, left, right, "");
    case TokenType.MINUS:
        if (type == "pointer") {
            String    element_type_name = left_data.type_name[:left_data.type_name.len - 1];
            TypeInfo* element_type_info  = lookup::get_type_info(context, element_type_name);

            LLVMValueRef neg_right = llvm::build_neg(generator.llvm_builder, right, "");

            return llvm::build_gep2(generator.llvm_builder, element_type_info.llvm_type, left, &neg_right, 1, "");
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
    case TokenType.RANGLE:
    case TokenType.LANGLE:
    case TokenType.LTE:
    case TokenType.IS_EQUAL:
    case TokenType.NOT_EQUAL:
    case TokenType.GTE: {
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
    }
    default:
        highlighter::panic("Missing generate_bin case for operator type '%s'", node.bin_node.operator.type);
    }
}

fn LLVMValueRef generate_ident(Generator* generator, CompileContext* context, Node* node) {
    VariableInfo* variable_info = scope::get_variable(generator.scope, node.ident_node.name);

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    return llvm::build_load_2(generator.llvm_builder, variable_info.llvm_type, variable_info.llvm_value, "");
}

fn LLVMValueRef generate_variable(Generator* generator, CompileContext* context, Node* node) {
    String       name        = node.variable_node.name.path_node.path;
    LLVMTypeRef  llvm_type   = lookup::get(context, node, generator.scope, generator).llvm_type;

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    LLVMValueRef llvm_alloca = llvm::build_alloca(generator.llvm_builder, llvm_type, (CChar*)name.ptr);
    
    if (node.variable_node.value) {
        LLVMValueRef llvm_value = generate_node(generator, context, node.variable_node.value);
        llvm::build_store(generator.llvm_builder, llvm_value, llvm_alloca);
    }

    scope::add_variable(generator.scope, context.alloc, name, node, llvm_type, llvm_alloca);

    return llvm_alloca;
}

fn bool generate_compound(Generator* generator, CompileContext* context, NodeList statements)
{
    bool returned;

    foreach (int index, Node* statement : statements)
    {
        if (returned) {
            continue;
        }

        if (statement.type == NodeType.RET && index != statements.len() - 1)
        {
            returned = true;
        }

        generate_node(generator, context, statement);
    }

    return returned;
}

fn LLVMValueRef generate_access(Generator* generator, CompileContext* context, Node* node) => @pool() {
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

                arguments.push(generate_node(generator, context, argument));
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

    // -- variable access --
    String        variable_name = node.access_node.name.path_node.path;
    VariableInfo* variable_info = scope::get_variable(generator.scope, variable_name);
    LookupElement type_data     = lookup::get(context, variable_info.node, generator.scope, generator);

    String base_group = type_data.type_group;
    String type_name  = type_data.type_name;

    if (base_group == "pointer") {
        type_name = type_name[:type_name.len - 1];
    }

    TypeInfo*    type_info    = lookup::get_type_info(context, type_name);
    LLVMValueRef instance_ptr = variable_info.llvm_value;

    if (base_group == "pointer") {
        LLVMTypeRef ptr_llvm_type = type_data.llvm_type;

        instance_ptr = llvm::build_load_2(generator.llvm_builder, ptr_llvm_type, instance_ptr, "");
    }

    String   field_name = node.access_node.next.ident_node.name;
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

    LLVMTypeRef  field_llvm_type = lookup::get(context, field_node, generator.scope, generator).llvm_type;
    LLVMValueRef field_ptr       = llvm::build_struct_gep2(generator.llvm_builder, type_info.llvm_type, instance_ptr, field_index, "");

    return llvm::build_load_2(generator.llvm_builder, field_llvm_type, field_ptr, "");
}

fn LLVMValueRef generate_unary(Generator* generator, CompileContext* context, Node* node) {
    LLVMValueRef llvm_value = generate_node(generator, context, node.unary_node.node);
    LLVMValueRef llvm_type  = lookup::get(context, node.unary_node.node, generator.scope, generator).llvm_type;

    switch (node.unary_node.operator.type) {
    case TokenType.MINUS:
        if (lookup::get(context, node, generator.scope, generator).type_group == "integer") {
            LLVMTypeRef int_type = context.lookup.get("int").llvm_type!!;
            
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
    default:
        highlighter::panic();
    }
}

fn void generate_if(Generator* generator, CompileContext* context, Node* node) {
    LLVMValueRef condition = generate_node(generator, context, node.if_node.condition);

    LLVMBasicBlockRef current_block = llvm::get_insert_block(generator.llvm_builder);
    LLVMValueRef      llvm_function = llvm::get_basic_block_parent(current_block);

    LLVMBasicBlockRef then_block = llvm::append_basic_block(llvm_function, "");
    LLVMBasicBlockRef else_block = llvm::append_basic_block(llvm_function, "");
    LLVMBasicBlockRef end_block  = llvm::append_basic_block(llvm_function, "");

    llvm::build_cond_br(generator.llvm_builder, condition, then_block, else_block);

    // -- THEN --
    generator.scope = scope::create(context.alloc, generator.scope);

    llvm::position_builder_at_end(generator.llvm_builder, then_block);

    generate_compound(generator, context, node.if_node.then_statements);

    LLVMBasicBlockRef then_end_block = llvm::get_insert_block(generator.llvm_builder);
    if (!llvm::get_basic_block_terminator(then_end_block)) {
        llvm::build_br(generator.llvm_builder, end_block);
    }

    generator.scope = generator.scope.parent;

    llvm::position_builder_at_end(generator.llvm_builder, else_block);
    if (node.if_node.else_if)
    {
        // -- ELSE IF --
        generate_node(generator, context, node.if_node.else_if);

        LLVMBasicBlockRef else_end_block = llvm::get_insert_block(generator.llvm_builder);
        if (!llvm::get_basic_block_terminator(else_end_block)) {
            llvm::build_br(generator.llvm_builder, end_block);
        }
    } else
    {
        // -- ELSE --
        generator.scope = scope::create(context.alloc, generator.scope);

        generate_compound(generator, context, node.if_node.else_statements);

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

fn LLVMValueRef generate_reference(Generator* generator, CompileContext* context, Node* node) {
    Node* inner = node.reference_node.node;

    if (inner.type == NodeType.IDENT) {
        VariableInfo* variable_info = scope::get_variable(generator.scope, inner.ident_node.name);

        return variable_info.llvm_value;
    }

    LLVMValueRef llvm_value = generate_node(generator, context, inner);
    LLVMTypeRef  llvm_type  = lookup::get(context, node, generator.scope, generator).llvm_type;
    LLVMValueRef alloca     = llvm::build_alloca(generator.llvm_builder, llvm_type, "");

    llvm::build_store(generator.llvm_builder, llvm_value, alloca);

    return alloca;
}

fn LLVMValueRef generate_dereference(Generator* generator, CompileContext* context, Node* node) {
    LLVMValueRef  llvm_value = generate_node(generator, context, node.dereference_node.node);
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
    Node*        target = node.assign_node.node;

    if (target.type == NodeType.IDENT) {
        VariableInfo* variable_info = scope::get_variable(generator.scope, target.ident_node.name);

        target_ptr = variable_info.llvm_value;
    } else if (target.type == NodeType.ACCESS) {
        String        name          = target.access_node.name.path_node.path;
        VariableInfo* variable_info = scope::get_variable(generator.scope, name);
        LookupElement type_data     = lookup::get(context, variable_info.node, generator.scope, generator);
        String        access_group  = type_data.type_group;
        String        type_name     = type_data.type_name;

        if (access_group == "pointer") {
            type_name = type_name[:type_name.len - 1];
        }

        TypeInfo*    type_info    = lookup::get_type_info(context, type_name);
        LLVMValueRef instance_ptr = variable_info.llvm_value;

        if (access_group == "pointer") {
            LLVMTypeRef ptr_llvm_type = lookup::get(context, variable_info.node, generator.scope, generator).llvm_type;

            instance_ptr = llvm::build_load_2(generator.llvm_builder, ptr_llvm_type, instance_ptr, "");
        }

        String   field_name = target.access_node.next.ident_node.name;
        NodeList fields      = lookup::get_type_fields(context, type_info, generator.scope);

        uint field_index = 0;
        foreach (uint i, Node* field : fields) {
            if (field.parameter_node.name.ident_node.name == field_name) {
                field_index = i;
                break;
            }
        }

        target_ptr = llvm::build_struct_gep2(generator.llvm_builder, type_info.llvm_type, instance_ptr, field_index, "");
    } else if (target.type == NodeType.DEREFERENCE) {
        target_ptr = generate_node(generator, context, target.dereference_node.node);
    } else {
        highlighter::panic("generate_assign only supports IDENT, ACCESS, and DEREFERENCE for now");
    }

    LLVMValueRef value = generate_node(generator, context, node.assign_node.expr);

    llvm::build_store(generator.llvm_builder, value, target_ptr);

    return value;
}

fn LLVMValueRef generate_null(Generator* generator, CompileContext* context, Node* node) {
    return llvm::const_null(llvm::pointer_type(llvm::int_8_type(), 0));
}

fn void generate_while(Generator* generator, CompileContext* context, Node* node) {
    LLVMValueRef condition = generate_node(generator, context, node.while_node.expr);

    LLVMBasicBlockRef current_block = llvm::get_insert_block(generator.llvm_builder);
    LLVMValueRef      llvm_function = llvm::get_basic_block_parent(current_block);

    LLVMBasicBlockRef then_block = llvm::append_basic_block(llvm_function, "");
    LLVMBasicBlockRef end_block  = llvm::append_basic_block(llvm_function, "");

    llvm::build_cond_br(generator.llvm_builder, condition, then_block, end_block);
    llvm::position_builder_at_end(generator.llvm_builder, then_block);

    generator.scope = scope::create(context.alloc, generator.scope);
    generate_compound(generator, context, node.while_node.statements);
    
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

fn LLVMValueRef create_int(LLVMTypeRef int_type, int value) {
    return llvm::const_int(int_type, (CULongLong)value, llvm::TRUE);
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
