BITS 16
ORG 0x1000

kernel_entry:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    mov si, marker_e
    call print16

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

print16:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp print16
.done:
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
    mov esp, 0x90000

    mov esi, marker_c
    call print32

    ; Clear PML4, PDPT, and PD at 0x90000, 0x91000, 0x92000.
    xor eax, eax
    mov edi, 0x90000
    mov ecx, (3 * 4096) / 4
    rep stosd

    mov dword [0x90000], 0x91003
    mov dword [0x90004], 0
    mov dword [0x91000], 0x92003
    mov dword [0x91004], 0

    ; Identity map first 1 GiB using 512 2-MiB pages.
    mov edi, 0x92000
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

    mov eax, 0x90000
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

print32:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0F
    mov ebx, 0x000B8000
    mov edx, [vga_cursor]
    mov [ebx + edx], ax
    add edx, 2
    mov [vga_cursor], edx
    ret
.done:
    ret

BITS 64
long_mode_entry:
    mov ax, DATA64_SEL
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, 0x90000
    mov rdi, 0xB8000
    mov al, 'L'
    mov ah, 0x0A
    mov [rdi + 10], ax
.halt:
    cli
    hlt
    jmp .halt

BITS 16
vga_cursor dd 2
marker_e db 'E', 0
marker_g db 'G', 0
BITS 32
marker_c db 'C', 0
marker_j db 'J', 0
marker_p db 'P', 0
