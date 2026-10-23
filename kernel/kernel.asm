BITS 16
ORG 0x1000

; Temporary physical layout for this BIOS prototype. Keep the stack separate
; from the page-table pages until E820 discovery and a real allocator exist.
STACK_TOP equ 0x8F000
PML4_ADDR equ 0x90000
PDPT_ADDR equ 0x91000
PD_ADDR   equ 0x92000
VGA_TEXT_ADDR equ 0xB8000
TASK1_STACK_TOP equ 0x88000
TASK2_STACK_TOP equ 0x8C000
TASK3_STACK_TOP equ 0x8A000
TSS_STACK_TOP equ 0x8E000
USER_CODE_VIRT equ 0x400000
USER_STACK_VIRT equ 0x600000
USER_STACK_TOP equ 0x600FF0
USER_CODE_SEL equ 0x2B
USER_DATA_SEL equ 0x33
FS_SUPER_LBA equ 0
FS_DATA_LBA equ 1
FS_ELF_LBA equ 2
FS_MAX_FILE_SIZE equ 500

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
; Each entry is 24 bytes. The physical allocator consumes this map in long mode.
collect_e820:
    pushad
    push es
    mov ax, 0x5000
    mov es, ax
    mov word [e820_count], 0
    mov dword [e820_continuation], 0
.next_entry:
    cmp word [e820_count], 32
    jae .done
    mov ax, [e820_count]
    mov dx, 24
    mul dx
    mov di, ax
    mov ax, 0x5000
    mov es, ax
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
gdt_user_code64:
    dq 0x00AFFA000000FFFF
gdt_user_data64:
    dq 0x00CFF2000000FFFF
gdt_tss:
    dq 0
    dq 0
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
    call tss_init64
    call init_idt64
    call pic_init64
    call pit_init64
    call pmm_init64
    call scheduler_init64
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
    mov rdi, command_mem
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
    mov rdi, command_pmmtest
    call strings_equal64
    test al, al
    jnz .pmmtest
    mov rsi, line_buffer
    mov rdi, command_schedtest
    call strings_equal64
    test al, al
    jnz .schedtest
    mov rsi, line_buffer
    mov rdi, command_ps
    call strings_equal64
    test al, al
    jnz .ps
    mov rsi, line_buffer
    mov rdi, command_install
    call strings_equal64
    test al, al
    jnz .fs_install
    mov rsi, line_buffer
    mov rdi, command_exec
    call strings_equal64
    test al, al
    jnz .fs_exec
    mov rsi, line_buffer
    mov rdi, command_ls
    call strings_equal64
    test al, al
    jnz .fs_ls
    mov rsi, line_buffer
    mov rdi, command_cat
    call strings_equal64
    test al, al
    jnz .fs_cat
    mov rsi, line_buffer
    mov rdi, command_usertest
    call strings_equal64
    test al, al
    jnz .usertest
    mov rsi, line_buffer
    mov rdi, command_userfaulttest
    call strings_equal64
    test al, al
    jnz .userfaulttest
    mov rsi, line_buffer
    mov rdi, command_write_prefix
    call string_starts_with64
    test al, al
    jnz .fs_write
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
 .pmmtest:
    ; Reject the first address outside the managed physical-memory range.
    push r12
    mov r12d, [rel free_page_count]
    mov rdi, 0x40000000
    call pmm_free_page64
    test eax, eax
    jnz .pmmtest_failed
    cmp r12d, [rel free_page_count]
    jne .pmmtest_failed
    ; Allocate/free one valid frame, then ensure a second free is rejected.
    call pmm_alloc_page64
    test rax, rax
    jz .pmmtest_failed
    mov rdi, rax
    mov r12, rax
    call pmm_free_page64
    test eax, eax
    jz .pmmtest_failed
    mov rdi, r12
    call pmm_free_page64
    test eax, eax
    jnz .pmmtest_failed
    pop r12
    mov rsi, message_pmmtest_pass
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.pmmtest_failed:
    pop r12
    mov rsi, message_pmmtest_fail
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
.ps:
    mov rsi, message_ps_foreground
    call print_string64
    mov al, 10
    call put_char64
    mov rsi, message_ps_worker_a
    call print_string64
    mov eax, [rel scheduler_counter_a]
    call print_hex32
    mov al, 10
    call put_char64
    mov rsi, message_ps_worker_b
    call print_string64
    mov eax, [rel scheduler_counter_b]
    call print_hex32
    mov al, 10
    call put_char64
    mov rsi, message_ps_user
    call print_string64
    movzx eax, byte [rel user_process_state]
    call print_hex32
    mov al, 10
    call put_char64
    jmp .done
.schedtest:
    cmp qword [rel scheduler_counter_a], 0
    je .schedtest_failed
    cmp qword [rel scheduler_counter_b], 0
    je .schedtest_failed
    mov rsi, message_schedtest_pass
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.schedtest_failed:
    mov rsi, message_schedtest_fail
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.fs_install:
    call fs_install64
    jmp .done
.fs_exec:
    call fs_exec64
    jmp .done
.fs_ls:
    call fs_list64
    jmp .done
.fs_cat:
    call fs_cat64
    jmp .done
.fs_write:
    call fs_write64
    jmp .done
.usertest:
    xor edi, edi
    call user_test_run64
    jmp .done
.userfaulttest:
    mov edi, 1
    call user_test_run64
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



; Install a small statically-linked ELF64 test executable into the single
; NOVA filesystem slot. Unknown nonblank media is rejected rather than erased.
fs_install64:
    push rbx
    push r12
    push r13
    mov eax, FS_SUPER_LBA
    lea rdi, [rel fs_sector_buffer]
    call ata_read_sector64
    test eax, eax
    jz .disk_error
    call fs_read_header64
    test eax, eax
    jnz .header_valid
    ; A blank disk is initialized; unknown nonblank media is never erased.
    lea rsi, [rel fs_sector_buffer]
    mov ecx, 512
.blank_check:
    cmp byte [rsi], 0
    jne .invalid
    inc rsi
    loop .blank_check
    lea rdi, [rel fs_sector_buffer]
    xor eax, eax
    mov ecx, 64
    rep stosq
    lea rsi, [rel fs_magic]
    lea rdi, [rel fs_sector_buffer]
    mov ecx, 7
    rep movsb
.header_valid:
    mov r12d, user_elf_end - user_elf_start
    mov [rel fs_sector_buffer + 28], r12d
    lea rsi, [rel fs_elf_filename]
    lea rdi, [rel fs_sector_buffer + 20]
    mov ecx, 8
    rep movsb
    mov eax, FS_SUPER_LBA
    lea rsi, [rel fs_sector_buffer]
    call ata_write_sector64
    test eax, eax
    jz .disk_error
    lea rdi, [rel fs_sector_buffer]
    xor eax, eax
    mov ecx, 64
    rep stosq
    lea rsi, [rel user_elf_start]
    lea rdi, [rel fs_sector_buffer]
    mov ecx, r12d
    rep movsb
    mov eax, FS_ELF_LBA
    lea rsi, [rel fs_sector_buffer]
    call ata_write_sector64
    test eax, eax
    jz .disk_error
    mov rsi, message_fs_installed
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.invalid:
    mov rsi, message_fs_invalid
    call print_string64
    mov al, 10
    call put_char64
    jmp .done
.disk_error:
    mov rsi, message_fs_no_disk
    call print_string64
    mov al, 10
    call put_char64
.done:
    pop r13
    pop r12
    pop rbx
    ret

; Load a bounded, single-PT_LOAD ELF64 executable from the data sector.
; Only fixed virtual address 0x400000 is supported in this first loader.
fs_exec64:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp byte [rel user_process_state], 1
    je .already_running
    call fs_read_header64
    test eax, eax
    jz .failed
    mov r12d, [rel fs_sector_buffer + 28]
    cmp r12d, 120
    jb .invalid
    mov eax, FS_ELF_LBA
    lea rdi, [rel fs_sector_buffer]
    call ata_read_sector64
    test eax, eax
    jz .failed
    cmp dword [rel fs_sector_buffer], 0x464C457F
    jne .invalid
    cmp word [rel fs_sector_buffer + 4], 0x0102
    jne .invalid
    cmp word [rel fs_sector_buffer + 18], 0x003E
    jne .invalid
    cmp qword [rel fs_sector_buffer + 32], 64
    jne .invalid
    cmp word [rel fs_sector_buffer + 52], 64
    jne .invalid
    cmp word [rel fs_sector_buffer + 54], 56
    jne .invalid
    cmp word [rel fs_sector_buffer + 56], 1
    jne .invalid
    cmp dword [rel fs_sector_buffer + 64], 1
    jne .invalid
    cmp dword [rel fs_sector_buffer + 68], 5
    jne .invalid
    cmp qword [rel fs_sector_buffer + 72], 0
    jne .invalid
    cmp qword [rel fs_sector_buffer + 80], USER_CODE_VIRT
    jne .invalid
    mov r13, [rel fs_sector_buffer + 24]
    cmp r13, USER_CODE_VIRT + 120
    jb .invalid
    cmp r13, USER_CODE_VIRT + 4096
    jae .invalid
    mov r14, [rel fs_sector_buffer + 96]
    cmp r14, r12
    ja .invalid
    cmp r14, 4096
    ja .invalid
    mov r15, [rel fs_sector_buffer + 104]
    cmp r15, r14
    jb .invalid
    cmp r15, 4096
    ja .invalid
    call user_vm_init64
    test eax, eax
    jz .failed
    mov rdi, [rel user_code_page]
    call vm_zero_page64
    lea rsi, [rel fs_sector_buffer]
    mov rdi, [rel user_code_page]
    mov rcx, r14
    rep movsb
    mov [rel user_process_entry], r13
    mov qword [rel task_rsp + 24], 0
    mov byte [rel task_started + 3], 0
    mov byte [rel user_process_state], 1
    mov rsi, message_fs_exec_started
    call print_string64
    mov al, 10
    call put_char64
    jmp .return
.already_running:
    mov rsi, message_fs_exec_running
    call print_string64
    mov al, 10
    call put_char64
    jmp .return
.invalid:
    mov rsi, message_fs_elf_invalid
    call print_string64
    mov al, 10
    call put_char64
    jmp .return
.failed:
    mov rsi, message_fs_exec_failed
    call print_string64
    mov al, 10
    call put_char64
.return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ATA primary-master PIO sector access (LBA28), for a separate writable IDE disk.
; EAX=LBA, RDI=buffer for read; EAX=LBA, RSI=buffer for write. EAX=1 success.
ata_wait_drq64:
    push rdx
    push rcx
    mov dx, 0x1F7
    mov ecx, 0x100000
.wait:
    in al, dx
    test al, 0x80
    jnz .again
    test al, 0x21
    jnz .fail
    test al, 0x08
    jnz .ok
.again:
    loop .wait
.fail:
    xor eax, eax
    pop rcx
    pop rdx
    ret
.ok:
    mov eax, 1
    pop rcx
    pop rdx
    ret

ata_wait_complete64:
    push rdx
    push rcx
    mov dx, 0x1F7
    mov ecx, 0x100000
.wait:
    in al, dx
    test al, 0x80
    jnz .again
    test al, 0x21
    jnz .fail
    mov eax, 1
    pop rcx
    pop rdx
    ret
.again:
    loop .wait
.fail:
    xor eax, eax
    pop rcx
    pop rdx
    ret

ata_read_sector64:
    push rbx
    push r12
    push r13
    mov r12d, eax
    mov r13, rdi
    mov dx, 0x1F6
    mov eax, r12d
    shr eax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov eax, r12d
    mov dx, 0x1F3
    out dx, al
    shr eax, 8
    mov dx, 0x1F4
    out dx, al
    shr eax, 8
    mov dx, 0x1F5
    out dx, al
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al
    call ata_wait_drq64
    test eax, eax
    jz .fail
    mov dx, 0x1F0
    mov rdi, r13
    mov ecx, 256
    rep insw
    mov eax, 1
    jmp .done
.fail:
    xor eax, eax
.done:
    pop r13
    pop r12
    pop rbx
    ret

ata_write_sector64:
    push rbx
    push r12
    push r13
    mov r12d, eax
    mov r13, rsi
    mov dx, 0x1F6
    mov eax, r12d
    shr eax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov eax, r12d
    mov dx, 0x1F3
    out dx, al
    shr eax, 8
    mov dx, 0x1F4
    out dx, al
    shr eax, 8
    mov dx, 0x1F5
    out dx, al
    mov dx, 0x1F7
    mov al, 0x30
    out dx, al
    call ata_wait_drq64
    test eax, eax
    jz .fail
    mov dx, 0x1F0
    mov rsi, r13
    mov ecx, 256
    rep outsw
    mov dx, 0x1F7
    mov al, 0xE7
    out dx, al
    call ata_wait_complete64
    jmp .done
.fail:
    xor eax, eax
.done:
    pop r13
    pop r12
    pop rbx
    ret

string_starts_with64:
    push rsi
    push rdi
.compare:
    mov al, [rdi]
    test al, al
    jz .yes
    cmp al, [rsi]
    jne .no
    inc rsi
    inc rdi
    jmp .compare
.yes:
    mov al, 1
    pop rdi
    pop rsi
    ret
.no:
    xor al, al
    pop rdi
    pop rsi
    ret

; Minimal one-file filesystem on a dedicated disk: LBA0 metadata, LBA1 data.
; Metadata signature "NOVAFS1", byte length at +8, filename at +12.
fs_read_header64:
    mov eax, FS_SUPER_LBA
    lea rdi, [rel fs_sector_buffer]
    call ata_read_sector64
    test eax, eax
    jz .fail
    mov rsi, fs_sector_buffer
    mov rdi, fs_magic
    mov ecx, 7
.compare:
    mov al, [rsi]
    cmp al, [rdi]
    jne .fail
    inc rsi
    inc rdi
    loop .compare
    mov eax, [rel fs_sector_buffer + 8]
    cmp eax, FS_MAX_FILE_SIZE
    ja .fail
    mov eax, [rel fs_sector_buffer + 28]
    cmp eax, FS_MAX_FILE_SIZE
    ja .fail
    mov eax, 1
    ret
.fail:
    xor eax, eax
    ret

fs_list64:
    call fs_read_header64
    test eax, eax
    jz .invalid
    cmp dword [rel fs_sector_buffer + 8], 0
    je .slot1
    lea rsi, [rel fs_sector_buffer + 12]
    mov ecx, 8
.name0:
    mov al, [rsi]
    call put_char64
    inc rsi
    loop .name0
    mov rsi, message_fs_list
    call print_string64
    mov eax, [rel fs_sector_buffer + 8]
    call print_hex32
    mov al, 10
    call put_char64
.slot1:
    cmp dword [rel fs_sector_buffer + 28], 0
    je .done
    lea rsi, [rel fs_sector_buffer + 20]
    mov ecx, 8
.name1:
    mov al, [rsi]
    call put_char64
    inc rsi
    loop .name1
    mov rsi, message_fs_list
    call print_string64
    mov eax, [rel fs_sector_buffer + 28]
    call print_hex32
    mov al, 10
    call put_char64
.done:
    ret
.invalid:
    mov rsi, message_fs_invalid
    call print_string64
    mov al, 10
    call put_char64
    ret

fs_cat64:
    call fs_read_header64
    test eax, eax
    jz .invalid
    mov ecx, [rel fs_sector_buffer + 8]
    test ecx, ecx
    jz .empty
    push rcx
    mov eax, FS_DATA_LBA
    lea rdi, [rel fs_sector_buffer]
    call ata_read_sector64
    test eax, eax
    jz .disk_error
    pop rcx
    mov rsi, message_fs_read
    call print_string64
    lea rsi, [rel fs_sector_buffer]
.print:
    test ecx, ecx
    jz .done
    mov al, [rsi]
    call put_char64
    inc rsi
    dec ecx
    jmp .print
.done:
    mov al, 10
    call put_char64
    ret
.empty:
    mov rsi, message_fs_empty
    call print_string64
    mov al, 10
    call put_char64
    ret
.disk_error:
    pop rcx
.invalid:
    mov rsi, message_fs_invalid
    call print_string64
    mov al, 10
    call put_char64
    ret

fs_write64:
    ; Require at least one byte after "write " and keep a sector-sized bound.
    mov ecx, [rel line_length]
    cmp ecx, 6
    jbe .usage
    sub ecx, 6
    cmp ecx, FS_MAX_FILE_SIZE
    ja .usage
    mov [rel fs_file_size], ecx
    ; If LBA0 is all zero, initialize it; never overwrite unknown media.
    mov eax, FS_SUPER_LBA
    lea rdi, [rel fs_sector_buffer]
    call ata_read_sector64
    test eax, eax
    jz .disk_error
    mov rsi, fs_sector_buffer
    mov ecx, 512
.check_blank:
    cmp byte [rsi], 0
    jne .check_magic
    inc rsi
    loop .check_blank
    jmp .initialize_header
.check_magic:
    mov rsi, fs_sector_buffer
    mov rdi, fs_magic
    mov ecx, 7
.check_signature:
    mov al, [rsi]
    cmp al, [rdi]
    jne .invalid
    inc rsi
    inc rdi
    loop .check_signature
    jmp .update_header
.initialize_header:
    lea rdi, [rel fs_sector_buffer]
    xor eax, eax
    mov ecx, 64
    rep stosq
    lea rsi, [rel fs_magic]
    lea rdi, [rel fs_sector_buffer]
    mov ecx, 7
    rep movsb
.update_header:
    mov eax, [rel fs_file_size]
    mov [rel fs_sector_buffer + 8], eax
    lea rsi, [rel fs_filename]
    lea rdi, [rel fs_sector_buffer + 12]
    mov ecx, 8
    rep movsb
    mov eax, FS_SUPER_LBA
    lea rsi, [rel fs_sector_buffer]
    call ata_write_sector64
    test eax, eax
    jz .disk_error
    ; Zero the sector, then copy the command payload without its prefix.
    lea rdi, [rel fs_sector_buffer]
    xor eax, eax
    mov ecx, 64
    rep stosq
    mov ecx, [rel fs_file_size]
    lea rsi, [rel line_buffer + 6]
    lea rdi, [rel fs_sector_buffer]
    rep movsb
    mov eax, FS_DATA_LBA
    lea rsi, [rel fs_sector_buffer]
    call ata_write_sector64
    test eax, eax
    jz .disk_error
    mov rsi, message_fs_written
    call print_string64
    mov al, 10
    call put_char64
    ret
.usage:
    mov rsi, message_fs_write_usage
    call print_string64
    mov al, 10
    call put_char64
    ret
.invalid:
    mov rsi, message_fs_invalid
    call print_string64
    mov al, 10
    call put_char64
    ret
.disk_error:
    mov rsi, message_fs_no_disk
    call print_string64
    mov al, 10
    call put_char64
    ret

; Physical memory manager: bitmap tracks the first 1 GiB in 4 KiB pages.
; Bitmap bit 1 = reserved/allocated; bit 0 = available. Keep low 1 MiB
; reserved for firmware data, the loaded kernel, stack, and page tables.
%define PMM_BITMAP       0x60000
%define PMM_USABLE_BITMAP 0x68000
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
    ; Allocation bitmap starts fully reserved; usable bitmap starts empty.
    ; The second bitmap prevents free() from releasing firmware-reserved pages.
    mov edi, PMM_BITMAP
    mov ecx, PMM_BITMAP_SIZE
    mov al, 0xFF
    rep stosb
    mov edi, PMM_USABLE_BITMAP
    xor eax, eax
    mov ecx, PMM_BITMAP_SIZE
    rep stosb
    mov edi, PMM_BITMAP
    mov dword [rel free_page_count], 0
    movzx ebp, word [rel e820_count]
    mov esi, 0x50000
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
    ; Mark this frame as eligible for allocation/free, separately from
    ; the allocation state. A reserved frame must never become freeable.
    mov rax, PMM_USABLE_BITMAP
    mov r10d, r8d
    shr r10d, 3
    mov ecx, r8d
    and ecx, 7
    mov r11d, 1
    shl r11d, cl
    or byte [rax + r10], r11b
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
    mov r9d, edi
    shr r9d, 12
    mov r10d, r9d
    shr r10d, 3
    mov ecx, r9d
    and ecx, 7
    mov r11d, 1
    shl r11d, cl
    ; Reject frames absent from the E820 usable-memory set. The allocation
    ; bitmap alone cannot distinguish reserved frames from allocated frames.
    mov r8d, PMM_USABLE_BITMAP
    test byte [r8 + r10], r11b
    jz .return
    mov r8d, PMM_BITMAP
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
    bts rax, 63
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

; Install a 64-bit TSS. Ring-3 interrupts use a dedicated kernel stack.
tss_init64:
    mov qword [rel tss64 + 4], TSS_STACK_TOP
    mov word [rel tss64 + 102], 104
    mov rdx, tss64
    mov rax, rdx
    and eax, 0xFFFF
    shl rax, 16
    mov r8, rdx
    shr r8, 16
    and r8d, 0xFF
    shl r8, 32
    or rax, r8
    mov r8, 0x89
    shl r8, 40
    or rax, r8
    mov r8, rdx
    shr r8, 24
    and r8d, 0xFF
    shl r8, 56
    or rax, r8
    or rax, 103
    mov [rel gdt_tss], rax
    mov rax, rdx
    shr rax, 32
    mov [rel gdt_tss + 8], rax
    mov ax, gdt_tss - gdt_start
    ltr ax
    ret

; Allocate a private page-table hierarchy and two user pages. The kernel
; remains identity-mapped supervisor-only; only the selected code and stack
; PTEs receive the user bit. This first address space is intentionally small.
user_vm_init64:
    cmp qword [rel user_pml4_page], 0
    jne .ready
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    xor r14d, r14d
    call pmm_alloc_page64
    test rax, rax
    jz .fail
    mov [rel user_pml4_page], rax
    call pmm_alloc_page64
    test rax, rax
    jz .fail
    mov [rel user_pdpt_page], rax
    call pmm_alloc_page64
    test rax, rax
    jz .fail
    mov [rel user_pd_page], rax
    call pmm_alloc_page64
    test rax, rax
    jz .fail
    mov [rel user_code_pt_page], rax
    call pmm_alloc_page64
    test rax, rax
    jz .fail
    mov [rel user_stack_pt_page], rax
    call pmm_alloc_page64
    test rax, rax
    jz .fail
    mov [rel user_code_page], rax
    call pmm_alloc_page64
    test rax, rax
    jz .fail
    mov [rel user_stack_page], rax

    mov rdi, [rel user_pml4_page]
    call vm_zero_page64
    mov rdi, [rel user_pdpt_page]
    call vm_zero_page64
    mov rdi, [rel user_pd_page]
    call vm_zero_page64
    mov rdi, [rel user_code_pt_page]
    call vm_zero_page64
    mov rdi, [rel user_stack_pt_page]
    call vm_zero_page64
    mov rdi, [rel user_code_page]
    call vm_zero_page64
    mov rdi, [rel user_stack_page]
    call vm_zero_page64

    ; Copy the kernel's existing identity-map hierarchy.
    mov rsi, PML4_ADDR
    mov rdi, [rel user_pml4_page]
    mov ecx, 512
    rep movsq
    mov rsi, PDPT_ADDR
    mov rdi, [rel user_pdpt_page]
    mov ecx, 512
    rep movsq
    mov rsi, PD_ADDR
    mov rdi, [rel user_pd_page]
    mov ecx, 512
    rep movsq

    mov rax, [rel user_pdpt_page]
    or rax, 7
    mov rdx, [rel user_pml4_page]
    mov [rdx], rax
    mov rax, [rel user_pd_page]
    or rax, 7
    mov rdx, [rel user_pdpt_page]
    mov [rdx], rax

    ; Replace the 2 MiB huge-page entries covering 4-6 MiB and 6-8 MiB
    ; with page tables so user permissions apply only to individual pages.
    mov rax, [rel user_code_pt_page]
    or rax, 7
    mov rdx, [rel user_pd_page]
    mov [rdx + 2*8], rax
    mov rax, [rel user_stack_pt_page]
    or rax, 7
    mov [rdx + 3*8], rax

    mov rdi, [rel user_code_pt_page]
    mov rdx, USER_CODE_VIRT
    xor ecx, ecx
.code_pt_loop:
    mov rax, rdx
    or rax, 3
    mov [rdi + rcx*8], rax
    add rdx, 0x1000
    inc ecx
    cmp ecx, 512
    jb .code_pt_loop
    mov rax, [rel user_code_page]
    or rax, 5                    ; present + user, read-only code page
    mov rdi, [rel user_code_pt_page]
    mov [rdi], rax

    mov rdi, [rel user_stack_pt_page]
    mov rdx, USER_STACK_VIRT
    xor ecx, ecx
.stack_pt_loop:
    mov rax, rdx
    or rax, 3
    mov [rdi + rcx*8], rax
    add rdx, 0x1000
    inc ecx
    cmp ecx, 512
    jb .stack_pt_loop
    mov rax, [rel user_stack_page]
    or rax, 7                    ; present + writable + user stack page
    mov rdi, [rel user_stack_pt_page]
    mov [rdi], rax

    mov r14d, 1
    jmp .done
.fail:
    xor r14d, r14d
.done:
    mov eax, r14d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.ready:
    mov eax, 1
    ret

vm_zero_page64:
    push rcx
    push rdi
    xor eax, eax
    mov ecx, 512
    rep stosq
    pop rdi
    pop rcx
    ret

; EDI selects 0=normal user program, 1=deliberate user-only protection fault.
user_test_run64:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    call user_vm_init64
    test eax, eax
    jz .setup_failed
    mov rdi, [rel user_code_page]
    test r12d, r12d
    jnz .copy_fault_program
    lea rsi, [rel user_program_start]
    mov ecx, user_program_end - user_program_start
    jmp .copy_program
.copy_fault_program:
    lea rsi, [rel user_fault_program_start]
    mov ecx, user_fault_program_end - user_fault_program_start
.copy_program:
    rep movsb
    mov [rel user_return_rsp], rsp
    mov rax, [rel user_pml4_page]
    mov cr3, rax
    push qword USER_DATA_SEL
    push qword USER_STACK_TOP
    push qword 0x202
    push qword USER_CODE_SEL
    push qword USER_CODE_VIRT
    iretq
.setup_failed:
    mov rsi, message_uservm_failed
    call print_string64
    mov al, 10
    call put_char64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; Syscall ABI: RAX=1 writes (RDI=user pointer, RSI=length); RAX=2 exits.
; Invalid syscall arguments terminate the process instead of returning to user.
syscall80_handler64:
    cmp eax, 1
    je .write
    cmp eax, 2
    je .exit
    cmp eax, 4
    je .file_read
    jmp user_bad_syscall_exit64
.write:
    cmp rsi, 1024
    ja user_bad_syscall_exit64
    mov rax, rdi
    add rax, rsi
    jc user_bad_syscall_exit64
    cmp rdi, USER_CODE_VIRT
    jb .write_stack_range
    cmp rdi, USER_CODE_VIRT + 4096
    jae .write_stack_range
    cmp rax, USER_CODE_VIRT + 4096
    ja user_bad_syscall_exit64
    jmp .write_valid
.write_stack_range:
    cmp rdi, USER_STACK_VIRT
    jb user_bad_syscall_exit64
    cmp rdi, USER_STACK_VIRT + 4096
    jae user_bad_syscall_exit64
    cmp rax, USER_STACK_VIRT + 4096
    ja user_bad_syscall_exit64
.write_valid:
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
.write_loop:
    test rsi, rsi
    jz .write_done
    mov al, [rdi]
    call put_char64
    inc rdi
    dec rsi
    jmp .write_loop
.write_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq
; RAX=4 reads NOVA.TXT into a validated writable user-stack buffer.
; RDI=destination, RSI=capacity (<=121); returns bytes copied in EAX.
.file_read:
    cmp rdi, USER_STACK_VIRT
    jb user_bad_syscall_exit64
    cmp rsi, 121
    ja user_bad_syscall_exit64
    mov rax, rdi
    add rax, rsi
    jc user_bad_syscall_exit64
    cmp rax, USER_STACK_VIRT + 4096
    ja user_bad_syscall_exit64
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r13, rdi
    mov r14, rsi
    call fs_read_header64
    test eax, eax
    jz .file_read_empty
    mov r12d, [rel fs_sector_buffer + 8]
    cmp r12, r14
    jbe .file_read_length_ready
    mov r12, r14
.file_read_length_ready:
    test r12, r12
    jz .file_read_empty
    mov eax, FS_DATA_LBA
    lea rdi, [rel fs_sector_buffer]
    call ata_read_sector64
    test eax, eax
    jz .file_read_empty
    mov ecx, r12d
    lea rsi, [rel fs_sector_buffer]
    mov rdi, r13
    rep movsb
    mov eax, r12d
    jmp .file_read_return
.file_read_empty:
    xor eax, eax
.file_read_return:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    iretq

.exit:
    cmp byte [rel current_task_index], 3
    je user_task_exit64
    mov rsi, message_user_exit
    call print_string64
    mov al, 10
    call put_char64
    mov rax, PML4_ADDR
    mov cr3, rax
    mov rsp, [rel user_return_rsp]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    sti                         ; exception/syscall gate cleared IF; restore shell IRQs
    ret

user_bad_syscall_exit64:
    cmp byte [rel current_task_index], 3
    je user_task_bad_syscall_exit64
    mov rsi, message_user_bad_syscall
    call print_string64
    mov al, 10
    call put_char64
    mov rax, PML4_ADDR
    mov cr3, rax
    mov rsp, [rel user_return_rsp]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    sti                         ; exception/syscall gate cleared IF; restore shell IRQs
    ret

user_task_exit64:
    mov rsi, message_user_exit
    jmp user_task_terminate64
user_task_fault_exit64:
    mov rsi, message_user_fault
    jmp user_task_terminate64
user_task_bad_syscall_exit64:
    mov rsi, message_user_bad_syscall
user_task_terminate64:
    call print_string64
    mov al, 10
    call put_char64
    mov byte [rel user_process_state], 0
    mov eax, PML4_ADDR
    mov cr3, rax
    mov byte [rel current_task_index], 0
    mov rsp, [rel task_rsp]
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq

user_fault_exit64:
    mov rsi, message_user_fault
    call print_string64
    mov al, 10
    call put_char64
    mov rax, PML4_ADDR
    mov cr3, rax
    mov rsp, [rel user_return_rsp]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    sti                         ; exception/syscall gate cleared IF; restore shell IRQs
    ret

; Minimal timer-preemptive round-robin scheduler. Task 0 is the existing
; kernel shell context. Tasks 1 and 2 are independent workers that validate
; PIT-driven context switching. Their stacks use reserved, unused low memory.
scheduler_init64:
    mov qword [rel task_rsp], 0
    mov qword [rel task_rsp + 8], 0
    mov qword [rel task_rsp + 16], 0
    mov qword [rel task_rsp + 24], 0
    mov byte [rel task_started], 1
    mov byte [rel task_started + 1], 0
    mov byte [rel task_started + 2], 0
    mov byte [rel task_started + 3], 0
    mov byte [rel user_process_state], 0
    mov byte [rel current_task_index], 0
    ret

scheduler_worker_a64:
.loop:
    inc qword [rel scheduler_counter_a]
    pause
    jmp .loop

scheduler_worker_b64:
.loop:
    inc qword [rel scheduler_counter_b]
    pause
    jmp .loop

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
    ; Vector 0x80 is callable from ring 3 (DPL=3 interrupt gate).
    lea rdi, [rel idt64 + 128*16]
    mov rax, syscall80_handler64
    mov [rdi], ax
    mov word [rdi + 2], CODE64_SEL
    mov byte [rdi + 4], 0
    mov byte [rdi + 5], 0xEE
    shr rax, 16
    mov [rdi + 6], ax
    shr rax, 16
    mov [rdi + 8], eax
    mov dword [rdi + 12], 0
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
; IRQ0 is the preemption point. The hardware frame (RIP, CS, RFLAGS)
; remains directly below the saved general registers.
irq0_handler64:
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    inc dword [rel timer_ticks]
    movzx eax, byte [rel current_task_index]
    lea rdx, [rel task_rsp]
    mov [rdx + rax*8], rsp

    inc al
    cmp al, 4
    jb .next_task_ready
    xor al, al
.next_task_ready:
    cmp al, 3
    jne .task_runnable
    cmp byte [rel user_process_state], 1
    je .task_runnable
    xor al, al
.task_runnable:
    mov [rel current_task_index], al
    movzx r10d, al               ; preserve selected task index across CR3 load
    cmp r10d, 3
    jne .kernel_cr3
    mov rax, [rel user_pml4_page]
    mov cr3, rax
    jmp .cr3_ready
.kernel_cr3:
    mov eax, PML4_ADDR
    mov cr3, rax
.cr3_ready:
    ; A zero saved RSP means this task has never run. Start it on its own stack.
    lea rdx, [rel task_rsp]
    cmp qword [rdx + r10*8], 0
    jne .resume_task
    lea rdx, [rel task_started]
    mov byte [rdx + r10], 1
    mov al, 0x20
    out 0x20, al
    cmp byte [rel current_task_index], 1
    je .start_task_a
    cmp byte [rel current_task_index], 2
    je .start_task_b
    ; First entry to a user process uses a five-qword CPL3 iret frame.
    mov rsp, TASK3_STACK_TOP
    push qword USER_DATA_SEL
    push qword USER_STACK_TOP
    push qword 0x202
    push qword USER_CODE_SEL
    push qword [rel user_process_entry]
    iretq
.start_task_b:
    mov rsp, TASK2_STACK_TOP
    sti
    jmp scheduler_worker_b64
.start_task_a:
    mov rsp, TASK1_STACK_TOP
    sti
    jmp scheduler_worker_a64

.resume_task:
    lea rdx, [rel task_rsp]
    mov rsp, [rdx + r10*8]
    mov al, 0x20
    out 0x20, al
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
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
    ; Ring-3 faults terminate only the current test process. The kernel shell
    ; and worker tasks remain alive; ring-0 faults retain the fatal diagnostic.
    mov rax, [rsp + 24]
    test al, 3
    jz .kernel_fault
    cmp byte [rel current_task_index], 3
    je user_task_fault_exit64
    jmp user_fault_exit64
.kernel_fault:
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
    times 129 * 16 db 0
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
user_program_start:
    mov eax, 1
    mov rdi, USER_CODE_VIRT + (user_program_message - user_program_start)
    mov esi, user_program_message_end - user_program_message
    int 0x80
    mov eax, 2
    int 0x80
    jmp $
user_program_message db 'NOVA ring-3 program: syscall write works', 10
user_program_message_end:
user_program_end:

user_fault_program_start:
    mov rax, 0x500000
    mov byte [rax], 0
    mov eax, 2
    int 0x80
    jmp $
user_fault_program_end:

; A minimal static ELF64 executable: one RX PT_LOAD segment at 0x400000.
; It uses syscall 1 for console output and syscall 2 to exit to the shell.
align 8
user_elf_start:
    db 0x7F, 'E', 'L', 'F', 2, 1, 1, 0
    times 8 db 0
    dw 2
    dw 0x3E
    dd 1
    dq USER_CODE_VIRT + (user_elf_entry - user_elf_start)
    dq 64
    dq 0
    dd 0
    dw 64
    dw 56
    dw 1
    dw 64
    dw 0
    dw 0
    dd 1
    dd 5
    dq 0
    dq USER_CODE_VIRT
    dq USER_CODE_VIRT
    dq user_elf_end - user_elf_start
    dq user_elf_end - user_elf_start
    dq 0x1000
user_elf_entry:
    mov eax, 1
    mov rdi, USER_CODE_VIRT + (user_elf_message - user_elf_start)
    mov esi, user_elf_message_end - user_elf_message
    int 0x80
    ; Read the persistent text file into the writable user stack, then print it.
    mov eax, 4
    mov rdi, USER_STACK_VIRT + 0x800
    mov esi, 121
    int 0x80
    test eax, eax
    jz .elf_exit
    mov esi, eax
    mov rdi, USER_STACK_VIRT + 0x800
    mov eax, 1
    int 0x80
.elf_exit:
    mov eax, 2
    int 0x80
    jmp $
user_elf_message db 'NOVA ELF64 program loaded from disk: ', 10
user_elf_message_end:
user_elf_end:

align 8
tss64:
    times 104 db 0
tss64_end:

banner64 db 'NOVA OS - 64-bit kernel online', 0
prompt64 db 'nova> ', 0
command_help db 'help', 0
command_about db 'about', 0
command_clear db 'clear', 0
command_reboot db 'reboot', 0
command_memory db 'memory', 0
command_mem db 'mem', 0
command_ps db 'ps', 0
command_alloc db 'alloc', 0
command_free db 'free', 0
command_heap db 'heap', 0
command_halloc db 'halloc', 0
command_hfree db 'hfree', 0
command_uptime db 'uptime', 0
command_pmmtest db 'pmmtest', 0
command_schedtest db 'schedtest', 0
command_usertest db 'usertest', 0
command_userfaulttest db 'userfaulttest', 0
command_install db 'install', 0
command_exec db 'exec', 0
command_ls db 'ls', 0
command_cat db 'cat', 0
fs_magic db 'NOVAFS1'
fs_filename db 'NOVA.TXT'
fs_elf_filename db 'NOVA.ELF'
fs_sector_buffer times 512 db 0
fs_file_size dd 0
command_write_prefix db 'write ', 0
message_help db 'Commands: help, about, clear, memory, mem, ps, alloc, free, pmmtest, schedtest, usertest, userfaulttest, install, exec, ls, cat, write, heap, halloc, hfree, uptime, reboot', 0
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
message_pmmtest_pass db 'PMM safety test passed: reserved and double frees rejected.', 0
message_pmmtest_fail db 'PMM safety test FAILED.', 0
message_schedtest_pass db 'Scheduler test passed: both preempted tasks made progress.', 0
message_schedtest_fail db 'Scheduler test FAILED: a worker task did not run.', 0
message_ps_foreground db 'Task 0: foreground shell / user-program context', 0
message_ps_worker_a db 'Task 1: worker-a iterations: 0x', 0
message_ps_worker_b db 'Task 2: worker-b iterations: 0x', 0
message_ps_user db 'Task 3: user ELF state (0=stopped, 1=runnable): 0x', 0
message_uservm_failed db 'User VM setup failed: no physical pages available.', 0
message_user_exit db 'Ring-3 program exited through syscall.', 0
message_user_fault db 'User process faulted; terminated safely.', 0
message_user_bad_syscall db 'User process made an invalid syscall; terminated.', 0
message_fs_no_disk db 'Storage unavailable: attach a writable IDE data disk.', 0
message_fs_invalid db 'Storage is unformatted or has an invalid NOVA filesystem header.', 0
message_fs_empty db 'NOVA.TXT is empty or does not exist.', 0
message_fs_written db 'Saved NOVA.TXT to persistent storage.', 0
message_fs_list db ' bytes: 0x', 0
message_fs_read db 'File: ', 0
message_fs_write_usage db 'Usage: write <text> (maximum 121 bytes).', 0
message_fs_installed db 'Installed NOVA.ELF on persistent storage.', 0
message_fs_elf_invalid db 'NOVA.ELF is invalid or unsupported.', 0
message_fs_exec_failed db 'Could not load NOVA.ELF from storage.', 0
message_fs_exec_started db 'Started NOVA.ELF as a preemptively scheduled user process.', 0
message_fs_exec_running db 'A user process is already running.', 0
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
user_pml4_page dq 0
user_pdpt_page dq 0
user_pd_page dq 0
user_code_pt_page dq 0
user_stack_pt_page dq 0
user_code_page dq 0
user_stack_page dq 0
user_return_rsp dq 0
user_process_entry dq 0
user_process_state db 0
current_task_index db 0
task_started times 4 db 0
align 8
task_rsp times 4 dq 0
scheduler_counter_a dq 0
scheduler_counter_b dq 0
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
