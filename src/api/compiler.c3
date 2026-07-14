module nina::api::compiler;

import nina::core;
import nina::lexer;
import nina::types;
import nina::parser;
import nina::analyser;
import nina::registry;
import nina::generator;

import std::io;
import std::os;

fn void compile_single_file(CompileContext* context, CChar* file) @export("nina_compile_single_file") {
    path::mkdir("out")!!;
    path::mkdir("out/obj")!!;
    path::mkdir("out/ir")!!;

    String? path = ((ZString)file).str_view().to_tpath().absolute(context.alloc).copy(context.alloc);
    if (catch err = path) {
        io::eprintfn("Unable to read file '%s': %s", file, err);
        os::exit(1);
    }

    Lexer* lexer = lexer::create(context, path);
    lexer::tokenize(lexer, context);

    Parser* parser = parser::create(context.alloc, lexer);
    parser::parse(parser, context, lexer);

    registry::register_types(context, context.trees.get(context.current_file))!!;
    registry::register_functions(context, context.trees.get(context.current_file))!!;

    Analyser* analyser = analyser::create(context, path);
    analyser::analyse(analyser, context);

    Generator* generator = generator::create(context);
    generator::generate(generator, context);

    lexer::free(lexer, context.alloc);
    parser::free(parser, context.alloc);
    analyser::free(analyser, context.alloc);
    generator::free(generator, context);
}
