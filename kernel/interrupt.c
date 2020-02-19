#include "interrupt.h"
#include "stdint.h"
#include "print.h"
#include "global.h"
#include "io.h"

#define IDT_DESC_CNT 0x21
#define PIC_M_CTRL 0x20 // 主片的控制端口是 0x20
#define PIC_M_DATA 0x21 // 主片的数据端口是 0x21
#define PIC_S_CTRL 0xa0 // 从片的控制端口是 0xa0
#define PIC_S_DATA 0xa1 // 从片的数据端口是 0xa1

struct intr_gate_desc {
	uint16_t func_offset_low_word;
	uint16_t selector;
	uint8_t  dcount;
	uint8_t  attribute;
	uint16_t func_offset_high_word;
};

static void make_idt_desc(struct intr_gate_desc* p_gdesc, uint8_t attr, intr_handler function);
static struct intr_gate_desc idt[IDT_DESC_CNT]; 
char * intr_name[IDT_DESC_CNT];  // 用于保存异常的名字
intr_handler intr_handler_table[IDT_DESC_CNT]; // 定义中断处理程序数组，在 kernel.S 中定义的 intrXXentry只是中断处理程序的入口，最终调用的是 intr_handler_table 中的处理程序

extern intr_handler intr_entry_table[IDT_DESC_CNT];

/* 创建中断门描述符 */
static void make_idt_desc(struct intr_gate_desc* p_gdesc, uint8_t attr, intr_handler function) { 
	p_gdesc->func_offset_low_word = (uint32_t)function & 0x0000FFFF;
	p_gdesc->selector = SELECTOR_K_CODE;
	p_gdesc->dcount = 0;
	p_gdesc->attribute = attr;
	p_gdesc->func_offset_high_word = ((uint32_t)function & 0xFFFF0000) >> 16;
}

/*初始化中断描述符表*/
static void idt_desc_init(void) {
	int i;
	for (i = 0; i < IDT_DESC_CNT; i++) {
		make_idt_desc(&idt[i], IDT_DESC_ATTR_DPL0, intr_entry_table[i]);
	}
	put_str(" idt_desc_init done\n");
}

/* 初始化可编程中断控制器 8259A */
static void pic_init(void) {
	/*初始化主片 */
	outb (PIC_M_CTRL, 0x11);	// ICW1: 边沿触发,级联 8259, 需要 ICW4
	outb (PIC_M_DATA, 0x20);	// ICW2: 起始中断向量号为 0x20, 也就是 IR[0-7] 为 0x20 ~ 0x27
	outb (PIC_M_DATA, 0x04);	// ICW3: IR2 接从片
	outb (PIC_M_DATA, 0x01); 	// ICW4: 8086 模式, 正常 EOI

	/*初始化从片 */
	outb (PIC_S_CTRL, 0x11);	// ICW1: 边沿触发,级联 8259, 需要 ICW4
	outb (PIC_S_DATA, 0x28);	// ICW2: 起始中断向量号为 0x28, 也就是 IR[8-15]为 0x28 ~ 0x2F
	outb (PIC_S_DATA, 0x02);	// ICW3: 设置从片连接到主片的 IR2 引脚
	outb (PIC_S_DATA, 0x01); 	// ICW4: 8086 模式, 正常 EOI

	put_str(" pic_init done\n");
}

/* 通用的中断处理函数，一般用在异常出现时的处理 */
static void general_intr_handler(uint8_t vec_nr) {
	// IRQ7和IRQ15会产生伪中断(spurious interrupt)，无需处理 //0x2f 是从片 8259A 上的最后一个 IRQ 引脚，保留项
	if (vec_nr == 0x27 || vec_nr == 0x2f) {
		return;
	}
	put_str("int vector : 0x"); 
	put_int(vec_nr);
	put_char('\n');
}

/* 完成一般中断处理函数注册及异常名称注册 */
static void exception_init(void) {
	int i;
	for (i = 0; i < IDT_DESC_CNT; i++) {
		/* idt_table数组中的函数是在进入中断后根据中断向量号调用的
		 * 见 kernel/kernel.S 的 call [idt_table + %1*4] */
		intr_handler_table[i] = general_intr_handler; // 默认为 general_intr_handler, 以后会由 register_handler 来注册具体处理函数
		intr_name[i] = "unknown"; // 先统一赋值为 unknown
	}
	intr_name[0] = "#DE Divide Error";
	intr_name[1] = "#DB Debug Exception";
	intr_name[2] = "NMI Interrupt";
	intr_name[3] = "#BP Breakpoint Exception";
	intr_name[4] = "#OF Overflow Exception";
	intr_name[5] = "#BR BOUND Range Exceeded Exception"; 
	intr_name[6] = "#UD Invalid Opcode Exception";
	intr_name[7] = "#NM Device Not Available Exception"; 
	intr_name[8] = "#DF Double Fault Exception";
	intr_name[9] = "Coprocessor Segment Overrun";
	intr_name[10] = "#TS Invalid TSS Exception";
	intr_name[11] = "#NP Segment Not Present";
	intr_name[12] = "#SS Stack Fault Exception";
	intr_name[13] = "#GP General Protection Exception"; 
	intr_name[14] = "#PF Page-Fault Exception";
	// intr_name[15] 第 15 项是 intel 保留项,未使用
	intr_name[16] = "#MF x87 FPU Floating-Point Error"; 
	intr_name[17] = "#AC Alignment Check Exception";
	intr_name[18] = "#MC Machine-Check Exception";
	intr_name[19] = "#XF SIMD Floating-Point Exception";
}

/*完成有关中断的所有初始化工作*/
void idt_init(void) {
	put_str("idt_init start\n");
	idt_desc_init();	// 初始化中断描述符表
	exception_init();	// 异常名初始化并注册通常的中断处理函数
	pic_init();			// 初始化 8259A

	/* 加载idt */
	uint64_t idt_operand = ((sizeof(idt) - 1) | ((uint64_t)((uint32_t)idt << 16))); 
	asm volatile("lidt %0" : : "m" (idt_operand));
	put_str("idt_init done\n");
}