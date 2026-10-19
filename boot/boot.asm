BITS 16
ORG 0x7C00

KERNEL_SEG equ 0x0000
KERNEL_OFF equ 0x1000
KERNEL_SECTORS equ 512           ; 256 KiB maximum kernel image

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
    mov si, marker_b
    call print_string

    ; Load a bounded kernel image one sector at a time. Single-sector CHS
    ; reads avoid BIOS track-boundary restrictions. ES:BX advances contiguously
    ; across 64 KiB boundaries; the E820 map lives at 0x50000, beyond this cap.
    mov word [sectors_remaining], KERNEL_SECTORS
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

print_string:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    mov bx, 0x0007
    int 0x10
    jmp print_string
.done:
    ret

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
