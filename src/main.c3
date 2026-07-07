module nina;

import llvm;

import std::io;
import std::os;
import std::time;
import std::thread;

fn void main(String[] argv)
{
    @todo("mark type narrowing as error without explicit cast");
    @todo("make slices provide the pointer for function calls that require a char*");

    CompileContext* context = core::context_create();

    profiler::commit(context.profiler, "Preparation");

    path::mkdir("out")!!;
    path::mkdir("out/obj")!!;
    path::mkdir("out/ir")!!;

    profiler::commit(context.profiler, "Args");
    args::parse(context.args, argv);

    foreach (String file : context.args.files) {
        String? path = file.to_tpath().absolute(context.alloc).copy(context.alloc);
        if (catch err = path) {
            io::eprintfn("Unable to read file '%s': %s", file, err);
            os::exit(1);
        }

        // -- LEXER --
        profiler::commit(context.profiler, "Lexer");
        
        Lexer* lexer = lexer::create(context, path);
        lexer::tokenize(lexer, context);

        // -- PARSER --
        profiler::commit(context.profiler, "Parser");

        Parser* parser = parser::create(context.alloc, lexer);
        parser::parse(parser, context, lexer);

        registry::register(context, parser);

        lexer::free(lexer, context.alloc);
    }

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;

        // -- ANALYSER --
        profiler::commit(context.profiler, "Analyser");

        Analyser* analyser = analyser::create(context, path);
        analyser::analyse(analyser, context);

        // -- GENERATOR --
        profiler::commit(context.profiler, "Generator");
        Generator* generator = generator::create(context);
        generator::generate(generator, context);

        profiler::commit(context.profiler, "Cleanup");

        // TODO: free nodes
        // parser::free(parser, context.alloc);
        analyser::free(analyser, context.alloc);
        generator::free(generator, context.alloc);

    }

    profiler::commit(context.profiler, "Linker");

    if (!context.args.no_linker) {
        Linker* linker = linker::create(context);
        linker::link(linker, context);
        linker::free(linker);
    }

    profiler::commit(context.profiler, "Cleanup");

    // TODO: move? cleanup still happens in context_free
    profiler::end(context.profiler);

    core::context_free(context);
}
