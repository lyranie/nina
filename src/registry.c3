module nina::registry;

import llvm;

import nina::types;
import nina::lookup;

import std::io;
import std::collections::list;

fn void register(CompileContext* context, Parser* parser) {
    String        mod         = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
    LLVMModuleRef llvm_module = llvm::module_create_with_name((CChar*)mod.ptr);

    context.modules.set(context.current_file, llvm_module);

    register_types(context, context.trees.get(context.current_file))!!;
    register_functions(context, context.trees.get(context.current_file))!!;
}

fn void register_types(CompileContext* context, Node* node) {
    switch (node.type) {
    case NodeType.STRUCT:
        String mod_name  = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
        String type_name = node.struct_node.name.ident_node.name;
        String name      = string::format(context.alloc, "%s.%s", mod_name, type_name);
        
        LLVMTypeRef llvm_struct_type = llvm::struct_create_named(context.llvm_context, (CChar*)name.ptr);

        TypeInfo* type_info = alloc::new(context.alloc, TypeInfo);
        type_info.mod        = mod_name;
        type_info.file       = context.current_file;
        type_info.node       = node;
        type_info.llvm_type  = llvm_struct_type;

        context.types.set(name, type_info);

        lookup::register_type(context.lookup, context.alloc, type_name, context.current_file, node, llvm_struct_type);
    case NodeType.MOD:
        foreach (Node* statement : node.mod_node.statements) {
            register_types(context, statement);
        }
    default:
        break;
    }
}

fn void register_functions(CompileContext* context, Node* node) {
    switch (node.type) {
    case NodeType.FUNCTION:
        String mod_name = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
        String fn_name  = node.function_node.name.ident_node.name;
        String name     = string::format(context.alloc, "%s.%s", mod_name, fn_name);

        LLVMTypeRef return_type = lookup::get_llvm_type(context.lookup, node.function_node.type);
    
        List{LLVMTypeRef} parameters;
        parameters.tinit();

        foreach (Node* parameter : node.function_node.parameters) {
            LLVMTypeRef llvm_parameter_type = lookup::get_llvm_type(context.lookup, parameter);
            parameters.push(llvm_parameter_type);
        }

        String function_name = name;
        String pure_name     = node.function_node.name.ident_node.name;

        if (pure_name == "main") {
            function_name = pure_name;
        }

        LLVMTypeRef  llvm_function_type  = llvm::function_type(return_type, parameters.to_array(context.alloc), (CUInt)parameters.len(), llvm::FALSE);
        LLVMValueRef llvm_function_value = llvm::add_function(context.modules.get(context.current_file)!!, (CChar*)function_name.ptr, llvm_function_type);

        FunctionInfo* function_info = alloc::new(context.alloc, FunctionInfo);
        function_info.mod        = mod_name;
        function_info.file       = context.current_file;
        function_info.node       = node;
        function_info.llvm_type  = llvm_function_type;
        function_info.llvm_value = llvm_function_value;

        context.functions.set(name, function_info);
    case NodeType.EXT:
        String mod_name = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
        String ext_name = node.ext_node.name.ident_node.name;
        String name     = string::format(context.alloc, "%s.%s", mod_name, ext_name);
    
        LLVMTypeRef return_type = lookup::get_llvm_type(context.lookup, node.function_node.type);

        List{LLVMTypeRef} parameters;
        parameters.tinit();

        bool vaarg = false;

        foreach (Node* parameter : node.ext_node.parameters) {
            if (parameter.parameter_node.vaarg) {
                vaarg = true;
                continue;
            }

            LLVMTypeRef llvm_parameter_type = lookup::get_llvm_type(context.lookup, parameter);
            parameters.push(llvm_parameter_type);
        }
        
        String pure_name = node.ext_node.name.ident_node.name;

        LLVMTypeRef  llvm_function_type  = llvm::function_type(return_type, parameters.to_array(context.alloc), (CUInt)parameters.len(), vaarg ? llvm::TRUE : llvm::FALSE);
        LLVMValueRef llvm_function_value = llvm::add_function(context.modules.get(context.current_file)!!, (CChar*)pure_name.ptr, llvm_function_type);

        FunctionInfo* function_info = alloc::new(context.alloc, FunctionInfo);
        function_info.mod        = mod_name;
        function_info.file       = context.current_file;
        function_info.node       = node;
        function_info.llvm_type  = llvm_function_type;
        function_info.llvm_value = llvm_function_value;

        context.functions.set(name, function_info);
    case NodeType.MOD:
        foreach (Node* statement : node.mod_node.statements) {
            register_functions(context, statement);
        }
    default:
        break;
    }
}
