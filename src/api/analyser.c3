module nina::api::analyser;

import nina::types;
import nina::analyser;

fn Analyser* analyser_create(CompileContext* context, Parser* parser) @export("nina_analyser_create") {
    return analyser::create(context.alloc, parser);
}

fn void analyser_analyse(CompileContext* context, Analyser* analyser, Parser* parser) @export("nina_analyser_analyse") {
    analyser::analyse(analyser, context, parser);
}

fn void analyser_free(CompileContext* context, Analyser* analyser) @export("nina_analyser_free") {
    analyser::free(analyser, context.alloc);
}
