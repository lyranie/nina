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

module nina::util;

import nina::types;

import libc;

fn int precedence(TokenType type) {
    switch (type) {
        case TokenType.OR:
            return 1;
        case TokenType.AND:
            return 2;
        case TokenType.IS_EQUAL:
        case TokenType.NOT_EQUAL:
            return 3;
        case TokenType.LANGLE:
        case TokenType.RANGLE:
        case TokenType.LTE:
        case TokenType.GTE:
            return 4;
        case TokenType.PLUS:
        case TokenType.MINUS:
            return 5;
        case TokenType.ASTERISK:
        case TokenType.SLASH:
            return 6;
        default:
            return 0;
    }
}

macro String @get_exec() {
    $switch:
    $case env::LINUX:
        char[4096] buffer;

        long len = libc::readlink("/proc/self/exe", &buffer, 4096);

        return (String)buffer[..len];
    $endswitch
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
