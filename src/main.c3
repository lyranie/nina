module nina;

import llvm;

import std::io;
import std::os;
import std::time;
import std::thread;
import std::collections::map;
import std::collections::set;
import std::collections::list;

fn void main(String[] argv)
{
    @todo("mark type narrowing as error without explicit cast");
    @todo("check function throw type against all throws");

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

fn void compile(CompileContext* context) => @pool() {
    if (!context.args.no_stdlib) {
        add_stdlib(context);
    }

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

    remove_unused(context);

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;
        context.current_file = path;

        registry::register(context);
        registry::register_types(context, context.trees.get(context.current_file))!!;
    }

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;
        context.current_file = path;

        registry::register_struct_bodies(context, context.trees.get(context.current_file))!!;
    }

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;
        context.current_file = path;

        registry::register_functions(context, context.trees.get(context.current_file))!!;
    }

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;
        context.current_file = path;

        registry::register_constants(context, context.trees.get(context.current_file))!!;
    }

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;

        profiler::commit(context.profiler, "Analyser");
        Analyser* analyser = analyser::create(context, path);
        analyser::analyse(analyser, context);
        analyser::free(analyser, context.alloc);
    }

    List{Generator*} generators;
    generators.tinit();

    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;
        context.current_file = path;

        profiler::commit(context.profiler, "Generator");
        Generator* generator = generator::create(context);
        generator::generate_constants(generator, context, context.trees.get(context.current_file)!!);
        generators.push(generator);
    }

    foreach (Generator* generator : generators) {
        context.current_file   = generator.file;
        context.current_module = generator.module_name;

        generator::generate_node(generator, context, context.trees.get(context.current_file)!!);
        generator::emit(generator, context);
    }

    foreach (Generator* generator : generators) {
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

fn void remove_unused(CompileContext* context) => @pool() {
    HashMap{String, String} module_to_path;
    module_to_path.tinit();

    context.trees.@each(; name, ast) {
        module_to_path.set(ast.mod_node.path.path_node.path, name);
    };

    HashSet{String} used_modules;
    used_modules.tinit();

    StringList worklist;
    worklist.tinit();

    context.trees.@each(; name, ast) {
        if (!name.contains("/stdlib/") || name.contains("/stdlib/core/builtin.n")) {
            used_modules.add(ast.mod_node.path.path_node.path);

            foreach (String imp : get_imports(context, ast)) {
                worklist.push(imp);
            }
        }
    };

    while (worklist.len() > 0) {
        String? mod_name_result = worklist.pop_first();
        if (catch mod_name_result) {
            continue;
        }

        String mod_name = mod_name_result;

        if (used_modules.contains(mod_name)) {
            continue;
        }

        used_modules.add(mod_name);

        String? path = module_to_path.get(mod_name);
        if (catch err = path) {
            continue;
        }

        Node* imported_ast = context.trees.get(path)!!;
        foreach (String imp : get_imports(context, imported_ast)) {
            if (!used_modules.contains(imp)) {
                worklist.push(imp);
            }
        }
    }

    String[] all_names = context.trees.keys(context.alloc);
    foreach (String name : all_names) {
        Node* ast = context.trees.get(name)!!;
        String mod_name = ast.mod_node.path.path_node.path;

        if (!used_modules.contains(mod_name)) {
            context.trees.remove(name);
        }
    }

    StringList kept_files;
    kept_files.init(context.alloc);
    foreach (String file : context.args.files) {
        String path = file.to_tpath().absolute(context.alloc).copy(context.alloc)!!;

        if (context.trees.has_key(path)) {
            kept_files.push(file);
        }
    }

    context.args.files = kept_files;
}

fn StringList get_imports(CompileContext* context, Node* ast) {
    StringList imports;
    imports.init(context.alloc);

    foreach (Node* statement : ast.mod_node.statements) {
        if (statement.type != NodeType.USE) {
            continue;
        }

        imports.push(statement.use_node.path.path_node.path);
    }

    return imports;
}
