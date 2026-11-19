// Guest program for ipswrun: loads the release's IMDPersistence and has it create an empty
// Messages database at the default location in the guest's home, as the first launch would.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

// Declares a pointer to the framework's function `name`, NULL if this release doesn't have it.
#define SYM(ret, name, ...) ret (*name)(__VA_ARGS__) = dlsym(h, #name)
#define CALL_IF_PRESENT(name, ...) do { if (name) name(__VA_ARGS__); } while (0)

int main(void) {
  void *h = dlopen("/System/Library/PrivateFrameworks/IMDPersistence.framework/IMDPersistence", RTLD_NOW);
  if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
  SYM(void *, IMDSharedSqliteDatabase, void);
  if (!IMDSharedSqliteDatabase) { fprintf(stderr, "no IMDSharedSqliteDatabase\n"); return 3; }

  // Newer releases only open the store in the process that owns it (imagent's database server).
  SYM(void, IMDSetIsRunningInDatabaseServerProcess, int);
  SYM(void, IMDSetThreadLocalIsRunningInDatabaseServerProcess, CFTypeRef);
  SYM(void, IMDEnsureSharedRecordStoreInitialized, void);
  SYM(CFStringRef, IMDSharedSqliteDatabasePath, void);
  CALL_IF_PRESENT(IMDSetIsRunningInDatabaseServerProcess, 1);
  CALL_IF_PRESENT(IMDSetThreadLocalIsRunningInDatabaseServerProcess, kCFBooleanTrue);
  CALL_IF_PRESENT(IMDEnsureSharedRecordStoreInitialized);
  CALL_IF_PRESENT(IMDSharedSqliteDatabasePath);
  return IMDSharedSqliteDatabase() ? 0 : 4;
}
