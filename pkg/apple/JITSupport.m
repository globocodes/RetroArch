//
//  JITSupport.m
//  RetroArchiOS
//
//  Created by Yoshi Sugawara on 9/25/21.
//  Copyright © 2021 RetroArch. All rights reserved.
//
//  Copied from UTMApp, original author: osy
//  

#import <Foundation/Foundation.h>

#import "JITSupport.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/getsect.h>
#include <pthread.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>

#include <string/stdstring.h>
#include <file/file_path.h>
#include <retro_miscellaneous.h>
#include "../../verbosity.h"

extern int csops(pid_t pid, unsigned int ops, void * useraddr, size_t usersize);
extern boolean_t exc_server(mach_msg_header_t *, mach_msg_header_t *);
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);

#define    CS_OPS_STATUS        0    /* return status */
#define CS_KILL     0x00000200  /* kill process if it becomes invalid */
#define CS_DEBUGGED 0x10000000  /* process is currently or has previously been debugged and allowed to run with invalid pages */
#define PT_TRACE_ME     0       /* child declares it's being traced */
#define PT_SIGEXC       12      /* signals as exceptions for current_proc */

#if !TARGET_OS_TV
static void *exception_handler(void *argument) {
    mach_port_t port = *(mach_port_t *)argument;
    mach_msg_server(exc_server, 2048, port, 0);
    return NULL;
}
#endif

static bool jb_has_debugger_attached(void) {
    int flags;
    return !csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) && flags & CS_DEBUGGED;
}

#ifndef P_TRACED
#define P_TRACED 0x00000800 /* sys/proc.h: a tracer holds this process */
#endif

/* Manic MP: a debugger is attached at this moment. CS_DEBUGGED above is sticky
 * ("is currently or has previously been debugged"); P_TRACED is set while a
 * tracer holds the process and cleared when it detaches or exits. */
static bool jb_has_live_tracer(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4]  = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0)
        return false;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

/* Manic MP: iOS 26 on A15/M2 or newer (machine major >= 14) runs the Trusted
 * Execution Monitor. There a process executes unsigned pages only while a
 * debugger is attached: the cores ask the attached StikDebug to make each JIT
 * region executable (brk, universal.js), and once StikDebug is gone the request
 * is answered by nobody. Dolphin then booted with JIT ARM64 and died on the
 * first block of its code buffer (SIGBUS, KERN_CODESIGN_ERROR) because
 * CS_DEBUGGED still said JIT was available. On PPL hardware CS_DEBUGGED alone
 * keeps JIT working after the debugger detaches. Same rule as hasTXM in the app. */
static bool jit_needs_live_debugger(void) {
    static bool txm = false;
    static dispatch_once_t txmOnce = 0;
    dispatch_once(&txmOnce, ^{
        if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 26)
            return;
        struct utsname systemInfo;
        if (uname(&systemInfo) != 0)
            return;
        const char *digits = NULL;
        if (strncmp(systemInfo.machine, "iPhone", 6) == 0)
            digits = systemInfo.machine + 6;
        else if (strncmp(systemInfo.machine, "iPad", 4) == 0)
            digits = systemInfo.machine + 4;
        if (!digits || !strchr(digits, ','))
            return;
        txm = atoi(digits) >= 14;
    });
    return txm;
}

bool jit_debugger_detached(void)
{
    return jit_needs_live_debugger() && jb_has_debugger_attached() && !jb_has_live_tracer();
}

bool jb_enable_ptrace_hack(void) {
#if !TARGET_OS_TV
    bool debugged = jb_has_debugger_attached();
    
    // Thanks to this comment: https://news.ycombinator.com/item?id=18431524
    // We use this hack to allow mmap with PROT_EXEC (which usually requires the
    // dynamic-codesigning entitlement) by tricking the process into thinking
    // that Xcode is debugging it. We abuse the fact that JIT is needed to
    // debug the process.
    if (ptrace(PT_TRACE_ME, 0, NULL, 0) < 0) {
        return false;
    }
    
    // ptracing ourselves confuses the kernel and will cause bad things to
    // happen to the system (hangs…) if an exception or signal occurs. Setup
    // some "safety nets" so we can cause the process to exit in a somewhat sane
    // state. We only need to do this if the debugger isn't attached. (It'll do
    // this itself, and if we do it we'll interfere with its normal operation
    // anyways.)
    if (!debugged) {
        // First, ensure that signals are delivered as Mach software exceptions…
        ptrace(PT_SIGEXC, 0, NULL, 0);
        
        // …then ensure that this exception goes through our exception handler.
        // I think it's OK to just watch for EXC_SOFTWARE because the other
        // exceptions (e.g. EXC_BAD_ACCESS, EXC_BAD_INSTRUCTION, and friends)
        // will end up being delivered as signals anyways, and we can get them
        // once they're resent as a software exception.
        mach_port_t port = MACH_PORT_NULL;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
        task_set_exception_ports(mach_task_self(), EXC_MASK_SOFTWARE, port, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        pthread_t thread;
        pthread_create(&thread, NULL, exception_handler, (void *)&port);
    } else {
        // JIT code frequently causes an EXC_BAD_ACCESS exception that lldb
        // cannot be convinced to ignore. Instead we can set up a nul handler
        // that effectively causes it to be ignored. Note that this sometimes
        // also hides actual crashes from the debugger.
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    }
#endif
    
    return true;
}

bool jit_available(void)
{
   static bool canOpenApps = false;
   static dispatch_once_t appsOnce = 0;
   dispatch_once(&appsOnce, ^{
      DIR *apps = opendir("/Applications");
      if (apps)
      {
         closedir(apps);
         canOpenApps = true;
      }
   });

   static bool dylded = false;
   static dispatch_once_t dyldOnce = 0;
   dispatch_once(&dyldOnce, ^{
      int imageCount = _dyld_image_count();
      for (int i = 0; i < imageCount; i++)
      {
         if (string_is_equal("/usr/lib/pspawn_payload-stg2.dylib", _dyld_get_image_name(i)))
            dylded = true;
      }
   });

   static bool doped = false;
   static dispatch_once_t dopeOnce = 0;
   dispatch_once(&dopeOnce, ^{
      int64_t (*jbdswDebugMe)(void) = dlsym(RTLD_DEFAULT, "jbdswDebugMe");
      if (jbdswDebugMe)
      {
         int64_t ret = jbdswDebugMe();
         doped = (ret == 0);
      }
   });

   if (canOpenApps || dylded || doped)
      return true;

   /* the debugger could be attached at any time, its value can't be cached */
   if (!jb_has_debugger_attached())
      return false;

   /* Manic MP: on TXM the debugger has to be attached right now, not just once. */
   if (jit_needs_live_debugger() && !jb_has_live_tracer())
      return false;

   return true;
}
