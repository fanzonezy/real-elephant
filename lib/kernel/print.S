TI_GDT equ 0
RPL0 equ 0
SELECTOR_VIDEO equ (0x0003<<3) + TI_GDT + RPL0

[bits 32]

section .data
put_int_buffer dq 0 

section .text

global put_char
global put_str
global put_int

;------------------------ put_char ----------------------------- 
;功能描述:把栈中的1个字符写入光标所在处
;-------------------------------------------------------------------
put_char:
	pushad ;备份 32 位寄存器环境 13 ;需要保证 gs 中为正确的视频段选择子
	;为保险起见，每次打印时都为 gs 赋值
	mov ax, SELECTOR_VIDEO ; 不能直接把立即数送入段寄存器 15 mov gs, ax

;;;;;;;;; 获取当前光标位置 ;;;;;;;;;

	;先获得高 8 位
	mov dx, 0x03d4
	mov al, 0x0e
	out dx, al
	mov dx, 0x03d5
	in al, dx
	mov ah, al

	;再获取低 8 位
	mov dx, 0x03d4
	mov al, 0x0f
	out dx, al
	mov dx, 0x03d5
	in al, dx

	;将光标存入 bx
	mov bx, ax
	; 下面这行是在栈中获取待打印的字符
	mov ecx, [esp + 36] ;pushad压入4×8=32字节，加上主调函数 4 字节的返回地址，故 esp+36 字节 
	cmp cl, 0xd         ;CR是0x0d，LF是0x0a
	jz .is_carriage_return 
	cmp cl, 0xa
	jz .is_line_feed

	cmp cl, 0x8 	;BS(backspace)的asc码是8
	jz .is_backspace
	jmp .put_other
;;;;;;;;;;;;;;;;;;

.is_backspace:
;;;;;;;;;;;; backspace的一点说明 ;;;;;;;;;;
; 当为 backspace 时，本质上只要将光标移向前一个显存位置即可.后面再输入的字符自然会覆盖此处的字符
; 但有可能在键入backspace后并不再键入新的字符，这时光标已经向前移动到待删除的字符位置，但字符还在原处
; 这就显得好怪异，所以此处添加了空格或空字符 0
	dec bx
	shl bx,1 ;光标左移 1 位等于乘 2 ;表示光标对应显存中的偏移字节
	mov byte [gs:bx], 0x20 ;将待删除的字节补为 0 或空格皆可
	inc bx
	mov byte [gs:bx], 0x07
	shr bx,1
	jmp .set_cursor 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.put_other:
	shl bx, 1 ;光标位置用 2 字节表示，将光标值乘 2 ;表示对应显存中的偏移字节 
	mov [gs:bx], cl ; ASCII字符本身 
	inc bx 
	mov byte [gs:bx],0x07 ; 字符属性 
	shr bx, 1 ; 恢复老的光标值 
	inc bx ; 下一个光标值 
	cmp bx, 2000 
	jl .set_cursor  ; 若光标值小于 2000，表示未写到 ; 显存的最后，则去设置新的光标值 
					; 若超出屏幕字符数大小(2000) ; 则换行处理
.is_line_feed:        ; 是换行符 LF(\n) 
.is_carriage_return:  ; 是回车符 CR(\r)
;如果是CR(\r)，只要把光标移到行首就行了
	xor dx, dx  ; dx 是被除数的高 16 位，清 0
   	mov ax, bx	; ax 是被除数的低 16 位
   	mov si, 80  ; 由于是效仿 Linux，Linux 中\n 表示 ;下一行的行首，所以本系统中
   	div si      ; 把\n 和\r 都处理为 Linux 中\n 的意思 ;也就是下一行的行首
   	sub bx, dx  ; 光标值减去除 80 的余数便是取整  
   				;以上4行处理\r的代码

.is_carriage_return_end:  ; 回车符 CR 处理结束
	add bx, 80
	cmp bx, 2000 
.is_line_feed_end: ; 若是 LF(\n),将光标移+80 便可
	jl .set_cursor

;屏幕行范围是0~24，滚屏的原理是将屏幕的第1~24行搬运到第0~23行 ;再将第 24 行用空格填充 
.roll_screen:	; 若超出屏幕大小，开始滚屏
    cld
    mov ecx, 960 ; 2000-80=1920个字符要搬运，共1920*2=3840字节 ;一次搬 4 字节，共 3840/4=960 次
    mov esi, 0xc00b80a0	; 第1行行首
    mov edi, 0xc00b8000 ; 第0行行首
    rep movsd

;;;;;;;将最后一行填充为空白 
	mov ebx, 3840	; 最后一行首字符的第一个字节偏移= 1920 * 2 
	mov ecx, 80		;一行是 80 字符(160 字节)，每次清空 1 字符 ; (2 字节)，一行需要移动 80 次
.cls:
	mov word [gs:ebx], 0x0720;0x0720是黑底白字的空格键
	add ebx, 2
	loop .cls
	mov bx,1920 ;将光标值重置为1920，最后一行的首字符

.set_cursor: 
;将光标设为 bx 值
;;;;;;; 1 先设置高 8 位 ;;;;;;;;
	mov dx, 0x03d4 ;索引寄存器
	mov al, 0x0e ;用于提供光标位置的高 8 位
	out dx, al
	mov dx, 0x03d5 ;通过读写数据端口 0x3d5 来获得或设置光标位置 
	mov al, bh
	out dx, al

;;;;;;; 2 再设置低 8 位 ;;;;;;;;; 
	mov dx, 0x03d4
    mov al, 0x0f
    out dx, al
    mov dx, 0x03d5
    mov al, bl
	out dx, al 
.put_char_done:
	popad
	ret


put_str: 
;由于本函数中只用到了ebx和ecx，只备份这两个寄存器
    push ebx
    push ecx
    xor ecx, ecx 	; 准备用 ecx 存储参数，清空
    mov ebx, [esp + 12] ; 从栈中得到待打印的字符串地址
.goon:
	mov cl, [ebx]	; 如果处理到了字符串尾，跳到结束处返回
	cmp cl, 0
	jz .str_over 
	push ecx		; 为 put_char 函数传递参数
	call put_char 
	add esp, 4 		; 回收参数所占的栈空间
	inc ebx			; 使 ebx 指向下一个字符
	jmp .goon
.str_over: 
	pop ecx 
	pop ebx
	ret

put_int:
	pushad
	mov ebp, esp
	mov eax, [ebp+4*9] ; call的返回地址占4字节+pushad的8个4字节
	mov edx, eax
	mov edi, 7 ; 指定在 put_int_buffer 中初始的偏移量
	mov ecx, 8 ; 32位数字中，十六进制数字的位数是8个
	mov ebx, put_int_buffer

;将32位数字按照十六进制的形式从低位到高位逐个处理
;共处理 8 个十六进制数字

.16based_4bits: ; 每 4 位二进制是十六进制数字的 1 位
;遍历每一位十六进制数字	
	and edx, 0x0000000F
	cmp edx, 9
	jg .is_A2F
	add edx, '0'
	jmp .store

.is_A2F:
	sub edx, 10
	add edx, 'A'

;将每一位数字转换成对应的字符后，按照类似“大端”的顺序 ;存储到缓冲区 put_int_buffer
;高位字符放在低地址，低位字符要放在高地址，这样和大端字节序 ;类似,只不过咱们这里是字符序
.store:
; 此时 dl 中应该是数字对应的字符的 ASCII 码
	mov [ebx+edi], dl
	dec edi
	shr eax, 4
	mov edx, eax
	loop .16based_4bits		

;现在put_int_buffer中已全是字符，打印之前 ;把高位连续的字符去掉，比如把字符000123变成123
.ready_to_print: 
	inc edi

.skip_prefix_0:
	cmp edi,8 ; 若已经比较第 9 个字符了 ; 表示待打印的字符串为全 0	
	je .all0

.go_on_skip:
	mov cl, [put_int_buffer+edi]
	inc edi
	cmp cl, '0'
	je .skip_prefix_0 ; 继续判断下一位字符是否为字符 0(不是数字 0) 
	dec edi ;edi在上面的inc操作中指向了下一个字符
	;若当前字符不为'0',要使 edi 减 1 恢复指向当前字符 
	jmp .put_each_num

.all0:
	mov cl,'0'

.put_each_num: 
	push ecx	; 此时 cl 中为可打印的字符
	call put_char
	add esp, 4
	inc edi
	mov cl, [put_int_buffer+edi] ; 获取下一个字符到 cl 寄存器 
	cmp edi,8
	jl .put_each_num 
	popad
	ret			