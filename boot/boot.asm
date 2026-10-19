BITS 16
ORG 0x7C00

KERNEL_SEG equ 0x0000
KERNEL_OFF equ 0x1000
KERNEL_SECTORS equ 512           ; 256 KiB maximum kernel image
SECTORS_PER_TRACK equ 18
HEADS_PER_CYLINDER equ 2

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

    ; Read track-bounded chunks. A chunk never crosses a 64 KiB ES:BX
    ; boundary, avoiding slow single-sector BIOS calls and DMA boundary bugs.
    mov ax, [kernel_sector_limit]
    mov [sectors_remaining], ax
    mov byte [current_sector], 2
    mov byte [current_head], 0
    mov byte [current_cylinder], 0
    mov bx, KERNEL_OFF
    mov ax, KERNEL_SEG
    mov es, ax
    mov byte [disk_retries], 3

.read_chunk:
    ; Sectors remaining on this CHS track.
    mov al, SECTORS_PER_TRACK
    sub al, [current_sector]
    inc al
    mov [sectors_this_read], al

    ; Sectors remaining before BX wraps. 0 means a full 64 KiB window.
    mov ax, bx
    test ax, ax
    jz .full_window
    neg ax
    shr ax, 9
    jmp .window_ready
.full_window:
    mov ax, 128
.window_ready:
    cmp al, [sectors_this_read]
    jae .read_disk
    mov [sectors_this_read], al

.remaining_limit:
    mov ax, [sectors_remaining]
    movzx dx, byte [sectors_this_read]
    cmp ax, dx
    jae .read_disk
    mov [sectors_this_read], al

.read_disk:
    mov ah, 0x02
    mov al, [sectors_this_read]
    mov ch, [current_cylinder]
    mov cl, [current_sector]
    mov dh, [current_head]
    mov dl, [boot_drive]
    int 0x13
    jnc .chunk_loaded

    xor ah, ah
    mov dl, [boot_drive]
    int 0x13
    dec byte [disk_retries]
    jnz .read_chunk
    jmp disk_error

.chunk_loaded:
    movzx eax, byte [sectors_this_read]
    shl eax, 9
    add bx, ax
    jnc .advance_chs
    mov ax, es
    add ax, 0x1000
    mov es, ax

.advance_chs:
    mov al, [sectors_this_read]
.advance_one:
    inc byte [current_sector]
    cmp byte [current_sector], SECTORS_PER_TRACK + 1
    jb .sector_advanced
    mov byte [current_sector], 1
    inc byte [current_head]
    cmp byte [current_head], HEADS_PER_CYLINDER
    jb .sector_advanced
    mov byte [current_head], 0
    inc byte [current_cylinder]
.sector_advanced:
    dec al
    jnz .advance_one

    movzx ax, byte [sectors_this_read]
    sub [sectors_remaining], ax
    jz .kernel_loaded
    mov byte [disk_retries], 3
    jmp .read_chunk

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
sectors_this_read db 0
marker_b db 'B', 0
marker_k db 'K', 0
marker_error db 'D', 0

times 510 - ($ - $$) db 0
dw 0xAA55
