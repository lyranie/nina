module nina::api::registry;

import nina::types;
import nina::registry;

/*
fn void registry_register_types(CompileContext* context, Parser* parser) @export("nina_registry_register_types") {
    registry::register_types(context, parser);
}

fn void registry_register_functions(CompileContext* context, Parser* parser) @export("nina_registry_register_functions") {
    registry::register_functions(context, parser);
}

/*
fn void register_types(CompileContext* context, Node* node) {
    String        mod         = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
    LLVMModuleRef llvm_module = llvm::module_create_with_name((CChar*)mod.ptr);

    context.modules.set(context.current_file, llvm_module);

    _register_types(context, node);
}

fn void register_functions(CompileContext* context, Node* node) {
    _register_functions(context, node);
}
