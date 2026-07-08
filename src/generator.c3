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

fn void* generate_node(Generator* generator, CompileContext* context, Node* node, void* data = null) {
    switch (node.type) {
    case NodeType.MOD:
        generate_mod(generator, context, node);
    case NodeType.FUNCTION:
        generate_function(generator, context, node);
    case NodeType.RET:
        generate_ret(generator, context, node, data);
    case NodeType.INT:
        return generate_int(generator, context, node, data);
    case NodeType.EXT:
        generate_ext(generator, context, node);
    case NodeType.CALL:
        return generate_call(generator, context, node);
    case NodeType.BOOL:
        return generate_bool(generator, context, node);
    case NodeType.STRING:
        return generate_string(generator, context, node);
    case NodeType.BIN:
        return generate_bin(generator, context, node);
    case NodeType.IDENT:
        return generate_ident(generator, context, node, data);
    case NodeType.VARIABLE:
        return generate_variable(generator, context, node);
    case NodeType.USE:
        break;
    case NodeType.ACCESS:
        return generate_access(generator, context, node);
    case NodeType.UNARY:
        return generate_unary(generator, context, node);
    case NodeType.IF:
        generate_if(generator, context, node);
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
    Node*         type          = node.function_node.type;
    String        full_name     = string::tformat("%s.%s", generator.module_name, name);
    FunctionInfo* function_info = context.functions.get(full_name)!!;

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
        LLVMTypeRef  llvm_parameter_type  = lookup::get_llvm_type(context.lookup, parameter);
        LLVMValueRef llvm_parameter_value = llvm::get_param(function_info.llvm_value, index);

        LLVMValueRef alloca = llvm::build_alloca(generator.llvm_builder, llvm_parameter_type, "");
        llvm::build_store(generator.llvm_builder, llvm_parameter_value, alloca);

        scope::add_variable(generator.scope, context.alloc, parameter_name, parameter, llvm_parameter_type, alloca);
        debug::add_parameter(generator, context, parameter, llvm_function_value, llvm_parameter_value, index);
    }

    bool returned = generate_compound(generator, context, node.function_node.statements, type);

    generator.scope = generator.scope.parent;

    if (!returned && lookup::get_type_name(context.lookup, context.alloc, node, generator.scope) == "void")
    {
        llvm::build_ret_void(generator.llvm_builder);
    }

    llvm::build_unreachable(generator.llvm_builder);
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
        Node* parameter_type = data;
        if (!parameter_type.parameter_node.vaarg) {
            int_type = lookup::get_llvm_type(context.lookup, parameter_type);
        }
    }

    return create_int(int_type, node.int_node.number.to_int())!!;
}

fn void generate_ext(Generator* generator, CompileContext* context, Node* node) => @pool() {
    String        name          = node.ext_node.name.ident_node.name;
    String        full_name     = string::tformat("%s.%s", generator.module_name, name);
    FunctionInfo* function_info = context.functions.get(full_name)!!;

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

    debug::add_function(generator, context, node, llvm_function_value);
}

fn LLVMValueRef generate_call(Generator* generator, CompileContext* context, Node* node) => @pool() {
    String        name          = node.call_node.name.path_node.path;
    String        full_name     = string::tformat("%s.%s", generator.module_name, name);
    FunctionInfo* function_info = scope::get_function(generator.scope, name);
    if (!function_info) {
        function_info = context.functions.get(full_name)!!;
    }
    
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

        arguments.push(generate_node(generator, context, argument, parameter_type));
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
    LLVMValueRef left  = generate_node(generator, context, node.bin_node.left);
    LLVMValueRef right = generate_node(generator, context, node.bin_node.right);
    String       type  = lookup::get_base_type_group(context.lookup, context.alloc, node.bin_node.left, generator.scope);

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    switch (node.bin_node.operator.type) {
    case TokenType.PLUS:
        return llvm::build_add(generator.llvm_builder, left, right, "");
    case TokenType.MINUS:
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
        if (type == "real") {
            return llvm::build_f_cmp(generator.llvm_builder, LLVMRealPredicate.REAL_OGT, left, right, "");
        }

        return llvm::build_i_cmp(generator.llvm_builder, LLVMIntPredicate.INT_SGT, left, right, "");
    case TokenType.LANGLE:
        if (type == "real") {
            return llvm::build_f_cmp(generator.llvm_builder, LLVMRealPredicate.REAL_OLT, left, right, "");
        }

        return llvm::build_i_cmp(generator.llvm_builder, LLVMIntPredicate.INT_SLT, left, right, "");
    case TokenType.LTE:
        if (type == "real") {
            return llvm::build_f_cmp(generator.llvm_builder, LLVMRealPredicate.REAL_OLE, left, right, "");
        }

        return llvm::build_i_cmp(generator.llvm_builder, LLVMIntPredicate.INT_SLE, left, right, "");
    case TokenType.IS_EQUAL:
        if (type == "real") {
            return llvm::build_f_cmp(generator.llvm_builder, LLVMRealPredicate.REAL_OEQ, left, right, "");
        }

        return llvm::build_i_cmp(generator.llvm_builder, LLVMIntPredicate.INT_EQ, left, right, "");
    default:
        highlighter::panic("Missing generate_bin case for operator type '%s'", node.bin_node.operator.type);
    }
}

fn LLVMValueRef generate_ident(Generator* generator, CompileContext* context, Node* node, void* data) {
    VariableInfo* variable_info = scope::get_variable(generator.scope, node.ident_node.name);

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    return llvm::build_load_2(generator.llvm_builder, variable_info.llvm_type, variable_info.llvm_value, "");
}

fn LLVMValueRef generate_variable(Generator* generator, CompileContext* context, Node* node) {
    String       name        = node.variable_node.name.ident_node.name;
    LLVMTypeRef  llvm_type   = lookup::get_llvm_type(context.lookup, node);

    debug::set_location(generator, context, node.range.from.line, node.range.from.column);

    LLVMValueRef llvm_alloca = llvm::build_alloca(generator.llvm_builder, llvm_type, (CChar*)name.ptr);
    
    if (node.variable_node.value) {
        LLVMValueRef llvm_value = generate_node(generator, context, node.variable_node.value, node);
        llvm::build_store(generator.llvm_builder, llvm_value, llvm_alloca);
    }

    scope::add_variable(generator.scope, context.alloc, name, node, llvm_type, llvm_alloca);

    return llvm_alloca;
}

fn bool generate_compound(Generator* generator, CompileContext* context, NodeList statements, void* data)
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

        generate_node(generator, context, statement, data);
    }

    return returned;
}

fn LLVMValueRef generate_access(Generator* generator, CompileContext* context, Node* node) {
    Node*  path = node.access_node.name;
    String name = path.path_node.path;

    if (scope::has_variable(generator.scope, name)) {
        @todo("generate_access for variable");
    } else {
        return traverse_access_module(generator, context, node);
    }

    highlighter::panic();
}

fn LLVMValueRef generate_unary(Generator* generator, CompileContext* context, Node* node) {
    LLVMValueRef llvm_value = generate_node(generator, context, node.unary_node.node);

    switch (node.unary_node.operator.type) {
    case TokenType.MINUS:
        if (lookup::get_base_type_group(context.lookup, context.alloc, node, generator.scope) == "integer") {
            LLVMTypeRef int_type = context.lookup.get("int").llvm_type!!;
            
            return llvm::build_mul(generator.llvm_builder, llvm_value, create_int(int_type, -1), "");
        }

        highlighter::panic();
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

    @todo("remove need to pass data; get function type locally");
    generate_compound(generator, context, node.if_node.then_statements, null);

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

        @todo("remove need to pass data; get function type locally");
        generate_compound(generator, context, node.if_node.else_statements, null);

        LLVMBasicBlockRef else_end_block = llvm::get_insert_block(generator.llvm_builder);
        if (!llvm::get_basic_block_terminator(else_end_block)) {
            llvm::build_br(generator.llvm_builder, end_block);
        }

        generator.scope = generator.scope.parent;
    }

    llvm::position_builder_at_end(generator.llvm_builder, end_block);
}

fn LLVMValueRef traverse_access_module(Generator* generator, CompileContext* context, Node* node) => @pool() {
    String name = node.access_node.name.path_node.path;
    
    DString full_name;
    full_name.tinit();

    Node*    next = node;
    Node*    last = null;
    while (next) {
        switch (next.type) {
        case NodeType.ACCESS:
            full_name.append(next.access_node.name.ident_node.name);
            full_name.append(".");

            last = next;
            next = next.access_node.next;
        case NodeType.CALL:
            full_name.append(next.call_node.name.ident_node.name);

            last = next;
            next = null;
        default:
            highlighter::panic();
        }
    }

    switch (last.type) {
    case NodeType.CALL:
        FunctionInfo* function_info = context.functions.get(full_name.str_view())!!;
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

            arguments.push(generate_node(generator, context, argument, parameter_type));
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

fn void free(Generator* generator, Allocator alloc) {
    scope::free(generator.scope);

    llvm::dispose_module(generator.llvm_module);
    llvm::dispose_builder(generator.llvm_builder);
}
