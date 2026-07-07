module nina::api::registry;

import nina::types;
import nina::registry;

fn void registry_register(CompileContext* context, Parser* parser) @export("nina_registry_register") {
    registry::register(context, parser);
}
