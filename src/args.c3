module nina::args;

import nina::types;

import std::io;
import std::os;

fn Args* create(Allocator alloc) {
    Args* args = alloc::new(alloc, Args);

    args.cmd     = CompileCommand.NONE;
    args.emit_ir = false;
    args.no_libc = false;
    args.output  = "";
    args.files.init(alloc);

    return args;
}

fn void parse(Args* args, String[] argv) {
    if (argv.len == 1) {
        print_help(argv[0]);
    }

    for (int i = 1; i < argv.len; i++) {
        switch (String arg = argv[i]) {
        case "compile":
            if ((long)i + 1 >= argv.len) {
                print_help(argv[0]);
            }

            args.cmd = CompileCommand.COMPILE;

            for (int j = i + 1; j < argv.len && !argv[j].starts_with("-"); j++, i++) {
                args.files.push(argv[j]);
            }
        case "compile-run":
            if ((long)i + 1 >= argv.len) {
                print_help(argv[0]);
            }

            args.cmd = CompileCommand.COMPILE_RUN;

            for (int j = i + 1; j < argv.len && !argv[j].starts_with("-"); j++, i++) {
                args.files.push(argv[j]);
            }
        case "--output":
        case "-o":
            if ((long)i + 1 >= argv.len) {
                print_help(argv[0]);
            }

            args.output = argv[++i];
        case "--ir":
            args.emit_ir = true;
        case "--no-libc":
            args.no_libc = true;
        case "--no-debug":
            args.no_debug = true;
        case "--no-link":
            args.no_linker = true;
        case "--help":
        case "-h":
            print_help(argv[0]);
        }
    }
}

fn void print_help(String program) @noreturn @private {
    io::printfn("Usage: %s <command> [options]", program);
    io::printfn("");
    io::printfn("Commands:");
    io::printfn("  compile     <files>          Compiles the given files.");
    io::printfn("  compile-run <files>          Compiles the given files and runs the resulting binary.");
    io::printfn("");
    io::printfn("Options:");
    io::printfn("  --help, -h                   Displays a page with all commands and options.");
    io::printfn("  --ir                         Emits the generated IR files for the selected backend.");
    io::printfn("  --no-libc                    Doesn't link against libc and the crt.");
    io::printfn("  --output, -o <file>          Specifies the output filename.");
    io::printfn("  --no-debug                   Doesn't emit debug symbols.");
    io::printfn("  --no-link                    Doesn't run the linker setup.");

    os::exit(0);
}
