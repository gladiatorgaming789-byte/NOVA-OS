BITS 16
ORG 0x7C00

KERNEL_SEG equ 0x0000
KERNEL_OFF equ 0x1000
KERNEL_SECTORS equ 16

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

    ; Read sectors 2..17 into physical address 0x1000.
    ; Retry three times and reset the BIOS disk subsystem between failures.
    mov byte [disk_retries], 3
.read_kernel:
    xor ax, ax
    mov es, ax
    mov bx, KERNEL_OFF
    mov ah, 0x02
    mov al, KERNEL_SECTORS
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, [boot_drive]
    int 0x13
    jnc .kernel_loaded

    xor ah, ah
    mov dl, [boot_drive]
    int 0x13
    dec byte [disk_retries]
    jnz .read_kernel
    jmp disk_error

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
marker_b db 'B', 0
marker_k db 'K', 0
marker_error db 'D', 0

times 510 - ($ - $$) db 0
dw 0xAA55
