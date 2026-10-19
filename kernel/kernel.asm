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

    ; Install exception and hardware IRQ gates before enabling interrupts.
    call init_idt64
    call pic_init64
    call pit_init64
    call pmm_init64
%ifdef NOVA_TEST_EXCEPTION
    int3                         ; CI-only fault injection validates the IDT.
%endif
    call screen_clear64
    sti
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

; Consume a scancode queued by IRQ1, then translate set-1 to ASCII.
; Returns ASCII in AL or zero when the queue is empty/non-printable.
poll_keyboard64:
    push rdx
    push r8
    mov al, [key_queue_tail]
    cmp al, [key_queue_head]
    je .none
    movzx edx, al
    mov al, [key_queue + rdx]
    inc byte [key_queue_tail]
    and byte [key_queue_tail], 63
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
    pop r8
    pop rdx
    ret
.shift_down:
    mov byte [shift_pressed], 1
    xor eax, eax
    pop r8
    pop rdx
    ret
.caps_toggle:
    xor byte [caps_lock], 1
    xor eax, eax
    pop r8
    pop rdx
    ret
.shift_up:
    mov byte [shift_pressed], 0
.none:
    xor eax, eax
    pop r8
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
    mov rsi, line_buffer
    mov rdi, command_alloc
    call strings_equal64
    test al, al
    jnz .alloc
    mov rsi, line_buffer
    mov rdi, command_free
    call strings_equal64
    test al, al
    jnz .free
    mov rsi, line_buffer
    mov rdi, command_heap
    call strings_equal64
    test al, al
    jnz .heap
    mov rsi, line_buffer
    mov rdi, command_halloc
    call strings_equal64
    test al, al
    jnz .halloc
    mov rsi, line_buffer
    mov rdi, command_hfree
    call strings_equal64
    test al, al
    jnz .hfree
    mov rsi, line_buffer
    mov rdi, command_uptime
    call strings_equal64
    test al, al
    jnz .uptime
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
    mov rsi, message_free_pages
    call print_string64
    mov eax, [free_page_count]
    call print_hex32
    mov al, 10
    call put_char64
    jmp .done
.alloc:
    cmp qword [test_alloc_page], 0
    jne .alloc_already
    call pmm_alloc_page64
    test rax, rax
    jz .alloc_failed
    mov [test_alloc_page], rax
    mov rsi, message_allocated
    call print_string64
    mov eax, [test_alloc_page]
    call print_hex32
    mov al, 10
    call put_char64
    jmp .done
.alloc_already:
    mov rsi, message_alloc_already
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.alloc_failed:
    mov rsi, message_alloc_failed
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.free:
    mov rdi, [test_alloc_page]
    test rdi, rdi
    jz .free_none
    call pmm_free_page64
    test eax, eax
    jz .free_failed
    mov qword [test_alloc_page], 0
    mov rsi, message_freed
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.free_none:
    mov rsi, message_free_none
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.free_failed:
    mov rsi, message_free_failed
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
 .heap:
    mov rsi, message_heap_status
    call print_string64
    mov eax, [rel heap_pages]
    call print_hex32
    mov al, 10
    call put_char64
    jmp .done
.halloc:
    cmp qword [rel test_heap_ptr], 0
    jne .halloc_already
    mov edi, 128
    call kmalloc64
    test rax, rax
    jz .halloc_failed
    mov [rel test_heap_ptr], rax
    mov rsi, message_heap_allocated
    call print_string64
    mov eax, [rel test_heap_ptr]
    call print_hex32
    mov al, 10
    call put_char64
    jmp .done
.halloc_already:
    mov rsi, message_heap_already
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.halloc_failed:
    mov rsi, message_heap_failed
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.hfree:
    mov rdi, [rel test_heap_ptr]
    test rdi, rdi
    jz .hfree_none
    call kfree64
    test eax, eax
    jz .hfree_failed
    mov qword [rel test_heap_ptr], 0
    mov rsi, message_heap_freed
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.hfree_none:
    mov rsi, message_heap_none
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.hfree_failed:
    mov rsi, message_heap_free_failed
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.uptime:
    mov rsi, message_uptime
    call print_string64
    mov eax, [timer_ticks]
    call print_hex32
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

; Print EAX as eight hexadecimal digits.
print_hex32:
    push rbx
    push rcx
    mov ebx, eax
    mov ecx, 8
.hex_digit32:
    mov eax, ebx
    shr eax, 28
    and eax, 0x0F
    mov al, [hex_digits64 + rax]
    call put_char64
    shl ebx, 4
    loop .hex_digit32
    pop rcx
    pop rbx
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



; Physical memory manager: bitmap tracks the first 1 GiB in 4 KiB pages.
; Bitmap bit 1 = reserved/allocated; bit 0 = available. Keep low 1 MiB
; reserved for firmware data, the loaded kernel, stack, and page tables.
%define PMM_BITMAP       0x60000
%define PMM_BITMAP_SIZE  32768
%define PMM_PAGE_COUNT   262144
%define PMM_FIRST_PAGE   256
%define PMM_LIMIT        0x40000000

pmm_init64:
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov edi, PMM_BITMAP
    mov ecx, PMM_BITMAP_SIZE
    mov al, 0xFF
    rep stosb
    mov edi, PMM_BITMAP
    mov dword [rel free_page_count], 0
    movzx ebp, word [rel e820_count]
    mov esi, 0x5000
.entry:
    test ebp, ebp
    jz .done
    cmp dword [rsi + 16], 1
    jne .next
    ; This simple allocator manages only addresses below 1 GiB.
    cmp dword [rsi + 4], 0
    jne .next
    mov eax, [rsi]
    cmp eax, PMM_LIMIT
    jae .next
    cmp dword [rsi + 12], 0
    jne .cap_end
    mov edx, [rsi + 8]
    add rdx, rax
    jc .cap_end
    cmp rdx, PMM_LIMIT
    ja .cap_end
    jmp .have_end
.cap_end:
    mov edx, PMM_LIMIT
.have_end:
    add eax, 0xFFF
    shr eax, 12                 ; ceil(base / page_size)
    cmp eax, PMM_FIRST_PAGE
    jae .start_ready
    mov eax, PMM_FIRST_PAGE
.start_ready:
    shr rdx, 12                 ; floor(end / page_size)
    mov r8d, eax                ; current page
    mov r9d, edx                ; exclusive end page
.mark_page:
    cmp r8d, r9d
    jae .next
    mov r10d, r8d
    shr r10d, 3
    mov ecx, r8d
    and ecx, 7
    mov r11d, 1
    shl r11d, cl
    mov al, [rdi + r10]
    test al, r11b
    jz .already_free
    not r11b
    and al, r11b
    mov [rdi + r10], al
    inc dword [rel free_page_count]
.already_free:
    inc r8d
    jmp .mark_page
.next:
    add rsi, 24
    dec ebp
    jmp .entry
.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    ret

; Allocate one 4 KiB physical page. Returns its address in RAX, or zero.
pmm_alloc_page64:
    push rbx
    push r8
    push r9
    push r10
    push r11
    mov r8d, PMM_BITMAP
    mov r9d, PMM_FIRST_PAGE
.scan:
    cmp r9d, PMM_PAGE_COUNT
    jae .no_page
    mov r10d, r9d
    shr r10d, 3
    mov ecx, r9d
    and ecx, 7
    mov r11d, 1
    shl r11d, cl
    mov al, [r8 + r10]
    test al, r11b
    jz .allocate
    inc r9d
    jmp .scan
.allocate:
    or al, r11b
    mov [r8 + r10], al
    dec dword [rel free_page_count]
    mov eax, r9d
    shl rax, 12
    jmp .return
.no_page:
    xor eax, eax
.return:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbx
    ret

; Free an aligned page address in RDI. Returns EAX=1 on success, else zero.
pmm_free_page64:
    push rbx
    push r8
    push r9
    push r10
    push r11
    xor eax, eax
    test rdi, 0xFFF
    jnz .return
    cmp rdi, 0x100000
    jb .return
    cmp rdi, PMM_LIMIT
    jae .return
    mov r8d, PMM_BITMAP
    mov r9d, edi
    shr r9d, 12
    mov r10d, r9d
    shr r10d, 3
    mov ecx, r9d
    and ecx, 7
    mov r11d, 1
    shl r11d, cl
    mov al, [r8 + r10]
    test al, r11b
    jz .return
    not r11b
    and al, r11b
    mov [r8 + r10], al
    inc dword [rel free_page_count]
    mov eax, 1
.return:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbx
    ret


; Simple page-backed kernel heap. Each block has a 16-byte header:
; [payload size with bit 63 = allocated][next block pointer]. Blocks are
; kept in a singly linked list; free validates pointers and first-fit reuses
; freed blocks. Requests are rounded to 16-byte alignment.
%define HEAP_USED_BIT 0x8000000000000000
%define HEAP_SIZE_MASK 0x7FFFFFFFFFFFFFFF

kmalloc64:
    ; RDI = requested bytes, RAX = pointer or zero.
    push rbx
    push r12
    push r13
    push r14
    test rdi, rdi
    jz .fail
    cmp rdi, 0x7FFFFFFF
    ja .fail
    add rdi, 15
    and rdi, -16
    mov r12, rdi
    mov r13, [rel heap_head]
    xor r14d, r14d
.find:
    test r13, r13
    jz .need_page
    mov rax, [r13]
    bt rax, 63
    jc .next
    btr rax, 63
    cmp rax, r12
    jae .found
.next:
    mov r14, r13
    mov r13, [r13 + 8]
    jmp .find
.need_page:
    call pmm_alloc_page64
    test rax, rax
    jz .fail
    mov qword [rax], 4080
    mov qword [rax + 8], 0
    inc dword [rel heap_pages]
    test r14, r14
    jnz .append
    mov [rel heap_head], rax
    mov r13, rax
    jmp .find
.append:
    mov [r14 + 8], rax
    mov r13, rax
    jmp .find
.found:
    ; Split if the remainder can hold a header and a minimum payload.
    mov rdx, rax
    sub rdx, r12
    cmp rdx, 32
    jb .mark_used
    lea rbx, [r13 + 16]
    add rbx, r12
    mov rcx, [r13 + 8]
    mov [rbx + 8], rcx
    sub rdx, 16
    mov [rbx], rdx
    mov [r13 + 8], rbx
    mov rax, r12
.mark_used:
    or rax, HEAP_USED_BIT
    mov [r13], rax
    lea rax, [r13 + 16]
    jmp .done
.fail:
    xor eax, eax
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

kfree64:
    ; RDI = payload pointer; EAX=1 on success, 0 on invalid/double free.
    push rbx
    push r12
    push r13
    mov r12, rdi
    xor eax, eax
    test r12, 15
    jnz .return
    cmp r12, 0x100000
    jb .return
    mov r13, [rel heap_head]
.find:
    test r13, r13
    jz .return
    lea rbx, [r13 + 16]
    cmp rbx, r12
    je .found
    mov r13, [r13 + 8]
    jmp .find
.found:
    mov rbx, [r13]
    bt rbx, 63
    jnc .return
    btr rbx, 63
    mov [r13], rbx
    ; Coalesce adjacent free blocks in list order.
    mov r13, [rel heap_head]
.coalesce:
    test r13, r13
    jz .success
    mov rax, [r13]
    bt rax, 63
    jc .coalesce_next
    mov rbx, [r13 + 8]
    test rbx, rbx
    jz .coalesce_next
    mov rcx, [rbx]
    bt rcx, 63
    jc .coalesce_next
    lea rdx, [r13 + 16]
    add rdx, rax
    cmp rdx, rbx
    jne .coalesce_next
    btr rcx, 63
    add rax, 16
    add rax, rcx
    mov [r13], rax
    mov rcx, [rbx + 8]
    mov [r13 + 8], rcx
    jmp .coalesce
.coalesce_next:
    mov r13, [r13 + 8]
    jmp .coalesce
.success:
    mov eax, 1
.return:
    pop r13
    pop r12
    pop rbx
    ret

; Build 32 exception gates and IRQ0/IRQ1 gates at runtime.
init_idt64:
    lea rdi, [rel idt64]
    lea rsi, [rel isr_table64]
    mov ecx, 34
.next_gate:
    mov rax, [rsi]
    mov [rdi], ax                 ; offset bits 0..15
    mov word [rdi + 2], CODE64_SEL
    mov byte [rdi + 4], 0          ; IST = current stack
    mov byte [rdi + 5], 0x8E       ; present, ring 0, interrupt gate
    shr rax, 16
    mov [rdi + 6], ax             ; offset bits 16..31
    shr rax, 16
    mov [rdi + 8], eax            ; offset bits 32..63
    mov dword [rdi + 12], 0
    add rsi, 8
    add rdi, 16
    loop .next_gate
    lidt [rel idtr64]
    ret

; Remap 8259 PIC vectors to 0x20..0x2F, then unmask only timer and keyboard.
pic_init64:
    mov al, 0x11
    out 0x20, al
    out 0xA0, al
    mov al, 0x20
    out 0x21, al
    mov al, 0x28
    out 0xA1, al
    mov al, 0x04
    out 0x21, al
    mov al, 0x02
    out 0xA1, al
    mov al, 0x01
    out 0x21, al
    out 0xA1, al
    mov al, 0xFC                 ; IRQ0 timer + IRQ1 keyboard enabled
    out 0x21, al
    mov al, 0xFF                 ; mask all slave IRQs
    out 0xA1, al
    ret

; Program PIT channel 0 to approximately 100 Hz (11932 Hz divisor).
pit_init64:
    mov al, 0x36
    out 0x43, al
    mov ax, 11932
    out 0x40, al
    mov al, ah
    out 0x40, al
    ret

; IRQ0 increments a 32-bit tick counter; IRQ1 queues the keyboard scancode.
; Preserve every general register that the interrupted kernel may be using.
irq0_handler64:
    push rax
    inc dword [rel timer_ticks]
    mov al, 0x20
    out 0x20, al
    pop rax
    iretq

irq1_handler64:
    push rax
    push rbx
    push rdx
    mov dx, 0x60
    in al, dx
    mov bl, [rel key_queue_head]
    mov ah, bl
    inc ah
    and ah, 63
    cmp ah, [rel key_queue_tail]
    je .queue_full
    movzx ebx, bl
    lea rdx, [rel key_queue]
    mov [rdx + rbx], al
    mov [rel key_queue_head], ah
.queue_full:
    mov al, 0x20
    out 0x20, al
    pop rdx
    pop rbx
    pop rax
    iretq

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

align 8
isr_table64:
    dq isr0, isr1, isr2, isr3, isr4, isr5, isr6, isr7
    dq isr8, isr9, isr10, isr11, isr12, isr13, isr14, isr15
    dq isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
    dq isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31
    dq irq0_handler64, irq1_handler64

align 16
idt64:
    times 34 * 16 db 0
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
command_alloc db 'alloc', 0
command_free db 'free', 0
command_heap db 'heap', 0
command_halloc db 'halloc', 0
command_hfree db 'hfree', 0
command_uptime db 'uptime', 0
message_help db 'Commands: help, about, clear, memory, alloc, free, heap, halloc, hfree, uptime, reboot', 0
message_about db 'NOVA OS is an experimental x86-64 operating system built from scratch.', 0
message_unknown db 'Unknown command. Type help.', 0
message_memory db 'Firmware E820 entries: 0x', 0
message_free_pages db 'Free 4KiB pages: 0x', 0
message_allocated db 'Allocated physical page: 0x', 0
message_alloc_already db 'A test page is already allocated; use free first.', 0
message_alloc_failed db 'No free physical page is available.', 0
message_freed db 'Freed test page.', 0
message_free_none db 'No test page is currently allocated.', 0
message_free_failed db 'Could not free the test page.', 0
message_heap_status db 'Heap pages allocated: 0x', 0
message_heap_allocated db 'Heap allocation at: 0x', 0
message_heap_already db 'A heap test allocation already exists; use hfree first.', 0
message_heap_failed db 'Kernel heap allocation failed.', 0
message_heap_freed db 'Heap test allocation freed.', 0
message_heap_none db 'No heap test allocation is active.', 0
message_heap_free_failed db 'Heap free rejected the pointer.', 0
message_uptime db 'PIT timer ticks: 0x', 0
message_reboot db 'Rebooting NOVA OS...', 0
message_reboot_failed db 'Reboot controller timed out; system halted safely.', 0
line_length dd 0
screen_cursor dd 0
shift_pressed db 0
caps_lock db 0
key_queue_head db 0
key_queue_tail db 0
key_queue times 64 db 0
align 4
timer_ticks dd 0
free_page_count dd 0
test_alloc_page dq 0
heap_head dq 0
heap_pages dd 0
test_heap_ptr dq 0
line_buffer times 128 db 0
scan_ascii:
    db 0,0,'1','2','3','4','5','6','7','8','9','0','-','=',8,0
    db 'q','w','e','r','t','y','u','i','o','p','[',']',10,0,'a','s'
    db 'd','f','g','h','j','k','l',';',0x27,0x60,0,0x5C,'z','x','c','v'
    db 'b','n','m',',','.','/',0,'*',0,' ',0,0,0,0,0,0
    times 64 db 0
scan_shifted:
    db 0,0,'!','@','#','$','%','^','&','*','(',')','_','+',8,0
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}',10,0,'A','S'
    db 'D','F','G','H','J','K','L',':',0x22,'~',0,'|','Z','X','C','V'
    db 'B','N','M','<','>','?',0,'*',0,' ',0,0,0,0,0,0
    times 64 db 0
