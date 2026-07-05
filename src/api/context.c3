module nina::api::context;

import nina::core;
import nina::types;

fn CompileContext* context_create() @export("nina_context_create") {
    return core::context_create();
}

fn void context_free(CompileContext* context) @export("nina_context_free") {
    core::context_free(context);
}
