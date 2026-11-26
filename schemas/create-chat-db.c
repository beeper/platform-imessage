// Guest program for ipswrun: loads the release's IMDPersistence and has it create an empty
// Messages database at the default location in the guest's home, as the first launch would.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <err.h>

// A pointer to the framework's function `name`, NULL if this release doesn't have it.
#define SYM(ret, name, params) ((ret (*)params)dlsym(h, #name))
// Calls it with the arguments `args` if the release has it.
#define TRY(ret, name, params, args) do { ret (*f)params = SYM(ret, name, params); if (f) f args; } while (0)

int main(void) {
  void *h = dlopen("/System/Library/PrivateFrameworks/IMDPersistence.framework/IMDPersistence", RTLD_NOW);
  if (!h) errx(2, "dlopen: %s", dlerror());
  void *(*database)(void) = SYM(void *, IMDSharedSqliteDatabase, (void));
  if (!database) errx(3, "no IMDSharedSqliteDatabase");

  // Newer releases only open the store in the process that owns it (imagent's database server).
  TRY(void, IMDSetIsRunningInDatabaseServerProcess, (int), (1));
  TRY(void, IMDSetThreadLocalIsRunningInDatabaseServerProcess, (CFTypeRef), (kCFBooleanTrue));
  TRY(void, IMDEnsureSharedRecordStoreInitialized, (void), ());
  TRY(CFStringRef, IMDSharedSqliteDatabasePath, (void), ());
  return database() ? 0 : 4;
}
