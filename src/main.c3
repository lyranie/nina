module nina;

import llvm;

import std::io;
import std::time;
import std::thread;

fn void main(String[] argv)
{
    CompileContext* context = core::context_create();

    profiler::commit(context.profiler, "Preparation");

    path::mkdir("out")!!;
    path::mkdir("out/obj")!!;
    path::mkdir("out/ir")!!;

    profiler::commit(context.profiler, "Args");
    args::parse(context.args, argv);

    foreach (String file : context.args.files) {
        context.current_file = file;

        // -- LEXER --
        profiler::commit(context.profiler, "Lexer");
        
        Lexer* lexer = lexer::create(context.alloc, file);
        lexer::tokenize(lexer, context);

        // -- PARSER --
        profiler::commit(context.profiler, "Parser");

        Parser* parser = parser::create(context.alloc, lexer);
        parser::parse(parser, context, lexer);

        // -- ANALYSER --
        profiler::commit(context.profiler, "Analyser");

        Analyser* analyser = analyser::create(context.alloc, parser);
        analyser::analyse(analyser, context, parser);

        // -- GENERATOR --
        profiler::commit(context.profiler, "Generator");
        Generator* generator = generator::create(context, parser);
        generator::generate(generator, context, parser);

        profiler::commit(context.profiler, "Cleanup");

        lexer::free(lexer, context.alloc);
        parser::free(parser, context.alloc);
        analyser::free(analyser, context.alloc);
        generator::free(generator, context.alloc);

    }

    profiler::commit(context.profiler, "Linker");

    Linker* linker = linker::create(context);

    linker::link(linker, context);

    profiler::commit(context.profiler, "Cleanup");

    linker::free(linker);
    core::context_free(context);
}
