/* PR0 link smoke: hermetic host C + BCR libgit2 (GIT.md).
 * HTTPS/SSH backends remain off at the BCR pin — do not enable here. */

#include "git2.h"

#include <stdio.h>
#include <string.h>

int main(void) {
  int err = git_libgit2_init();
  if (err < 0) {
    const git_error *e = git_error_last();
    fprintf(stderr, "git_libgit2_init failed: %s\n",
            e && e->message ? e->message : "unknown");
    return 1;
  }

  int major = 0, minor = 0, rev = 0;
  git_libgit2_version(&major, &minor, &rev);
  printf("libgit2 %d.%d.%d (features=0x%x)\n", major, minor, rev,
         git_libgit2_features());

  /* Expect 1.9.x pin. */
  if (major != 1 || minor != 9) {
    fprintf(stderr, "unexpected libgit2 version (want 1.9.x)\n");
    git_libgit2_shutdown();
    return 1;
  }

  git_libgit2_shutdown();
  return 0;
}
