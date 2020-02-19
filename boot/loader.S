%include "boot.inc"
section loader vstart=LOADER_BASE_ADDR
LOADER_STACK_TOP equ LOADER_BASE_ADDR 

;------------------------------------------------------------ 
;构建gdt及其内部的描述符
;------------------------------------------------------------ 

; gdt第0项，全零。（8字节）
GDT_BASE: dd 0x00000000 
		  dd 0x00000000

; gdt第1项，代码段描述符。（8字节）
CODE_DESC: dd 0x0000FFFF
		   dd DESC_CODE_HIGH4

; gdt第2项，数据段描述符。（8字节）
DATA_STACK_DESC: dd 0x0000FFFF
				 dd DESC_DATA_HIGH4

; gdt第3项，显示缓冲区段描述符。（8字节）
VIDEO_DESC: dd 0x80000007       ;limit=(0xbffff-0xb8000)/4k=0x7
			dd DESC_VIDEO_HIGH4 ;此时 dpl 为 0

GDT_SIZE  equ $ - GDT_BASE
GDT_LIMIT equ GDT_SIZE - 1

; 此处预留 60 个描述符的空位 （480字节）
times 60 dq 0 

SELECTOR_CODE  equ (0x0001<<3) + TI_GDT + RPL0   ; 相当于(CODE_DESC - GDT_BASE)/8 + TI_GDT + RPL0 
SELECTOR_DATA  equ (0x0002<<3) + TI_GDT + RPL0   ; 同上
SELECTOR_VIDEO equ (0x0003<<3) + TI_GDT + RPL0   ; 同上

total_mem_bytes dd 0
 
;以下是 gdt 的指针，前 2 字节是 gdt 界限，后 4 字节是 gdt 起始地址 （6字节）
gdt_ptr dw GDT_LIMIT 
	    dd GDT_BASE

;------------------------------------------------------------ 
; BIOS 0x15中断函数返回值缓冲区 
;------------------------------------------------------------ 
ards_buf times 244 db 0
ards_nr  dw 0

;------------------------------------------------------------ 
; loader起始
;------------------------------------------------------------ 
; 此处地址为 0x900 + 0x300(8 * 4 + 480 + 4 + 6 + 244 + 2)

loader_start:
;------------------------------------------------------------ 
; 检测装机内存
;------------------------------------------------------------ 

; int 15h eax = 0000E820h ,edx = 534D4150h ('SMAP') 获取内存布局
	xor ebx, ebx
	mov edx, 0x534d4150
	mov di, ards_buf

.e820_mem_get_loop:
	mov eax, 0x0000e820
	mov ecx, 20
	int 0x15
	jc .e820_failed_so_try_e801
	add di, cx
	inc word [ards_nr]
	cmp ebx, 0
	jnz .e820_mem_get_loop
	mov cx, [ards_nr]
	mov ebx, ards_buf
	xor edx, edx

.find_max_mem_area:
	mov eax, [ebx]
	add eax, [ebx+8]
	add ebx, 20
	cmp edx, eax
	jge .next_ards
	mov edx, eax

.next_ards:
	loop .find_max_mem_area
	jmp .mem_get_ok

.e820_failed_so_try_e801:
	mov ax, 0xe801
	int 0x15
	jc .e801_failed_so_try88

	mov cx,  0x400
	mul cx
	shl edx, 16
	and eax, 0x0000FFFF
	or  edx, eax
	add edx, 0x100000
	mov esi, edx
	xor eax, eax
	mov ax,  bx
	mov ecx, 0x10000 
	mul ecx			

	add esi, eax
	mov edx, esi
	jmp .mem_get_ok

.e801_failed_so_try88:
	mov ah, 0x88
	int 0x15
	jc .error_hlt
	and eax, 0x0000FFFF

	mov cx, 0x400
	mul cx
	shl edx, 16
	or edx, eax
	add edx,0x100000
	jmp .mem_get_ok

.error_hlt:
	hlt

.mem_get_ok:
	mov [total_mem_bytes], edx	


;------------------------------------------------------------
;准备进入保护模式  
;------------------------------------------------------------

	;1 打开A20
	in al,0x92
	or al, 0000_0010b
	out 0x92, al

	;2 加载gdt
	lgdt [gdt_ptr]

 	
 	;3 将cr0的pe位置1
 	mov eax, cr0
 	or eax, 0x00000001
	mov cr0, eax

 	jmp dword SELECTOR_CODE:p_mode_start  ; refresh pipeline


[bits 32]
p_mode_start:

	mov ax, SELECTOR_DATA 
	mov ds, ax
	mov es, ax
	mov ss, ax
	mov esp,LOADER_STACK_TOP 
	mov ax, SELECTOR_VIDEO 
	mov gs, ax

	mov byte [gs:160], 'E'
	mov byte [gs:162], 'n'
	mov byte [gs:164], 't'
	mov byte [gs:166], 'e'
	mov byte [gs:168], 'r'
	mov byte [gs:170], 'e'
	mov byte [gs:172], 'd'
	mov byte [gs:174], ' '
	mov byte [gs:176], 'P'
	mov byte [gs:178], 'r'
	mov byte [gs:180], 'o'
	mov byte [gs:182], 't'
	mov byte [gs:184], 'e'
	mov byte [gs:186], 'c'
	mov byte [gs:188], 't'
	mov byte [gs:190], 'e'
	mov byte [gs:192], 'd'
	mov byte [gs:194], ' '
	mov byte [gs:196], 'M'
	mov byte [gs:198], 'o'
	mov byte [gs:200], 'd'
	mov byte [gs:202], 'e'

	; 加载内核到内存缓冲区
	mov eax, KERNEL_START_SECTOR
	mov ebx, KERNEL_BIN_BASE_ADDR
	mov ecx, 200
	call rd_disk_m_32

	; 初始化页表目录和页表
	call setup_page
	sgdt [gdt_ptr]
	mov ebx, [gdt_ptr + 2]
	or  dword [ebx + 0x18 + 4], 0xc0000000
	add dword [gdt_ptr + 2], 0xc0000000
	add esp, 0xc0000000
	mov eax, PAGE_DIR_TABLE_POS
	mov cr3, eax
	mov eax, cr0
	or eax, 0x80000000
	mov cr0, eax
	lgdt [gdt_ptr]

	mov byte [gs:320], 'E'
	mov byte [gs:322], 'n'
	mov byte [gs:324], 'a'
	mov byte [gs:326], 'b'
	mov byte [gs:328], 'l'
	mov byte [gs:330], 'e'
	mov byte [gs:332], 'd'
	mov byte [gs:334], ' '
	mov byte [gs:336], 'V'
	mov byte [gs:338], 'i'
	mov byte [gs:340], 'r'
	mov byte [gs:342], 't'
	mov byte [gs:344], 'u'
	mov byte [gs:346], 'a'
	mov byte [gs:348], 'l'
	mov byte [gs:350], ' '
	mov byte [gs:352], 'M'
	mov byte [gs:354], 'e'
	mov byte [gs:356], 'm'
	mov byte [gs:358], 'o'
	mov byte [gs:360], 'r'
	mov byte [gs:362], 'y'

	; 初始化内核
	jmp SELECTOR_CODE:enter_kernel

enter_kernel:
	call kernel_init
	mov esp, 0xc009f000

	mov byte [gs:480], 'K'
	mov byte [gs:482], 'e'
	mov byte [gs:484], 'r'
	mov byte [gs:486], 'n'
	mov byte [gs:488], 'e'
	mov byte [gs:490], 'l'
	jmp KERNEL_ENTRY_POINT	


;	

setup_page:
	mov ecx, 4096
	mov esi, 0

; 先将页表目录区域清零
.clear_page_dir:
	mov byte [PAGE_DIR_TABLE_POS + esi], 0
	inc esi
	loop .clear_page_dir

.create_pde:
	mov eax, PAGE_DIR_TABLE_POS
	add eax, 0x1000 ; 计算页表区域起始地址，PAGE_DIR_TABLE_POS + 4k（页表目录大小）
	mov ebx, eax    ; 使用ebx存储页表区域的其实地址

	; 页表目录项结构
	; ｜31｜30｜29｜28｜27｜26｜25｜24｜23｜22｜21｜20｜19｜17｜16｜15｜14｜13｜12｜11｜10｜9｜8｜7｜6｜5｜4  ｜3   ｜2 ｜1 ｜0｜
	; ｜           page table directory physical addr 31-12 bits             ｜   AVL  ｜G｜0｜D｜A｜PCD｜PWT ｜US｜RW｜P｜

	; 页表项结构
	; ｜31｜30｜29｜28｜27｜26｜25｜24｜23｜22｜21｜20｜19｜17｜16｜15｜14｜13｜12｜11｜10｜9｜8｜7  ｜6｜5｜4  ｜3   ｜2 ｜1 ｜0｜
	; ｜                  page table physical addr 31-12 bits                ｜   AVL  ｜G｜PAT｜D｜A｜PCD｜PWT ｜US｜RW｜P｜

	; AVL：Available
	; G：Global
	; D：Dirty
	; A：Accessed
	; PAT：Page Attribute Table 
	; PCD：Page-level Cache Disable
	; PWT：Page-level Write-Through
	; US：User/Supervisor
	; RW：Read/Write
	; P： Present

	or eax, PG_US_U | PG_RW_W | PG_P 		; (注意此时eax的值为PAGE_DIR_TABLE_POS + 0x1000， 即位第一个页表的起始地址)
											; 页目录项的属性 RW 和 P 位为 1，US 为 1，表示用户属性，所有特权级别都可以访问
	mov [PAGE_DIR_TABLE_POS + 0x0],   eax 	; 写入第 1 个目录项
	mov [PAGE_DIR_TABLE_POS + 0xc00], eax 	; 一个页表项占用 4 字节, 0xc00 = 4 * 768 = 12(c) * 256
	sub eax, 0x1000                         ; 对应行191
	mov [PAGE_DIR_TABLE_POS + 4092], eax    ; 使最后一个目录项指向页目录表自己的地址

	mov ecx, 256
	mov esi, 0
	mov edx, PG_US_U | PG_RW_W | PG_P

.create_pte:
	mov [ebx+esi*4], edx
	add edx,4096		   ; 4096 = 0x1000
	inc esi
	loop .create_pte

	mov eax, PAGE_DIR_TABLE_POS
	add eax, 0x2000
	or eax, PG_US_U | PG_RW_W | PG_P
	mov ebx, PAGE_DIR_TABLE_POS
	mov ecx, 254
	mov esi, 769

.create_kernel_pde:
	mov [ebx+esi*4], eax
	inc esi
	add eax, 0x1000
	loop .create_kernel_pde
	ret		

kernel_init:
	xor eax, eax
	xor ebx, ebx
	xor ecx, ecx
	xor edx, edx

	mov dx,  [KERNEL_BIN_BASE_ADDR + 42] ; 偏移文件 42 字节处的属性是 e_phentsize，表示 program header 大小
	mov ebx, [KERNEL_BIN_BASE_ADDR + 28] ; 偏移文件开始部分 28 字节的地方是 e_phoff
	add ebx,  KERNEL_BIN_BASE_ADDR  	 
	mov cx,  [KERNEL_BIN_BASE_ADDR + 44] ; 偏移文件开始部分 44 字节的地方是 e_phnum，表示有几个 program header

.each_segment:
	cmp byte [ebx + 0], PT_NULL
	je .PTNULL

	push dword [ebx + 16]  	; 压入函数 memcpy 的第三个参数:size, program header中偏移16字节的地方是p_filesz.  
	mov eax, [ebx + 4]
	add eax, KERNEL_BIN_BASE_ADDR
	push eax				; 压入函数 memcpy 的第二个参数:源地址
	push dword [ebx + 8]  	; 压入函数 memcpy 的第一个参数:目的地址, 偏移程序头 8 字节的位置是 p_vaddr，这就是目的地址
	call mem_cpy
	add esp, 12

.PTNULL:
	add ebx, edx

	loop .each_segment
	ret

mem_cpy:
	cld
	push ebp
	mov ebp, esp 
	push ecx
	; rep指令用到了ecx
	; 但 ecx 对于外层段的循环还有用，故先入栈备份
	mov edi, [ebp + 8]
	mov esi, [ebp + 12]
	mov ecx, [ebp + 16]
	rep movsb
	;恢复环境 
	pop ecx 
	pop ebp 
	ret		

rd_disk_m_32:
	; eax=LBA扇区号
  	; ebx=将数据写入的内存地址 
  	; ecx=读入的扇区数
  	mov esi, eax   ;备份eax
  	mov edi, ecx   ;备份ecx

  	;读写硬盘:
  	;第1步:设置要读取的扇区数  
  	mov dx,0x1f2
  	mov al,cl
  	out dx,al   ;读取的扇区数

  	mov eax,esi 

  	;第 2 步:将 LBA 地址存入 0x1f3 ~ 0x1f6
  	;LBA 地址 7~0 位写入端口 0x1f3
  	mov dx,0x1f3
  	out dx,al

  	;LBA 地址 15~8 位写入端口 0x1f4
  	mov cl,8
  	shr eax,cl
  	mov dx,0x1f4
  	out dx,al

  	;LBA 地址 23~16 位写入端口 0x1f5
  	shr eax,cl
  	mov dx,0x1f5
  	out dx,al

  	shr eax,cl
  	and al,0x0f ; lba第24~27位
  	or al,0xe0  ; 设置 7~4 位为 1110,表示 lba 模式
  	mov dx,0x1f6
  	out dx,al

  	;第3步:向0x1f7端口写入读命令,0x20 
  	mov dx,0x1f7
  	mov al,0x20
  	out dx,al

  	;第4步:检测硬盘状态 
.not_ready:
  	;同一端口,写时表示写入命令字,读时表示读入硬盘状态
  	nop
  	in al,dx
  	and al,0x88 ;第 4 位为 1 表示硬盘控制器已准备好数据传输, 第 7 位为 1 表示硬盘忙
  	cmp al, 0x08
  	jnz .not_ready

  	;第5步: 从0x1f0端口读数据
  	mov ax, di
  	mov dx, 256
  	mul dx
  	mov cx, ax  ; di为要读取的扇区数,一个扇区有512字节,每次读入一个字
              	; 共需 di*512/2 次,所以 di*256 
  	mov dx, 0x1f0

.go_on_read: 
  	in ax,dx
  	mov [ebx],ax
  	add ebx,2
  	loop .go_on_read 
  	ret