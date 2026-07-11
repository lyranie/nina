import nina::types;

import std::io;
import std::math;
import std::os::process;
import std::collections::map;

extern fn CompileContext* nina_context_create();
extern fn void nina_context_free(CompileContext* context);

extern fn Lexer* nina_lexer_create(CompileContext* context, CChar* path);
extern fn void nina_lexer_tokenize(CompileContext *context, Lexer* lexer);
extern fn void nina_lexer_free(CompileContext* context, Lexer* lexer);

extern fn Parser* nina_parser_create(CompileContext* context, Lexer* lexer);
extern fn void nina_parser_parse(CompileContext* context, Parser* parser, Lexer* lexer);
extern fn void nina_parser_free(CompileContext* context, Parser* parser);

extern fn void nina_registry_register(CompileContext* context, Parser* parser);

extern fn Analyser* nina_analyser_create(CompileContext* context, CChar* path);
extern fn void nina_analyser_analyse(CompileContext* context, Analyser* analyser, Parser* parser);
extern fn void nina_analyser_free(CompileContext* context, Analyser* analyser);

extern fn Generator* nina_generator_create(CompileContext* context, Parser* parser);
extern fn void nina_generator_generate(CompileContext *context, Generator* generator, Parser* parser);
extern fn void nina_generator_free(CompileContext *context, Generator* generator);

alias Summary = HashMap{String, bool};

fn void main() {
    path::mkdir("out")!!;
    path::mkdir("out/ir")!!;
    path::mkdir("out/obj")!!;

    CompileContext* context = nina_context_create();
    context.args.emit_ir  = true;
    context.args.no_debug = true;

    Path     dir   = path::tnew("test/unit")!!;
    PathList items = path::ls(context.alloc, dir)!!;

    Summary summary;
    summary.init(context.alloc);

    for (int i = 0; i < items.len(); i++) {
        Path path = items[i];

        if (!path.has_extension("n")) {
            continue;
        }
        
        summary.set(path, run_test(context, ((String)path).strip_suffix(".n")));
    }

    print_summary(context, summary);

    nina_context_free(context);
}

fn bool run_test(CompileContext* context, String name) {
    String test_file = string::format(context.alloc, "test/unit/%s.n", name);

    Lexer* lexer = nina_lexer_create(context, (CChar*)test_file.ptr);
    nina_lexer_tokenize(context, lexer);

    Parser* parser = nina_parser_create(context, lexer);
    nina_parser_parse(context, parser, lexer);

    nina_registry_register(context, parser);

    Analyser* analyser = nina_analyser_create(context, (CChar*)test_file.ptr);
    nina_analyser_analyse(context, analyser, parser);

    Generator* generator = nina_generator_create(context, parser);
    nina_generator_generate(context, generator, parser);

    String module_name = generator.module_name;
    String ir_file     = string::format(context.alloc, "out/ir/%s.ll", module_name);
    String obj_file    = string::format(context.alloc, "out/obj/%s.o", module_name);

    nina_lexer_free(context, lexer);
    nina_parser_free(context, parser);
    nina_analyser_free(context, analyser);
    nina_generator_free(context, generator);

    if (catch path::delete(obj_file.to_path(context.alloc))) {
        io::eprintfn("Failed to delete file '%s'", obj_file);
    }

    String   generated      = (String)file::load(context.alloc, ir_file)!!;
    String[] expected_parts = ((String)file::load(context.alloc, test_file)).split(context.alloc, "/*")!!;
    String   expected       = "";
    if (expected_parts.len == 2) {
        expected = expected_parts[1];
    }

    if (expected.len != 0 && !generated.contains(expected)) {
        io::eprint(ansi::get_color(0x9b55e0));
        io::eprintf("Test '%s' failed", name);
        io::eprintn(Ansi.RESET);

        int offset = find_offset(context, generated, expected);
        report(context, name, generated, expected, offset);

        return false;
    }

    return true;
}

fn int find_offset(CompileContext* context, String generated, String expected) {
    String[] generated_lines = generated.split(context.alloc, "\n");
    String[] expected_lines  = expected.split(context.alloc, "\n");

    int best_offset = 0;
    int best_score  = -1;

    int max_offset = generated_lines.len - expected_lines.len;
    if (max_offset < 0) {
        max_offset = 0;
    }

    for (int offset = 0; offset <= max_offset; offset++) {
        int score = 0;

        for (int i = 0; i < expected_lines.len; i++) {
            int generated_index = (int)offset + i;
            if (generated_index >= generated_lines.len) {
                break;
            }

            if (generated_lines[generated_index] == expected_lines[i]) {
                score++;
                continue;
            }
        }

        if (score > best_score) {
            best_score  = score;
            best_offset = offset;
        }
    }

    return best_offset;
}

fn void report(CompileContext* context, String test, String generated, String expected, int offset) {
    String[] generated_lines = generated.split(context.alloc, "\n");
    String[] expected_lines  = expected.split(context.alloc, "\n");

    for (int i = 0; i < expected_lines.len; i++) {
        int generated_index = offset + i;

        String expected_line  = expected_lines[i];
        String generated_line = "";
        if (generated_index < generated_lines.len) {
            generated_line = generated_lines[generated_index];
        }

        if (generated_line == expected_line) {
            continue;
        }

        int column_start = get_column_start(expected_line, generated_line);
        int column_end   = (int)math::max(expected_line.len, generated_line.len);

        Range from = { .line = generated_index + 1, .column = column_start };
        Range to   = { .line = generated_index + 1, .column = column_end };

        error(context, test, generated, expected_line, from, to);
    }
}

fn int get_column_start(String expected_line, String generated_line) {
    int min_length = (int)math::min(expected_line.len, generated_line.len);

    for (int i = 0; i < min_length; i++) {
        if (expected_line[i] != generated_line[i]) {
            return i;
        }
    }

    return min_length;
}

fn void error(CompileContext* context, String test, String content, String expected_line, Range from, Range to) {
    String line_str = content.tsplit("\n")[from.line != 0 ? from.line - 1 : 0].copy(context.alloc);

    int line    = from.line;
    int padding = 0;

    while (line != 0) {
        line /= 10;
        padding++;
    }

    for (int i = math::max(0, from.line - 3); i < from.line; i++) {
        io::eprintfn("%-*d: %s", padding, i + 1, content.tsplit("\n")[i]);
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

    io::eprintn(ansi::get_color(0x2aad8c));
    io::eprint("expected: ");
    io::eprintn(Ansi.RESET);
    io::eprintfn("%-*d: %s", padding, from.line, expected_line);
    
    io::eprintn("──────────────────────────────");
}

fn void print_summary(CompileContext* context, Summary summary) {
    String separator  = "──────────────────────────────";
    int    line_width = 30;

    io::printn();
    io::printn("Test Summary");
    io::printn(separator);

    int passed = 0;

    foreach (String name : summary.keys(context.alloc)) {
        String status  = summary[name]!! ? "passed" : "failed";
        int    padding = line_width - name.len - status.len;

        if (padding < 1) {
            padding = 1;
        }

        io::print(name);
        for (int i = 0; i < padding; i++) {
            io::print(" ");
        }
        
        AnsiColor color = ansi::get_color(0xc73232);
        if (status == "passed") {
            color = ansi::get_color(0x32c74b);
        }

        io::print(color);
        io::print(status);
        io::printn(Ansi.RESET);

        if (summary[name]!!) {
            passed++;
        }
    }

    io::printn("──────────────────────────────");
    io::printfn("%d/%d passed", passed, summary.len());
}
