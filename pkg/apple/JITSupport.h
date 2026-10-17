//
//  JITSupport.h
//  RetroArchiOS
//
//  Created by Yoshi Sugawara on 9/25/21.
//  Copyright © 2021 RetroArch. All rights reserved.
//

#ifndef JITSupport_h
#define JITSupport_h

#include <stdbool.h>

bool jit_available(void);
bool jb_enable_ptrace_hack(void);
/* Manic MP: this process was debugged once (CS_DEBUGGED) but no debugger is
 * attached now, on hardware where JIT only works while one is (TXM: iOS 26 on
 * A15/M2 or newer). jit_available() is false in this state. */
bool jit_debugger_detached(void);

#endif /* JITSupport_h */
