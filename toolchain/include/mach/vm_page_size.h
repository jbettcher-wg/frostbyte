/* <mach/vm_page_size.h> appeared in Mac OS X 10.6. On 10.5 the page size
 * globals live in <mach/mach_init.h> (vm_page_size only), and the kernel
 * page size equals the user page size (4 KiB on this port: hw.pagesize). */
#ifndef LEOPARD_SHIM_VM_PAGE_SIZE_H
#define LEOPARD_SHIM_VM_PAGE_SIZE_H
#include <mach/mach_init.h>
#include <mach/vm_types.h>
#ifndef vm_kernel_page_size
#define vm_kernel_page_size  vm_page_size
#define vm_kernel_page_mask  (vm_page_size - 1)
#define vm_kernel_page_shift 12
#define vm_page_mask         (vm_page_size - 1)
#define vm_page_shift        12
#endif
#endif
