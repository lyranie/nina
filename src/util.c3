module nina;

import std::io;

fn bool char.is_newline(self) {
    return self == '\n' || self == '\r';
}

fn bool char.is_hex_digit(self) {
    return (self >= '0' && self <= '9') || 
           (self >= 'a' && self <= 'f') || 
           (self >= 'A' && self <= 'F');
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
        case TokenType.PIPE:
            return 3;
        case TokenType.CARET:
            return 4;
        case TokenType.AMP:
            return 5;
        case TokenType.IS_EQUAL:
        case TokenType.NOT_EQUAL:
            return 6;
        case TokenType.LANGLE:
        case TokenType.RANGLE:
        case TokenType.LTE:
        case TokenType.GTE:
            return 7;
        case TokenType.SHL:
        case TokenType.SHR:
            return 8;
        case TokenType.PLUS:
        case TokenType.MINUS:
            return 9;
        case TokenType.ASTERISK:
        case TokenType.SLASH:
            return 10;
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

fn bool try_get_typeid_narrowing(Node* condition, String* out_var, String* out_type) {
    if (condition.type != NodeType.BIN) {
        return false;
    }

    if (condition.bin_node.operator.type != TokenType.IS_EQUAL) {
        return false;
    }

    Node* left  = condition.bin_node.left;
    Node* right = condition.bin_node.right;

    String var_name;
    if (!is_ident_typeid_access(left, &var_name)) {
        return false;
    }

    String type_name;
    if (!is_type_typeid_access(right, &type_name)) {
        return false;
    }

    *out_var  = var_name;
    *out_type = type_name;

    return true;
}

fn bool try_get_typeid_narrowing_switch(Node* subject, Node* case_expr, String* out_var, String* out_type) {
    String var_name;
    if (!is_ident_typeid_access(subject, &var_name)) {
        return false;
    }

    String type_name;
    if (!is_type_typeid_access(case_expr, &type_name)) {
        return false;
    }

    *out_var  = var_name;
    *out_type = type_name;
    return true;
}

fn bool is_ident_typeid_access(Node* node, String* out_var) {
    if (node.type != NodeType.ACCESS) {
        return false;
    }

    if (node.access_node.name.type != NodeType.IDENT) {
        return false;
    }

    if (!node.access_node.next) {
        return false;
    }

    if (node.access_node.next.type != NodeType.IDENT) {
        return false;
    }

    if (node.access_node.next.ident_node.name != "$typeid") {
        return false;
    }

    *out_var = node.access_node.name.ident_node.name;
    return true;
}

fn bool is_type_typeid_access(Node* node, String* out_type) {
    if (node.type != NodeType.ACCESS) {
        return false;
    }

    if (node.access_node.name.type != NodeType.IDENT) {
        return false;
    }

    if (!node.access_node.next) {
        return false;
    }

    if (node.access_node.next.type != NodeType.IDENT) {
        return false;
    }

    if (node.access_node.next.ident_node.name != "$typeid") {
        return false;
    }

    *out_type = node.access_node.name.ident_node.name;
    return true;
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
