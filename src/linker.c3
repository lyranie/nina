module nina::linker;

import llvm;

import nina::types;

import std::io;
import std::os;

fn Linker* create(CompileContext* context) {
    Linker* linker = alloc::new(context.alloc, Linker);

    linker.target_os   = TargetOS.UNKNOWN;
    linker.target_arch = TargetArch.UNKNOWN;
    
    if (context.args.output != "") {
        linker.output = context.args.output;
    } else {
        linker.output = context.args.files[0].replace(context.alloc, ".n", "").file_basename(context.alloc)!!;
    }

    create_default_target(linker, context.alloc);

    return linker;
}

fn void link(Linker* linker, CompileContext* context) {
    String[] link_command = build_link_command(linker, context);

    Process? process = process::spawn(link_command);
    if (catch err = process) {
        io::printfn("Failed to create linker process: %s", err);
        os::exit(1);
    }

    const BUF_SIZE = 64 * 1024;
    char[BUF_SIZE] stdout_buf;
    char[BUF_SIZE] stderr_buf;

    if (catch err = process.join()) {
        io::eprintfn("Failed to join linker process: %s", err);
        os::exit(1);
    }

    if (try sz len = process.read_stdout(&stdout_buf, BUF_SIZE)) {
        io::print((String)stdout_buf[:len]);
    }

    if (try sz len = process.read_stderr(&stderr_buf, BUF_SIZE)) {
        io::eprint((String)stderr_buf[:len]);
    }
}

fn void create_default_target(Linker* linker, Allocator alloc) {
    CChar*   default_target_triple = llvm::get_default_target_triple();
    String[] parts                 = ((ZString)default_target_triple).str_view().split(alloc, "-");

    switch (parts[0]) {
    case "x86_64":
        linker.target_arch = TargetArch.X86_64;
    default:
        io::eprintfn("Arch '%s' not supported yet", parts[0]);
        os::exit(1);
    }

    switch (parts[2]) {
    case "linux":
        linker.target_os = TargetOS.LINUX;
    default:
        io::eprintfn("OS '%s' nit supported yet", parts[2]);
        os::exit(1);
    }
}

fn String[] build_link_command(Linker* linker, CompileContext* context) {
    switch (linker.target_os) {
    case TargetOS.LINUX:
        return build_linux_link_command(linker, context);
    default:
        io::eprintfn("OS '%s' is not supported yet", linker.target_os);
        os::exit(1);
    }
}

fn String[] build_linux_link_command(Linker* linker, CompileContext* context) => @pool() {
    StringList command;
    command.tinit();

    command.push("ld.lld");

    if (env::LIBC && !context.args.no_libc) {
        command.push("/lib/crt1.o");
        command.push("/lib/crti.o");
        command.push("/lib/crtn.o");

        command.push("-lc");
    }

    command.push("-L/usr/lib");

    switch (linker.target_arch) {
    case TargetArch.X86_64:
        command.push("-m");
        command.push("elf_x86_64");
        command.push("--dynamic-linker");
        command.push("/lib64/ld-linux-x86-64.so.2");
    default:
        io::printfn("Arch '%s' not supported yet", linker.target_arch);
    }

    command.push("-o");
    command.push(linker.output);

    foreach (String mod : context.mods.keys(context.alloc)) {
        command.push(string::format(context.alloc, "out/obj/%s.o", mod));
    }

    defer  command.free();
    return command.to_array(context.alloc);
}

fn void free(Linker* linker) {
    
}
