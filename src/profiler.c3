module nina::profiler;

import nina::types;

import std::collections::map;
import std::time;
import std::io;

fn Profiler* create(Allocator alloc) {
    Profiler* profiler = alloc::new(alloc, Profiler);

    profiler.stages.init(alloc);
    profiler.start = time::now();

    return profiler;
}

fn void commit(Profiler* profiler, String name) {
$if $feature(DEBUG):
    Time now = time::now();

    if (profiler.stages.len() > 0) {
       ProfilerStage* last = &profiler.stages[profiler.stages.len() - 1];
       last.elapsed = (double)now.diff_us(profiler.start) / 1000.0;
   }
    
    profiler.stages.push({ .name = name });
    profiler.start = now;
$endif
}

fn void end(Profiler* profiler) {
$if $feature(DEBUG):
    Time now = time::now();

    if (profiler.stages.len() > 0) {
       ProfilerStage* last = &profiler.stages[profiler.stages.len() - 1];
       last.elapsed = (double)now.diff_us(profiler.start) / 1000.0;
   }

    double total = 0;
    foreach (ProfilerStage stage : profiler.stages) {
        total += stage.elapsed;
    }

    OrderedMap{String, double} stages;
    stages.tinit();

    foreach (ProfilerStage stage : profiler.stages) {
        if (stages.has_key(stage.name)) {
            stages.set(stage.name, stages.get(stage.name)!! + stage.elapsed);
        } else {
            stages.set(stage.name, stage.elapsed);
        }
    }

    io::printn();
    io::printn("PROFILER");
    io::printfn("%-20s %10s %6s", "Stage", "ms", "%");
    io::printfn("%.38s", "--------------------------------------");

    stages.@each(; name, elapsed) {
        double percentage = elapsed / total * 100;

        io::printfn("%-20s %10.2f %5.1f%%", name, elapsed, percentage);
    };

    io::printfn("%.38s", "--------------------------------------");
    io::printfn("%-20s %10.2f %5.1f%%", "total", total, 100);

    stages.free();
$endif
}
