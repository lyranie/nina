module nina::debug;

import llvm;

import nina::types;
import nina::lookup;

import std::collections::list;
import std::io;

fn void add_function(Generator* generator, CompileContext* context, Node* node, LLVMValueRef llvm_function_value) {
    if (context.args.no_debug) {
        return;
    }

    String name = node.function_node.name.ident_node.name;
    CUInt  line = (CUInt)node.range.from.line;

    List{LLVMMetadataRef} debug_types;
    debug_types.tinit();

    debug_types.push(lookup::get_llvm_debug_type(context, generator, context.lookup, node.function_node.type));

    foreach (Node* parameter : node.function_node.parameters) {
        if (parameter.parameter_node.vaarg) {
            continue;
        }

        debug_types.push(lookup::get_llvm_debug_type(context, generator, context.lookup, parameter));
    }

    LLVMMetadataRef llvm_subroutine_type = llvm::di_builder_create_subroutine_type(
        generator.llvm_debug_builder,
        generator.llvm_debug_file,
        debug_types.to_array(context.alloc),
        (CUInt)debug_types.len(),
        LLVMDIFlags.DI_FLAG_ZERO
    );

    LLVMMetadataRef llvm_subprogram = llvm::di_builder_create_function(
        generator.llvm_debug_builder,
        generator.llvm_debug_file,
        (CChar*)name.ptr,
        (CUInt)name.len,
        (CChar*)name.ptr,
        (CUInt)name.len,
        generator.llvm_debug_file,
        line,
        llvm_subroutine_type,
        llvm::FALSE,
        llvm::TRUE,
        line,
        LLVMDIFlags.DI_FLAG_ZERO,
        llvm::FALSE
    );

    llvm::set_subprogram(llvm_function_value, llvm_subprogram);

    debug_types.free();
}

fn LLVMValueRef add_parameter(Generator* generator, CompileContext* context, Node* parameter, LLVMValueRef llvm_function_value, LLVMValueRef llvm_parameter_value, CUInt index) {
    if (context.args.no_debug) {
        return null;
    }

    String          parameter_name  = parameter.parameter_node.name.ident_node.name;
    LLVMMetadataRef llvm_subprogram = llvm::get_subprogram(llvm_function_value);
    LLVMMetadataRef llvm_debug_type = lookup::get_llvm_debug_type(context, generator, context.lookup, parameter);
    LLVMTypeRef     llvm_type       = lookup::get_llvm_type(context, parameter, generator.scope);
    CUInt           line            = (CUInt)parameter.range.from.line;

    LLVMValueRef llvm_alloca = llvm::build_alloca(generator.llvm_builder, llvm_type, (CChar*)parameter_name.ptr);
    llvm::build_store(generator.llvm_builder, llvm_parameter_value, llvm_alloca);

    LLVMMetadataRef llvm_parameter_variable = llvm::di_builder_create_parameter_variable(
        generator.llvm_debug_builder,
        llvm_subprogram,
        (CChar*)parameter_name.ptr,
        (CUInt)parameter_name.len,
        index + 1,
        generator.llvm_debug_file,
        line,
        llvm_debug_type,
        llvm::TRUE,
        LLVMDIFlags.DI_FLAG_ZERO
    );

    LLVMMetadataRef llvm_debug_location = llvm::di_builder_create_debug_location(
        llvm::get_global_context(),
        line,
        0,
        llvm_subprogram,
        null
    );

    llvm::di_builder_insert_declare_record_at_end(
        generator.llvm_debug_builder,
        llvm_alloca,
        llvm_parameter_variable,
        llvm::di_builder_create_expression(generator.llvm_debug_builder, null, 0),
        llvm_debug_location,
        llvm::get_insert_block(generator.llvm_builder)
    );

    return llvm_alloca;
}

fn void set_location(Generator* generator, CompileContext* context, int line, int column) {
    if (context.args.no_debug) {
        return;
    }

    LLVMValueRef    llvm_function_value = llvm::get_basic_block_parent(llvm::get_insert_block(generator.llvm_builder));
    LLVMMetadataRef llvm_subprogram     = llvm::get_subprogram(llvm_function_value);
    LLVMMetadataRef llvm_debug_location = llvm::di_builder_create_debug_location(
        llvm::get_global_context(),
        (CUInt)line,
        (CUInt)column,
        llvm_subprogram,
        null
    );

    llvm::set_current_debug_location_2(generator.llvm_builder, llvm_debug_location);
}
