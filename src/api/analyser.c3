module nina::api::analyser;

import nina::types;
import nina::analyser;

fn Analyser* analyser_create(CompileContext* context, CChar* path) @export("nina_analyser_create") {
    return analyser::create(context, ((ZString)path).str_view().copy(context.alloc));
}

fn void analyser_analyse(CompileContext* context, Analyser* analyser) @export("nina_analyser_analyse") {
    analyser::analyse(analyser, context);
}

fn void analyser_free(CompileContext* context, Analyser* analyser) @export("nina_analyser_free") {
    analyser::free(analyser, context.alloc);
}
