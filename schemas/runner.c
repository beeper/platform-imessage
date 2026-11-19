// Guest program for ipswrun: loads the release's IMDPersistence and has it create an empty
// Messages database at the default location in the guest's home, as the first launch would.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

int main(void) {
  void *h = dlopen("/System/Library/PrivateFrameworks/IMDPersistence.framework/IMDPersistence", RTLD_NOW);
  if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
  void *(*database)(void) = dlsym(h, "IMDSharedSqliteDatabase");
  if (!database) { fprintf(stderr, "no IMDSharedSqliteDatabase\n"); return 3; }

  // Newer releases only open the store in the process that owns it (imagent's database server).
  void (*setServer)(int) = dlsym(h, "IMDSetIsRunningInDatabaseServerProcess");
  void (*setServerThread)(CFTypeRef) = dlsym(h, "IMDSetThreadLocalIsRunningInDatabaseServerProcess");
  void (*ensure)(void) = dlsym(h, "IMDEnsureSharedRecordStoreInitialized");
  CFStringRef (*sharedPath)(void) = dlsym(h, "IMDSharedSqliteDatabasePath");
  if (setServer) setServer(1);
  if (setServerThread) setServerThread(kCFBooleanTrue);
  if (ensure) ensure();
  if (sharedPath) sharedPath();
  return database() ? 0 : 4;
}
