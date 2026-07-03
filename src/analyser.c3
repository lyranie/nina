module nina::analyser;

import nina::scope;
import nina::types;
import nina::highlighter;

import std::collections::map;
import std::io;
import std::os;

fn Analyser* create(Allocator alloc, Parser* parser) {
    Analyser* analyser = alloc::new(alloc, Analyser);
    String    mod      = parser.context.ast.mod_node.path.path_node.path;
    
    analyser.scope       = scope::create(alloc);
    analyser.module_name = mod;

    return analyser;
}

fn void analyse(Analyser* analyser, CompileContext* context, Parser* parser) {
    analyse_node(analyser, context, parser.context.ast);
}

fn void analyse_node(Analyser* analyser, CompileContext* context, Node* node, void* data = null) {
    switch (node.type) {
    case NodeType.MOD:
        analyse_mod(analyser, context, node);
    case NodeType.FUNCTION:
        analyse_function(analyser, context, node);
    case NodeType.TYPE:
        analyse_type(analyser, context, node);
    case NodeType.RET:
        analyse_ret(analyser, context, node, data);
    case NodeType.INT:
        break;
    case NodeType.EXT:
        analyse_ext(analyser, context, node);
    case NodeType.CALL:
        analyse_call(analyser, context, node);
    default:
        highlighter::panic("Missing analyser function for type '%s'", node.type);
    }
}

fn void analyse_mod(Analyser* analyser, CompileContext* context, Node* node) {
    String path = node.mod_node.path.path_node.path;

    if (context.mods.has_key(path)) {
        highlighter::error(
            context,
            node.mod_node.path.range.from,
            node.mod_node.path.range.to,
            "Module '%s' already declared in file '%s'", path, context.mods.get(path)
        )!!;
    }

    context.mods.set(path, context.current_file);

    foreach (Node* statement : node.mod_node.statements) {
        analyse_node(analyser, context, statement);
    }
}

fn void analyse_function(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.function_node.type);

    String name = node.function_node.name.ident_node.name;
    if (scope::has_function(analyser.scope, name)) {
        FunctionInfo* prev = scope::get_function(analyser.scope, name);

        highlighter::note(context, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Function '%s' already defined", name);
    }

    scope::add_function(analyser.scope, context.alloc, name, analyser.module_name, context.current_file, node);

    // TODO: check if there is a return statement present for each possible outcome
    Node*  type  = node.function_node.type;
    analyser.scope = scope::create(context.alloc, analyser.scope);

    HashMap{String, Node*} parameters;
    parameters.tinit();

    foreach (Node* parameter : node.function_node.parameters) {
        analyse_node(analyser, context, parameter.parameter_node.type);

        String parameter_name = parameter.parameter_node.name.ident_node.name;

        if (parameters.has_key(parameter_name)) {
            Node* prev = parameters.get(parameter_name)!!;

            highlighter::note(context, prev.range.from, prev.range.to, "Previous definition was here");
            highlighter::error(context, parameter.range.from, parameter.range.to, "Parameter '%s' already defined", parameter_name);
        }

        parameters.set(parameter_name, parameter);
        scope::add_variable(analyser.scope, context.alloc, parameter_name, parameter);
    }

    foreach (Node* statement : node.function_node.statements) {
        analyse_node(analyser, context, statement, type);
    }

    analyser.scope = analyser.scope.parent;

    parameters.free();
}

fn void analyse_type(Analyser* analyser, CompileContext* context, Node* node) {
    String name = node.type_node.name.ident_node.name;

    if (!context.lookup.has_key(name)) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find type '%s'", name);
    }
}

fn void analyse_ret(Analyser* analyser, CompileContext* context, Node* node, void* data) {
    Node* function_type = (Node*)data;

    // TODO: compare return type to function type

    if (node.ret_node.value) {
        analyse_node(analyser, context, node.ret_node.value);
    }
}

fn void analyse_ext(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.ext_node.type);

    String name = node.ext_node.name.ident_node.name;
    if (scope::has_function(analyser.scope, name)) {
        FunctionInfo* prev = scope::get_function(analyser.scope, name);
        
        highlighter::note(context, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Function '%s' already defined", name);
    }

    scope::add_function(analyser.scope, context.alloc, name, analyser.module_name, context.current_file, node);

    HashMap{String, Node*} parameters;
    parameters.tinit();

    foreach (Node* parameter : node.ext_node.parameters) {
        analyse_node(analyser, context, parameter.parameter_node.type);

        String parameter_name = parameter.parameter_node.name.ident_node.name;

        if (parameters.has_key(parameter_name)) {
            Node* prev = parameters.get(parameter_name)!!;

            highlighter::note(context, prev.range.from, prev.range.to, "Previous definition was here");
            highlighter::error(context, parameter.range.from, parameter.range.to, "Parameter '%s' already defined", parameter_name);
        }

        parameters.set(parameter_name, parameter);
        scope::add_variable(analyser.scope, context.alloc, parameter_name, parameter);
    }
}

fn void analyse_call(Analyser* analyser, CompileContext* context, Node* node) {
    String name = node.call_node.name.path_node.path;

    if (!scope::has_function(analyser.scope, name)) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find function '%s'", name);
    }

    foreach (Node* argument : node.call_node.arguments) {
        analyse_node(analyser, context, argument);
    }
}

fn void free(Analyser* analyser, Allocator alloc) {
    scope::free(analyser.scope);
}
