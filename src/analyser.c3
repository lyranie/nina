module nina::analyser;

import nina::scope;
import nina::types;
import nina::lookup;
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
    case NodeType.BOOL:
        break;
    case NodeType.STRING:
        break;
    case NodeType.BIN:
        analyse_bin(analyser, context, node);
    case NodeType.IDENT:
        analyse_ident(analyser, context, node);
    case NodeType.VARIABLE:
        analyse_variable(analyser, context, node);
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

    if (!always_returns(analyser, context, node) && lookup::get_type_name(context.lookup, context.alloc, node, analyser.scope) != "void")
    {
        highlighter::error(context, node.range.from, node.range.to, "Missing return at end of function");
    }

    Node* type = node.function_node.type;
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

    analyse_compound(analyser, context, node.function_node.statements, type);

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

    @todo("compare return type to function type");

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
        if (parameter.parameter_node.type) {
            analyse_node(analyser, context, parameter.parameter_node.type);
        }

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

    FunctionInfo* function_info = scope::get_function(analyser.scope, name);

    bool vaarg = false;
    int  min_parameters_len = (int)function_info.node.function_node.parameters.len();
    foreach (index, parameter : function_info.node.function_node.parameters)
    {
        if (parameter.parameter_node.vaarg)
        {
            vaarg              = true;
            min_parameters_len = (int)index;
            break;
        }
    }

    int arguments_len  = (int)node.call_node.arguments.len();
    int parameters_len = (int)function_info.node.function_node.parameters.len();
    
    if (arguments_len < min_parameters_len) {
        highlighter::note(context, function_info.node.range.from, function_info.node.range.to, "Definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Expected more arguments");
    }

    if (arguments_len > parameters_len)
    {
        if (!vaarg)
        {
            Node* argument = node.call_node.arguments[(long)arguments_len - 1];

            highlighter::error(context, argument.range.from, argument.range.to, "Expected less arguments");
        }
    }

    foreach (int i, Node* argument : node.call_node.arguments)
    {
        if (i >= parameters_len) {
            break;
        }

        Node* parameter = function_info.node.function_node.parameters[i];

        analyse_node(analyser, context, argument);

        if (parameter.parameter_node.vaarg) {
            continue;
        }

        if (!lookup::compare_type(context.lookup, context.alloc, parameter, argument, analyser.scope))
        {
            String parameter_type = lookup::get_type_name(context.lookup, context.alloc, parameter, analyser.scope);
            String argument_type  = lookup::get_type_name(context.lookup, context.alloc, argument, analyser.scope);

            highlighter::error(context, argument.range.from, argument.range.to, "Expected type '%s', got '%s'", parameter_type, argument_type);
        }
    }
}

fn void analyse_bin(Analyser* analyser, CompileContext* context, Node* node) {
    @todo("check if operator is applicable to type");

    if (!lookup::compare_type(context.lookup, context.alloc, node.bin_node.left, node.bin_node.right, analyser.scope)) {
        String left_type  = lookup::get_type_name(context.lookup, context.alloc, node.bin_node.left, analyser.scope);
        String right_type = lookup::get_type_name(context.lookup, context.alloc, node.bin_node.right, analyser.scope);

        highlighter::error(context, node.range.from, node.range.to, "Cannot operate type '%s' with type '%s'", left_type, right_type);
    }
}

fn void analyse_ident(Analyser* analyser, CompileContext* context, Node* node) {
    String name = node.ident_node.name;

    if (!scope::has_variable(analyser.scope, name)) {
        highlighter::error(context, node.range.from, node.range.to, "Could not find variable '%s'", name);
    }
}

fn void analyse_variable(Analyser* analyser, CompileContext* context, Node* node) {
    analyse_node(analyser, context, node.variable_node.type);

    String name = node.variable_node.name.ident_node.name;

    if (scope::has_variable(analyser.scope, name)) {
        VariableInfo* prev = scope::get_variable(analyser.scope, name);
        
        highlighter::note(context, prev.node.range.from, prev.node.range.to, "Previous definition was here");
        highlighter::error(context, node.range.from, node.range.to, "Variable '%s' already defined", name);
    }

    scope::add_variable(analyser.scope, context.alloc, name, node);

    if (node.variable_node.type) {
        analyse_node(analyser, context, node.variable_node.type);

        @todo("check if value type matches variable type");
    }
}

<*
  @param type : `The Function return type`
*>
fn void analyse_compound(Analyser* analyser, CompileContext* context, NodeList statements, Node* type) {
    bool returned;

    foreach (int index, Node* statement : statements)
    {
        analyse_node(analyser, context, statement, type);

        if (returned)
        {
            highlighter::warn(context, statement.range.from, statement.range.to, "Statement will never be executed");
        }

        if (statement.type == NodeType.RET && index != statements.len() - 1)
        {
            returned = true;
            highlighter::note(context, statement.range.from, statement.range.to, "No statement will be executed after return");
        }
    }
}

fn bool always_returns(Analyser* analyser, CompileContext* context, Node* node) {
    switch (node.type) {
    case NodeType.RET:
        return true;
    case NodeType.FUNCTION:
        return compound_returns(analyser, context, node.function_node.statements);
    default:
        return false;
    }
}

fn bool compound_returns(Analyser* analyser, CompileContext* context, NodeList statements)
{
    foreach (Node* statement : statements)
    {
        if (always_returns(analyser, context, statement)) {
            return true;
        }
    }

    return false;
}

fn void free(Analyser* analyser, Allocator alloc) {
    scope::free(analyser.scope);
}
