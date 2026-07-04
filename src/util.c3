module nina;

import std::io;

fn bool char.is_newline(self) {
    return self == '\n' || self == '\r';
}

macro @todo(String fmt, args...) @builtin {
$if $feature(DEBUG):
    io::print(ansi::color_rgb(255, 204, 255, true));
    io::print(Ansi.BLACK);
    io::print(Ansi.BOLD);
    io::print("TODO: ");
    io::printf(fmt, ...args);
    io::printf(" (%s %d)", $$FILE, $$LINE);
    io::printn(Ansi.RESET);
$endif
}

module llvm;

fn LLVMTypeRef slice_type(LLVMTypeRef base) {
    LLVMTypeRef   pointer_type = llvm::pointer_type(base, 0);
    LLVMTypeRef   int_type     = llvm::int_32_type();
    LLVMTypeRef[] slice_types  = {pointer_type, int_type};

    return llvm::struct_type(slice_types, 2, llvm::FALSE);
}

extern fn void initialize_x86_target_info()  @cname("LLVMInitializeX86TargetInfo");
extern fn void initialize_x86_target()       @cname("LLVMInitializeX86Target");
extern fn void initialize_x86_target_mc()    @cname("LLVMInitializeX86TargetMC");
extern fn void initialize_x86_asm_printer()  @cname("LLVMInitializeX86AsmPrinter");
extern fn void initialize_x86_asm_parser()   @cname("LLVMInitializeX86AsmParser");
extern fn void initialize_x86_disassembler() @cname("LLVMInitializeX86Disassembler");
