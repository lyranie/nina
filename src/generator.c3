module nina::generator;

import llvm;

import nina::debug;
import nina::scope;
import nina::types;
import nina::lookup;

import std::collections::list;
import std::io;
import std::os;

fn Generator* create(CompileContext* context, Parser* parser) {
    Generator* generator = alloc::new(context.alloc, Generator);

    String mod = parser.context.ast.mod_node.path.path_node.path;

    generator.module_name        = mod;
    generator.scope              = scope::create(context.alloc);
    generator.llvm_module        = llvm::module_create_with_name((CChar*)mod.ptr);

    String flag_name = "Debug Info Version";
    llvm::add_module_flag(
        generator.llvm_module,
        LLVMModuleFlagBehavior.MODULE_FLAG_BEHAVIOR_WARNING,
        (CChar*)flag_name.ptr,
        flag_name.len,
        llvm::value_as_metadata(llvm::const_int(llvm::int_32_type(), llvm::debug_metadata_version(), llvm::FALSE))
    );

    generator.llvm_builder       = llvm::create_builder();
    generator.llvm_debug_builder = llvm::create_di_builder(generator.llvm_module);
    generator.llvm_debug_file    = llvm::di_builder_create_file(
        generator.llvm_debug_builder,
        (CChar*)context.current_file.ptr,
        (CUInt)context.current_file.len,
        "", 0 // TODO: splt absolute path
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

    return generator;
}

fn void generate(Generator* generator, CompileContext* context, Parser* parser) {
    generate_node(generator, context, parser.context.ast);
    emit(generator, context);
}

fn void* generate_node(Generator* generator, CompileContext* context, Node* node, void* data = null) {
    switch (node.type) {
    case NodeType.MOD:
        generate_mod(generator, context, node);
    case NodeType.FUNCTION:
        generate_function(generator, context, node);
    case NodeType.RET:
        generate_ret(generator, context, node);
    case NodeType.INT:
        return generate_int(generator, context, node);
    default:
        io::eprintfn("Missing generator function for type '%s'", node.type);
        os::exit(1);
    }

    return null;
}

fn void generate_mod(Generator* generator, CompileContext* context, Node* node) {
    foreach (Node* statement : node.mod_node.statements) {
        generate_node(generator, context, statement);
    }
}

fn void generate_function(Generator* generator, CompileContext* context, Node* node) {
    String      name        = node.function_node.name.ident_node.name;
    LLVMTypeRef return_type = lookup::get_llvm_type(context.lookup, node.function_node.type);

    List{LLVMTypeRef} parameters;
    parameters.tinit();

    foreach (Node* parameter : node.function_node.parameters) {
        LLVMTypeRef llvm_parameter_type = lookup::get_llvm_type(context.lookup, parameter);
        parameters.push(llvm_parameter_type);
    }

    LLVMTypeRef  llvm_function_type  = llvm::function_type(return_type, parameters.to_array(context.alloc), (CUInt)parameters.len(), llvm::FALSE);
    LLVMValueRef llvm_function_value = llvm::add_function(generator.llvm_module, (CChar*)name.ptr, llvm_function_type);

    FunctionInfo* function_info = scope::add_function(
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

        scope::add_variable(generator.scope, context.alloc, parameter_name, parameter, llvm_parameter_type, llvm_parameter_value);
        debug::add_parameter(generator, context, parameter, llvm_function_value, llvm_parameter_value, index);
    }

    foreach (Node* statement : node.function_node.statements) {
        generate_node(generator, context, statement);
    }

    generator.scope = generator.scope.parent;
}

fn void generate_ret(Generator* generator, CompileContext* context, Node* node) {
    Node* value = node.ret_node.value;

    if (value) {
        llvm::build_ret(generator.llvm_builder, generate_node(generator, context, value));
    } else {
        llvm::build_ret_void(generator.llvm_builder);
    }
}

fn LLVMValueRef generate_int(Generator* generator, CompileContext* context, Node* node) {
    LLVMTypeRef int_type = context.lookup.get("int").llvm_type!!;

    return llvm::const_int(int_type, (CULongLong)node.int_node.number.to_int(), llvm::TRUE)!!;
}

fn void emit(Generator* generator, CompileContext* context) {
    llvm::di_builder_finalize(generator.llvm_debug_builder);

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

    if (llvm::target_machine_emit_to_file(target_machine, generator.llvm_module, (CChar*)string::format(context.alloc, "out/obj/%s.o", generator.module_name), LLVMCodeGenFileType.OBJECT_FILE, &error))
    {
        io::eprintfn("Failed to emit object file: %s", (ZString)error);
        llvm::dispose_message(error);
        os::exit(1);
    }

    if (context.args.emit_ir) {
        if (llvm::print_module_to_file(generator.llvm_module, (CChar*)string::format(context.alloc, "out/ir/%s.ll", generator.module_name), &error) != 0) {
            io::eprintn((ZString)error);
            llvm::dispose_message(error);
        }
    }
}

fn void free(Generator* generator, Allocator alloc) {
    scope::free(generator.scope);

    llvm::dispose_module(generator.llvm_module);
    llvm::dispose_builder(generator.llvm_builder);
}
