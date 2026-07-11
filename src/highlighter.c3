module nina::highlighter;

import nina::types;

import std::math;
import std::io;
import std::os;

fn void error(CompileContext* context, String file, Range from, Range to, String message, args...) @noreturn {
    String content  = (String)file::load(context.alloc, file)!!;
    String line_str = content.tsplit("\n")[from.line != 0 ? from.line - 1 : 0].copy(context.alloc);

    io::eprint(Ansi.BRIGHT_RED);
    io::eprint(Ansi.BOLD);
    io::eprintf("Error: ");
    io::eprint(Ansi.RESET);
    io::eprintfn(message, ...args);

    int line    = from.line;
    int padding = 0;

    while (line != 0) {
        line /= 10;
        padding++;
    }

    for (int i = math::max(0, from.line - 3); i < from.line; i++) {
        if (to.line != from.line && i + 1 == from.line) {
            io::eprintfn("%-*d: %s…", padding, i + 1, content.tsplit("\n")[i]);
        } else {
            io::eprintfn("%-*d: %s", padding, i + 1, content.tsplit("\n")[i]);
        }
    }

    for (int i = 0; i < padding + 2 + from.column; i++) {
        io::eprint(" ");
    }

    if (to.line != from.line) {
        for (int i = 0; i < line_str.len - from.column; i++) {
            io::eprint("^");
        }
    } else {
        for (int i = 0; i < to.column - from.column; i++) {
            io::eprint("^");
        }
    }

    io::eprintn();
    io::eprintfn("in file (%s %d:%d)", context.current_file, from.line, from.column);

    os::exit(1);
}

fn void note(CompileContext* context, String file, Range from, Range to, String message, args...) {
    String content  = (String)file::load(context.alloc, file)!!;
    String line_str = content.tsplit("\n")[from.line != 0 ? from.line - 1 : 0].copy(context.alloc);

    io::eprint(Ansi.BRIGHT_BLUE);
    io::eprint(Ansi.BOLD);
    io::eprintf("Note: ");
    io::eprint(Ansi.RESET);
    io::eprintfn(message, ...args);

    int line    = from.line;
    int padding = 0;

    while (line != 0) {
        line /= 10;
        padding++;
    }

    for (int i = math::max(0, from.line - 3); i < from.line; i++) {
        if (to.line != from.line && i + 1 == from.line) {
            io::eprintfn("%-*d: %s…", padding, i + 1, content.tsplit("\n")[i]);
        } else {
            io::eprintfn("%-*d: %s", padding, i + 1, content.tsplit("\n")[i]);
        }
    }

    for (int i = 0; i < padding + 2 + from.column; i++) {
        io::eprint(" ");
    }

    if (to.line != from.line) {
        for (int i = 0; i < line_str.len - from.column; i++) {
            io::eprint("^");
        }
    } else {
        for (int i = 0; i < to.column - from.column; i++) {
            io::eprint("^");
        }
    }

    io::eprintn();
    io::eprintfn("in file (%s %d:%d)", context.current_file, from.line, from.column);
}

fn void warn(CompileContext* context, String file, Range from, Range to, String message, args...) {
    String content  = (String)file::load(context.alloc, file)!!;
    String line_str = content.tsplit("\n")[from.line != 0 ? from.line - 1 : 0].copy(context.alloc);

    io::eprint(Ansi.BRIGHT_YELLOW);
    io::eprint(Ansi.BOLD);
    io::eprintf("Warning: ");
    io::eprint(Ansi.RESET);
    io::eprintfn(message, ...args);

    int line    = from.line;
    int padding = 0;

    while (line != 0) {
        line /= 10;
        padding++;
    }

    for (int i = math::max(0, from.line - 3); i < from.line; i++) {
        if (to.line != from.line && i + 1 == from.line) {
            io::eprintfn("%-*d: %s…", padding, i + 1, content.tsplit("\n")[i]);
        } else {
            io::eprintfn("%-*d: %s", padding, i + 1, content.tsplit("\n")[i]);
        }
    }

    for (int i = 0; i < padding + 2 + from.column; i++) {
        io::eprint(" ");
    }

    if (to.line != from.line) {
        for (int i = 0; i < line_str.len - from.column; i++) {
            io::eprint("^");
        }
    } else {
        for (int i = 0; i < to.column - from.column; i++) {
            io::eprint("^");
        }
    }

    io::eprintn();
    io::eprintfn("in file (%s %d:%d)", context.current_file, from.line, from.column);
}

macro panic(String message = "", args...) @noreturn {
    String location     = string::tformat("%s(%d)", $$FILE, $$LINE);
    String line         = string::tformat("Error in file %s (%s)", location, $$FUNC);
    String message_line = string::tformat(message, ...args);
    int    pad          = 60 - line.len - 1;
    int    message_pad  = 60 - message_line.len - 1;

    io::eprint(Ansi.YELLOW);
    io::eprintfn("┌────────────────────────────────────────────────────────────┐");
    io::eprintfn("│ Whoops! You've hit a roadblock. Seems like this feature    │");
    io::eprintfn("│ isn't implemented yet. Feel free to create an issue here:  │");
    io::eprintfn("│   https://codeberg.org/lyranie/nina/issues                 │");
    io::eprintfn("│                                                            │");
    io::eprintfn("│ %s%*s│", line, pad, "");

    if (message != "") {
        io::eprintfn("│ %s%*s│", message_line, message_pad, "");
    }

    io::eprintfn("└────────────────────────────────────────────────────────────┘");
    io::eprint(Ansi.RESET);

    os::exit(1);
}
