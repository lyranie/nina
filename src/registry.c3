module nina::registry;

import llvm;

import nina::types;
import nina::lookup;
import nina::highlighter;

import std::io;
import std::collections::list;

fn Registry* create(Allocator alloc) {
    Registry* registry = alloc::new(alloc, Registry);

    registry.functions.init(alloc);
    registry.types.init(alloc);

    return registry;
}

fn void register_types(CompileContext* context, Node* node) {
    String        mod         = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
    LLVMModuleRef llvm_module = llvm::module_create_with_name((CChar*)mod.ptr);

    context.modules.set(context.current_file, llvm_module);

    _register_types(context, node);
}

fn void register_functions(CompileContext* context, Node* node) {
    _register_functions(context, node);
}

fn void _register_types(CompileContext* context, Node* node) {
    switch (node.type) {
    case NodeType.STRUCT:
        String mod_name  = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
        String type_name = node.struct_node.name.ident_node.name;
        String name      = string::format(context.alloc, "%s.%s", mod_name, type_name);

        LLVMTypeRef llvm_struct_type = llvm::struct_create_named(context.llvm_context, (CChar*)name.ptr);

        TypeInfo* type_info = alloc::new(context.alloc, TypeInfo);
        type_info.name       = type_name;
        type_info.mod        = mod_name;
        type_info.file       = context.current_file;
        type_info.node       = node;
        type_info.llvm_type  = llvm_struct_type;

        context.registry.types.set(name, type_info);
    case NodeType.MOD:
        foreach (Node* statement : node.mod_node.statements) {
            register_types(context, statement);
        }
    default:
        break;
    }
}

fn void _register_functions(CompileContext* context, Node* node) {
    switch (node.type) {
    case NodeType.FUNCTION:
        String mod_name = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
        String fn_name  = node.function_node.name.ident_node.name;
        String name     = string::format(context.alloc, "%s.%s", mod_name, fn_name);

        TypeInfo* type_info = lookup::get_type_info(context, node.function_node.type.type_node.name.path_node.path);
        if (!type_info) {
            highlighter::error(context, context.current_file, node.function_node.type.range.from, node.function_node.type.range.to, "Could not find type '%s'", node.function_node.type.type_node.name.path_node.path);
        }

        LLVMTypeRef return_type = lookup::get(context, node.function_node.type, null).llvm_type;
    
        List{LLVMTypeRef} parameters;
        parameters.tinit();

        foreach (Node* parameter : node.function_node.parameters) {
            TypeInfo* parameter_type_info = lookup::get_type_info(context, parameter.parameter_node.type.type_node.name.path_node.path);
            if (!parameter_type_info) {
                highlighter::error(context, context.current_file, parameter.parameter_node.type.range.from, parameter.parameter_node.type.range.to, "Could not find type '%s'", parameter.parameter_node.type.type_node.name.path_node.path);
            }

            if (!parameter.parameter_node.vaarg && !parameter.parameter_node.type) {
                highlighter::error(context, context.current_file, parameter.range.from, parameter.range.to, "Unnamed parameters are not allowed");
            }

            LLVMTypeRef llvm_parameter_type = lookup::get(context, parameter, null).llvm_type;
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

        context.registry.functions.set(name, function_info);
    case NodeType.EXT:
        String mod_name = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
        String ext_name = node.ext_node.name.ident_node.name;
        String name     = string::format(context.alloc, "%s.%s", mod_name, ext_name);

        TypeInfo* type_info = lookup::get_type_info(context, node.ext_node.type.type_node.name.path_node.path);
        if (!type_info) {
            highlighter::error(context, context.current_file, node.ext_node.type.range.from, node.ext_node.type.range.to, "Could not find type '%s'", node.ext_node.type.type_node.name.path_node.path);
        }
    
        LLVMTypeRef return_type = lookup::get(context, node.function_node.type, null).llvm_type;

        List{LLVMTypeRef} parameters;
        parameters.tinit();

        bool vaarg = false;

        foreach (Node* parameter : node.ext_node.parameters) {
            if (parameter.parameter_node.vaarg) {
                vaarg = true;
                continue;
            }

            TypeInfo* parameter_type_info = lookup::get_type_info(context, parameter.parameter_node.type.type_node.name.path_node.path);
            if (!parameter_type_info) {
                highlighter::error(context, context.current_file, parameter.parameter_node.type.range.from, parameter.parameter_node.type.range.to, "Could not find type '%s'", parameter.parameter_node.type.type_node.name.path_node.path);
            }
            
            if (!parameter.parameter_node.vaarg && !parameter.parameter_node.type) {
                highlighter::error(context, context.current_file, parameter.range.from, parameter.range.to, "Unnamed parameters are not allowed");
            }

            LLVMTypeRef llvm_parameter_type = lookup::get(context, parameter, null).llvm_type;
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

        context.registry.functions.set(name, function_info);
    case NodeType.MOD:
        foreach (Node* statement : node.mod_node.statements) {
            register_functions(context, statement);
        }
    default:
        break;
    }
}
