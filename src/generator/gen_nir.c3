module nina::generator::gen_nir;

import nir;

import std::io;
import std::collections::list;

import nina::scope;
import nina::types;
import nina::lookup;
import nina::highlighter;

fn Generator* create(CompileContext* context) {
    Generator* generator = alloc::new(context.alloc, Generator);

    generator.module_name = context.trees.get(context.current_file).mod_node.path.path_node.path!!;
    generator.scope       = scope::create(context.alloc);
    generator.nir_builder = nir::create_builder();

    return generator;
}

fn void generate(Generator* generator, CompileContext* context) {
    Node* ast = context.trees.get(context.current_file)!!;

    generate_node(generator, context, ast);
    emit(generator, context);
}

fn void* generate_node(Generator* generator, CompileContext* context, Node* node, void* data = null) {
    switch (node.type) {
    case NodeType.MOD:             generate_mod(generator, context, node);
    case NodeType.FUNCTION:        generate_function(generator, context, node);
    case NodeType.RET:             generate_ret(generator, context, node);
    case NodeType.INT:      return generate_int(generator, context, node);
    default:
        highlighter::panic("Missing nir_generator function for type '%s'", node.type);
    }

    return null;
}

fn void generate_mod(Generator* generator, CompileContext* context, Node* node) {
    foreach (Node* statement : node.mod_node.statements) {
        generate_node(generator, context, statement);
    }
}

fn void generate_function(Generator* generator, CompileContext* context, Node* node) {
    String name           = node.function_node.name.ident_node.name;
    String qualified_name = string::format(context.alloc, "%s.%s", generator.module_name, name);

    LookupElement type = lookup::get(context, node.function_node.type, null);
    if (!type.llvm_type) {
        highlighter::error(context, context.current_file, node.function_node.type.range.from, node.function_node.type.range.to, "Could not find type '%s'", node.function_node.type.type_node.name.path_node.path);
    }

    NirType return_type = type.nir_type;

    List{NirParameter} parameters;
    parameters.tinit();

    foreach (Node* parameter : node.function_node.parameters) {
        TypeInfo* parameter_type_info = lookup::get_type_info(context, parameter.parameter_node.type.type_node.name.path_node.path);
        if (!parameter_type_info) {
            highlighter::error(context, context.current_file, parameter.parameter_node.type.range.from, parameter.parameter_node.type.range.to, "Could not find type '%s'", parameter.parameter_node.type.type_node.name.path_node.path);
        }

        if (!parameter.parameter_node.vaarg && !parameter.parameter_node.type) {
            highlighter::error(context, context.current_file, parameter.range.from, parameter.range.to, "Unnamed parameters are not allowed");
        }

        NirType nir_parameter_type = lookup::get(context, parameter, null).nir_type;
        String  nir_parameter_name = parameter.parameter_node.name.ident_node.name;
        parameters.push({ nir_parameter_type, nir_parameter_name });
    }

    String function_name = qualified_name;

    if (name == "main") {
        function_name = name;
    }

    NirStatement* function = nir::build_function(generator.nir_builder, return_type, parameters.to_array(context.alloc), function_name);

    if (function_name == "main") {
        nir::add_attributes(function, { NirAttributes.GLOBAL });
    }

    generator.function = node;
    generator.scope    = scope::create(context.alloc, generator.scope);

    foreach (int index, Node* parameter : node.function_node.parameters) {
        String        parameter_name = parameter.parameter_node.name.ident_node.name;
        NirStatement* nir_parameter  = nir::get_param(function, index);

        scope::add_variable(generator.scope, context.alloc, parameter_name, parameter, null, null, nir_parameter);
    }

    generate_compound(generator, context, node.function_node.statements);

    generator.scope    = generator.scope.parent;
    generator.function = null;
}

fn bool generate_compound(Generator* generator, CompileContext* context, NodeList statements)
{
    bool returned;
    foreach (int index, Node* statement : statements) {
        if (returned) {
            continue;
        }

        if ((statement.type == NodeType.RET ||
             statement.type == NodeType.ERR ||
             statement.type == NodeType.TRAP)) {
            returned = true;
        }

        generate_node(generator, context, statement);
    }

    return returned;
}

fn void generate_ret(Generator* generator, CompileContext* context, Node* node) {
    Node* value = node.ret_node.value;

    if (value) {
        NirValue* nir_value = generate_node(generator, context, value);
        nir::build_return(generator.nir_builder, nir_value);
    }
}

fn NirValue* generate_int(Generator* generator, CompileContext* context, Node* node) {
    NirType int_type = context.lookup.get("int").nir_type!!;

    return nir::build_int(generator.nir_builder, int_type, node.int_node.number.to_int())!!;
}

fn void emit(Generator* generator, CompileContext* context) {
    if (context.args.emit_ir) {
        nir::emit_nir(generator.nir_builder.mod, string::format(context.alloc, "out/ir/%s.nir", generator.module_name));
    }

    nir::emit_obj(generator.nir_builder.mod, string::format(context.alloc, "out/obj/%s.o", generator.module_name));
}
