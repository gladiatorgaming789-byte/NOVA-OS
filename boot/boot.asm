BITS 16
ORG 0x7C00

KERNEL_SEG equ 0x0000
KERNEL_OFF equ 0x1000
KERNEL_SECTORS equ 512           ; hard safety limit: 256 KiB

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld
    mov [boot_drive], dl
    call serial_init16
    mov si, marker_b
    call print_string

    ; The build patches kernel_sector_limit to ceil(kernel_size / 512).
    ; Read one sector per BIOS call for maximum CHS compatibility.
    mov ax, [kernel_sector_limit]
    mov [sectors_remaining], ax
    mov byte [current_sector], 2
    mov byte [current_head], 0
    mov byte [current_cylinder], 0
    mov bx, KERNEL_OFF
    mov ax, KERNEL_SEG
    mov es, ax
    mov byte [disk_retries], 3

.read_sector:
    mov ah, 0x02
    mov al, 1
    mov ch, [current_cylinder]
    mov cl, [current_sector]
    mov dh, [current_head]
    mov dl, [boot_drive]
    int 0x13
    jnc .sector_loaded

    xor ah, ah
    mov dl, [boot_drive]
    int 0x13
    dec byte [disk_retries]
    jnz .read_sector
    jmp disk_error

.sector_loaded:
    add bx, 512
    jnc .advance_chs
    mov ax, es
    add ax, 0x1000
    mov es, ax

.advance_chs:
    inc byte [current_sector]
    cmp byte [current_sector], 19
    jb .count_sector
    mov byte [current_sector], 1
    inc byte [current_head]
    cmp byte [current_head], 2
    jb .count_sector
    mov byte [current_head], 0
    inc byte [current_cylinder]

.count_sector:
    dec word [sectors_remaining]
    jz .kernel_loaded
    mov byte [disk_retries], 3
    jmp .read_sector

.kernel_loaded:
    mov si, marker_k
    call print_string
    jmp KERNEL_SEG:KERNEL_OFF

disk_error:
    mov si, marker_error
    call print_string
.hang:
    cli
    hlt
    jmp .hang

serial_init16:
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

serial_putc16:
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

print_string:
    lodsb
    test al, al
    jz .done
    push ax
    call serial_putc16
    pop ax
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp print_string
.done:
    ret

kernel_count_signature db 'NOVA_KSEC'
kernel_sector_limit dw KERNEL_SECTORS
boot_drive db 0
disk_retries db 0
current_sector db 2
current_head db 0
current_cylinder db 0
sectors_remaining dw 0
marker_b db 'B', 0
marker_k db 'K', 0
marker_error db 'D', 0

times 510 - ($ - $$) db 0
dw 0xAA55
