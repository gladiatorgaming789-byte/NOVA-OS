BITS 16
ORG 0x1000

; Temporary physical layout for this BIOS prototype. Keep the stack separate
; from the page-table pages until E820 discovery and a real allocator exist.
STACK_TOP equ 0x8F000
PML4_ADDR equ 0x90000
PDPT_ADDR equ 0x91000
PD_ADDR   equ 0x92000
VGA_TEXT_ADDR equ 0xB8000

kernel_entry:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    call serial_init
    mov si, marker_e
    call print16
    call collect_e820

    ; Enable A20 using the fast A20 gate.
    in al, 0x92
    or al, 00000010b
    and al, 11111110b
    out 0x92, al

    lgdt [gdt_descriptor]
    mov si, marker_g
    call print16
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp CODE32_SEL:protected_mode_entry

; Initialize COM1 at 38400 baud, 8-N-1.
serial_init:
    push ax
    push dx
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8
    mov al, 3
    out dx, al
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 3
    out dx, al
    mov dx, 0x3FA
    mov al, 0xC7
    out dx, al
    mov dx, 0x3FC
    mov al, 0x0B
    out dx, al
    pop dx
    pop ax
    ret

; Write AL to COM1 with a bounded wait so a missing UART cannot hang boot.
serial_putc:
    push ax
    push cx
    push dx
    mov ah, al
    mov dx, 0x3FD
    mov cx, 0xFFFF
.wait:
    in al, dx
    test al, 0x20
    jnz .ready
    loop .wait
    jmp .done
.ready:
    mov dx, 0x3F8
    mov al, ah
    out dx, al
.done:
    pop dx
    pop cx
    pop ax
    ret

print16:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    ; Mirror every early marker to COM1 for a persistent log.
    push ax
    call serial_putc
    pop ax
    jmp print16
.done:
    ret


; Collect the BIOS E820 memory map into physical 0x5000 (up to 32 entries).
; Each entry is 24 bytes. This is discovery only; no allocator uses it yet.
collect_e820:
    pushad
    push es
    xor ax, ax
    mov es, ax
    mov word [e820_count], 0
    mov dword [e820_continuation], 0
.next_entry:
    cmp word [e820_count], 32
    jae .done
    mov ax, [e820_count]
    mov dx, 24
    mul dx
    add ax, 0x5000
    mov di, ax
    mov dword [es:di + 20], 1
    mov eax, 0xE820
    mov edx, 0x534D4150
    mov ecx, 24
    mov ebx, [e820_continuation]
    int 0x15
    jc .done
    cmp eax, 0x534D4150
    jne .done
    cmp ecx, 20
    jb .done
    inc word [e820_count]
    mov [e820_continuation], ebx
    test ebx, ebx
    jnz .next_entry
.done:
    pop es
    popad
    ret

align 8
gdt_start:
    dq 0x0000000000000000
gdt_code32:
    dq 0x00CF9A000000FFFF
gdt_data32:
    dq 0x00CF92000000FFFF
gdt_code64:
    dq 0x00AF9A000000FFFF
gdt_data64:
    dq 0x00CF92000000FFFF
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE32_SEL equ gdt_code32 - gdt_start
DATA32_SEL equ gdt_data32 - gdt_start
CODE64_SEL equ gdt_code64 - gdt_start
DATA64_SEL equ gdt_data64 - gdt_start

BITS 32
protected_mode_entry:
    mov ax, DATA32_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax
    mov esp, STACK_TOP

    mov esi, marker_c
    call print32

    ; Clear PML4, PDPT, and PD at 0x90000, 0x91000, 0x92000.
    xor eax, eax
    mov edi, PML4_ADDR
    mov ecx, (3 * 4096) / 4
    rep stosd

    mov dword [PML4_ADDR], PDPT_ADDR | 3
    mov dword [PML4_ADDR + 4], 0
    mov dword [PDPT_ADDR], PD_ADDR | 3
    mov dword [PDPT_ADDR + 4], 0

    ; Identity map first 1 GiB using 512 2-MiB pages.
    mov edi, PD_ADDR
    mov eax, 0x00000083
    mov ecx, 512
.map_pages:
    mov [edi], eax
    mov dword [edi + 4], 0
    add eax, 0x200000
    add edi, 8
    loop .map_pages

    mov esi, marker_j
    call print32

    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    mov eax, PML4_ADDR
    mov cr3, eax

    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    mov esi, marker_p
    call print32
    jmp CODE64_SEL:long_mode_entry

; 32-bit COM1 output routine (must be encoded for protected mode).
serial_putc32:
    push eax
    push ecx
    push edx
    mov ah, al
    mov dx, 0x3FD
    mov ecx, 0xFFFF
.wait:
    in al, dx
    test al, 0x20
    jnz .ready
    loop .wait
    jmp .done
.ready:
    mov dx, 0x3F8
    mov al, ah
    out dx, al
.done:
    pop edx
    pop ecx
    pop eax
    ret

print32:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0F
    mov ebx, 0x000B8000
    mov edx, [vga_cursor]
    mov [ebx + edx], ax
    push eax
    call serial_putc32
    pop eax
    add edx, 2
    mov [vga_cursor], edx
    jmp print32
.done:
    ret

BITS 64
; 64-bit COM1 output routine.
serial_putc64:
    push rax
    push rcx
    push rdx
    mov ah, al
    mov dx, 0x3FD
    mov ecx, 0xFFFF
.wait:
    in al, dx
    test al, 0x20
    jnz .ready
    loop .wait
    jmp .done
.ready:
    mov dx, 0x3F8
    mov al, ah
    out dx, al
.done:
    pop rdx
    pop rcx
    pop rax
    ret

long_mode_entry:
    mov ax, DATA64_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, STACK_TOP
    cld
    mov al, 'L'
    call serial_putc64

    ; Install exception gates before starting kernel services.
    call init_idt64
%ifdef NOVA_TEST_EXCEPTION
    int3                         ; CI-only fault injection validates the IDT.
%endif
    call screen_clear64
    mov rsi, banner64
    call print_string64
    mov al, 10
    call put_char64
    call print_prompt64

.keyboard_loop:
    call poll_keyboard64
    test al, al
    jz .keyboard_loop
    cmp al, 10
    je .enter
    cmp al, 8
    je .backspace
    mov ecx, [line_length]
    cmp ecx, 127
    jae .keyboard_loop
    mov [line_buffer + rcx], al
    inc ecx
    mov [line_length], ecx
    call put_char64
    jmp .keyboard_loop
.backspace:
    mov ecx, [line_length]
    test ecx, ecx
    jz .keyboard_loop
    dec ecx
    mov [line_length], ecx
    mov byte [line_buffer + rcx], 0
    mov al, 8
    call put_char64
    jmp .keyboard_loop
.enter:
    mov ecx, [line_length]
    mov byte [line_buffer + rcx], 0
    mov al, 10
    call put_char64
    call execute_command64
    mov dword [line_length], 0
    mov byte [line_buffer], 0
    call print_prompt64
    jmp .keyboard_loop

screen_clear64:
    push rax
    push rcx
    push rdi
    mov rdi, VGA_TEXT_ADDR
    mov ax, 0x0720
    mov ecx, 2000
    rep stosw
    mov dword [screen_cursor], 0
    pop rdi
    pop rcx
    pop rax
    ret

scroll_screen64:
    push rax
    push rcx
    push rsi
    push rdi
    mov rsi, VGA_TEXT_ADDR + 160
    mov rdi, VGA_TEXT_ADDR
    mov ecx, 1920
    rep movsw
    mov rdi, VGA_TEXT_ADDR + 3840
    mov ax, 0x0720
    mov ecx, 80
    rep stosw
    mov dword [screen_cursor], 1920
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; AL = character. Handles LF, backspace, scrolling, VGA and serial output.
put_char64:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    mov bl, al
    cmp bl, 10
    je .newline
    cmp bl, 8
    je .erase
    cmp bl, 13
    je .carriage_return
    mov al, bl
    call serial_putc64
    mov eax, [screen_cursor]
    cmp eax, 2000
    jb .write_character
    call scroll_screen64
.write_character:
    mov edx, [screen_cursor]
    mov rdi, 0xB8000
    mov al, bl
    mov ah, 0x0A
    mov [rdi + rdx*2], ax
    mov eax, [screen_cursor]
    inc eax
    mov [screen_cursor], eax
    cmp eax, 2000
    jb .done
    call scroll_screen64
    jmp .done
.newline:
    mov al, 13
    call serial_putc64
    mov al, 10
    call serial_putc64
    mov eax, [screen_cursor]
    xor edx, edx
    mov ecx, 80
    div ecx
    inc eax
    imul eax, eax, 80
    mov [screen_cursor], eax
    cmp eax, 2000
    jb .done
    call scroll_screen64
    jmp .done
.carriage_return:
    mov al, 13
    call serial_putc64
    jmp .done
.erase:
    mov al, 8
    call serial_putc64
    mov al, ' '
    call serial_putc64
    mov al, 8
    call serial_putc64
    mov eax, [screen_cursor]
    test eax, eax
    jz .done
    dec eax
    mov [screen_cursor], eax
    mov edx, eax
    mov rdi, 0xB8000
    mov ax, 0x0A20
    mov [rdi + rdx*2], ax
.done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

print_string64:
    lodsb
    test al, al
    jz .done
    call put_char64
    jmp print_string64
.done:
    ret

print_prompt64:
    mov rsi, prompt64
    call print_string64
    ret

; Non-blocking PS/2 set-1 scancode polling; no IRQ/IDT is required yet.
; Returns ASCII in AL or zero when no printable key was pressed.
poll_keyboard64:
    push rdx
    mov dx, 0x64
    in al, dx
    test al, 1
    jz .none
    mov dx, 0x60
    in al, dx
    cmp al, 0xAA
    je .shift_up
    cmp al, 0xB6
    je .shift_up
    test al, 0x80
    jnz .none
    cmp al, 0x2A
    je .shift_down
    cmp al, 0x36
    je .shift_down
    cmp al, 0x3A
    je .caps_toggle
    movzx r8d, al
    mov al, [scan_ascii + r8]
    test al, al
    jz .none
    cmp al, 'a'
    jb .punctuation
    cmp al, 'z'
    ja .punctuation
    mov cl, [shift_pressed]
    xor cl, [caps_lock]
    test cl, cl
    jz .return_key
    sub al, 32
    jmp .return_key
.punctuation:
    cmp byte [shift_pressed], 0
    je .return_key
    mov al, [scan_shifted + r8]
    test al, al
    jz .none
.return_key:
    pop rdx
    ret
.shift_down:
    mov byte [shift_pressed], 1
    xor eax, eax
    pop rdx
    ret
.caps_toggle:
    xor byte [caps_lock], 1
    xor eax, eax
    pop rdx
    ret
.shift_up:
    mov byte [shift_pressed], 0
.none:
    xor eax, eax
    pop rdx
    ret

execute_command64:
    mov rsi, line_buffer
    mov rdi, command_help
    call strings_equal64
    test al, al
    jnz .help
    mov rsi, line_buffer
    mov rdi, command_about
    call strings_equal64
    test al, al
    jnz .about
    mov rsi, line_buffer
    mov rdi, command_clear
    call strings_equal64
    test al, al
    jnz .clear
    mov rsi, line_buffer
    mov rdi, command_reboot
    call strings_equal64
    test al, al
    jnz .reboot
    mov rsi, line_buffer
    mov rdi, command_memory
    call strings_equal64
    test al, al
    jnz .memory
    cmp byte [line_buffer], 0
    je .done
    mov rsi, message_unknown
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.help:
    mov rsi, message_help
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.about:
    mov rsi, message_about
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.clear:
    call screen_clear64
    mov rsi, banner64
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.memory:
    mov rsi, message_memory
    call print_string64
    mov ax, [e820_count]
    call print_hex16
    mov al, 10
    call put_char64
    jmp .done
.reboot:
    mov rsi, message_reboot
    call print_string64
    mov al, 10
    call put_char64
.wait_controller:
    mov ecx, 0xFFFF
.wait_input_buffer:
    mov dx, 0x64
    in al, dx
    test al, 2
    jz .send_reset
    loop .wait_input_buffer
    mov rsi, message_reboot_failed
    call print_string64
    mov al, 10
    call put_char64
    jmp .halt
.send_reset:
    mov al, 0xFE
    out 0x64, al
    cli
.halt:
    hlt
    jmp .halt
.done:
    ret

; AL=1 when the zero-terminated strings match; otherwise AL=0.
print_hex16:
    push rbx
    push rcx
    mov bx, ax
    mov ecx, 4
.hex_digit:
    mov eax, ebx
    shr eax, 12
    and eax, 0x0F
    mov al, [hex_digits64 + rax]
    call put_char64
    shl bx, 4
    loop .hex_digit
    pop rcx
    pop rbx
    ret

strings_equal64:
    push rsi
    push rdi
.compare:
    mov al, [rsi]
    cmp al, [rdi]
    jne .different
    test al, al
    jz .same
    inc rsi
    inc rdi
    jmp .compare
.same:
    mov al, 1
    pop rdi
    pop rsi
    ret
.different:
    xor al, al
    pop rdi
    pop rsi
    ret



; Install gates for the 32 architecturally defined CPU exception vectors.
; Hardware IRQs remain disabled until an interrupt controller is implemented.
init_idt64:
    lidt [rel idtr64]
    ret

exception_common64:
    ; Stubs normalize the stack to [vector, error code, saved RIP, ...].
    mov ebx, [rsp]
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push rbx

    mov rsi, exception_prefix64
.print_prefix:
    lodsb
    test al, al
    jz .print_vector
    call serial_putc64
    jmp .print_prefix

.print_vector:
    mov eax, ebx
    shr eax, 4
    and eax, 0x0F
    mov al, [hex_digits64 + rax]
    call serial_putc64
    mov eax, ebx
    and eax, 0x0F
    mov al, [hex_digits64 + rax]
    call serial_putc64
    mov al, 13
    call serial_putc64
    mov al, 10
    call serial_putc64
.halt:
    cli
    hlt
    jmp .halt

%macro ISR_NOERR 1
isr%1:
    push qword 0
    push qword %1
    jmp exception_common64
%endmacro

%macro ISR_ERR 1
isr%1:
    push qword %1
    jmp exception_common64
%endmacro

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

%macro IDT_GATE 1
    dw %1 & 0xFFFF
    dw CODE64_SEL
    db 0
    db 0x8E
    dw (%1 >> 16) & 0xFFFF
    dd (%1 >> 32) & 0xFFFFFFFF
    dd 0
%endmacro

align 16
idt64:
    IDT_GATE isr0
    IDT_GATE isr1
    IDT_GATE isr2
    IDT_GATE isr3
    IDT_GATE isr4
    IDT_GATE isr5
    IDT_GATE isr6
    IDT_GATE isr7
    IDT_GATE isr8
    IDT_GATE isr9
    IDT_GATE isr10
    IDT_GATE isr11
    IDT_GATE isr12
    IDT_GATE isr13
    IDT_GATE isr14
    IDT_GATE isr15
    IDT_GATE isr16
    IDT_GATE isr17
    IDT_GATE isr18
    IDT_GATE isr19
    IDT_GATE isr20
    IDT_GATE isr21
    IDT_GATE isr22
    IDT_GATE isr23
    IDT_GATE isr24
    IDT_GATE isr25
    IDT_GATE isr26
    IDT_GATE isr27
    IDT_GATE isr28
    IDT_GATE isr29
    IDT_GATE isr30
    IDT_GATE isr31
idt64_end:

idtr64:
    dw idt64_end - idt64 - 1
    dq idt64

exception_prefix64 db 'NOVA exception vector 0x', 0
hex_digits64 db '0123456789ABCDEF'

BITS 16
vga_cursor dd 8
e820_count dw 0
e820_continuation dd 0
marker_e db 'E', 0
marker_g db 'G', 0
BITS 32
marker_c db 'C', 0
marker_j db 'J', 0
marker_p db 'P', 0
BITS 64
banner64 db 'NOVA OS - 64-bit kernel online', 0
prompt64 db 'nova> ', 0
command_help db 'help', 0
command_about db 'about', 0
command_clear db 'clear', 0
command_reboot db 'reboot', 0
command_memory db 'memory', 0
message_help db 'Commands: help, about, clear, reboot', 0
message_about db 'NOVA OS is an experimental x86-64 operating system built from scratch.', 0
message_unknown db 'Unknown command. Type help.', 0
message_memory db 'Firmware E820 entries: 0x', 0
message_reboot db 'Rebooting NOVA OS...', 0
message_reboot_failed db 'Reboot controller timed out; system halted safely.', 0
line_length dd 0
screen_cursor dd 0
shift_pressed db 0
caps_lock db 0
line_buffer times 128 db 0
scan_ascii:
    db 0,0,'1','2','3','4','5','6','7','8','9','0','-','=',8,0
    db 'q','w','e','r','t','y','u','i','o','p','[',']',10,0,'a','s'
    db 'd','f','g','h','j','k','l',';',0x27,0x60,0,0x5C,'z','x','c','v'
    db 'b','n','m',',','.','/',0,'*',0,' ',0,0,0,0,0,0
    times 64 db 0
