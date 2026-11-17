#include "macremote_capture_logical.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void)
{
    char temp[] = "/tmp/macremote-logical-test-XXXXXX";
    char* root = mkdtemp(temp);
    assert(root);
    char* previous = getenv("HOME") ? strdup(getenv("HOME")) : NULL;
    assert(setenv("HOME", root, 1) == 0);
    char path[PATH_MAX], dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/Library", root);
    assert(mkdir(dir, 0700) == 0);
    snprintf(dir, sizeof(dir), "%s/Library/Application Support", root);
    assert(mkdir(dir, 0700) == 0);
    snprintf(dir, sizeof(dir), "%s/Library/Application Support/MacRemote", root);
    assert(mkdir(dir, 0700) == 0);
    snprintf(path, sizeof(path), "%s/capture-logical.conf", dir);

    CGRect bounds = CGRectMake(0, 0, 2304, 1296);
    assert(!mr_capture_override_bounds(42, &bounds));
    assert(bounds.size.width == 2304);

    FILE* f = fopen(path, "w");
    assert(f);
    fputs("42 1920 1080\n", f);
    fclose(f);
    assert(!mr_capture_override_bounds(43, &bounds));
    assert(mr_capture_override_bounds(42, &bounds));
    assert(bounds.size.width == 1920 && bounds.size.height == 1080);

    f = fopen(path, "w");
    assert(f);
    fputs("42 10000 0\n", f);
    fclose(f);
    assert(!mr_capture_override_bounds(42, &bounds));
    assert(bounds.size.width == 1920 && bounds.size.height == 1080);
    assert(unlink(path) == 0);
    assert(rmdir(dir) == 0);
    snprintf(dir, sizeof(dir), "%s/Library/Application Support", root);
    assert(rmdir(dir) == 0);
    snprintf(dir, sizeof(dir), "%s/Library", root);
    assert(rmdir(dir) == 0);
    assert(rmdir(root) == 0);
    if (previous) { assert(setenv("HOME", previous, 1) == 0); free(previous); }
    else assert(unsetenv("HOME") == 0);
    puts("capture logical bounds manifest: all checks passed");
    return 0;
}
