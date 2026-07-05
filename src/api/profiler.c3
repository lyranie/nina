module nina::api::profiler;

import nina::types;
import nina::profiler;

fn void profiler_commit(CompileContext* context, CChar* name) @export("nina_profiler_commit") {
    profiler::commit(context.profiler, ((ZString)name).str_view().copy(context.alloc));
}

fn void profiler_end(CompileContext* context) @export("nina_profiler_end") {
    profiler::end(context.profiler);
}
