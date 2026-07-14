module nina;

import llvm;

import std::io;
import std::os;
import std::time;
import std::thread;

fn void main(String[] argv)
{
    @todo("mark type narrowing as error without explicit cast");
    @todo("add reflection");
    @todo("add type widening");

    CompileContext* context = core::context_create();

    profiler::commit(context.profiler, "Preparation");

    path::mkdir("out")!!;
    path::mkdir("out/obj")!!;
    path::mkdir("out/ir")!!;

    profiler::commit(context.profiler, "Args");
    args::parse(context.args, argv);

    switch (context.args.cmd) {
    case CompileCommand.COMPILE:
        compile(context);
    default:
        highlighter::panic();
    }

    profiler::end(context.profiler);

    core::context_free(context);
}

fn void compile(CompileContext* context) {
    add_stdlib(context);

    foreach (String file : context.args.files) {
        String? path = file.to_tpath().absolute(context.alloc).copy(context.alloc);
        if (catch err = path) {
            io::eprintfn("Unable to read file '%s': %s", file, err);
            os::exit(1);
        }

        profiler::commit(context.profiler, "Lexer");
        Lexer* lexer = lexer::create(context, path);
        lexer::tokenize(lexer, context);

        profiler::commit(context.profiler, "Parser");
        Parser* parser = parser::create(context.alloc, lexer);
        parser::parse(parser, context, lexer);

        lexer::free(lexer, context.alloc);
    }

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;
        context.current_file = path;

        registry::register_types(context, context.trees.get(context.current_file))!!;
    }

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;
        context.current_file = path;

        registry::register_functions(context, context.trees.get(context.current_file))!!;
    }

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;

        profiler::commit(context.profiler, "Analyser");
        Analyser* analyser = analyser::create(context, path);
        analyser::analyse(analyser, context);

        profiler::commit(context.profiler, "Generator");
        Generator* generator = generator::create(context);
        generator::generate(generator, context);

        profiler::commit(context.profiler, "Cleanup");

        // TODO: free nodes
        // parser::free(parser, context.alloc);
        analyser::free(analyser, context.alloc);
        generator::free(generator, context);
    }

    profiler::commit(context.profiler, "Linker");

    if (!context.args.no_linker) {
        Linker* linker = linker::create(context);
        linker::link(linker, context);
        linker::free(linker);
    }

    profiler::commit(context.profiler, "Cleanup");
}

fn void add_stdlib(CompileContext* context) {
    String exe    = util::@get_exec();
    Path   stdlib = string::tformat("%s/stdlib", ((Path)exe).parent()).to_path(context.alloc)!!;

    path::traverse(stdlib, fn bool?(path, is_dir, data) {
        CompileContext* context = (CompileContext*)data;

        if (!is_dir && path.has_extension("n")) {
            context.args.files.push(path.copy(context.alloc));
        }

        return false;
    }, context)!!;
}
