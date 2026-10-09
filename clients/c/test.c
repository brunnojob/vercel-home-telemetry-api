#define ARCHIVE_TEST
#include "archive.c"
#include <assert.h>

int main(void) {
    assert(curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK);
    assert(confirmed("{\"persisted\":true,\"clientKey\":\"one\"}", "one"));
    assert(!confirmed("{\"persisted\":true,\"clientKey\":\"two\"}", "one"));
    assert(!confirmed("{\"persisted\":true,\"clientKey\":\"one\",\"persisted\":false}", "one"));
    assert(!confirmed("{\"nested\":{\"persisted\":true},\"clientKey\":\"one\"}", "one"));
    assert(!confirmed("{\"persisted\":true,\"clientKey\":\"one\"} garbage", "one"));
    assert(endpoint_valid("https://example.com/api/runs"));
    assert(!endpoint_valid("https://user:secret@example.com/api/runs"));
    assert(!endpoint_valid("http://example.com/api/runs"));
    assert(!identifier("token\r\nInjected: value", 8192));
    char directory[] = "/tmp/archive-test-XXXXXX";
    assert(mkdtemp(directory));
    char result[4096]; assert(path_join(result, directory, "result.txt"));
    FILE *file = fopen(result, "w"); assert(file);
    assert(fputs("{\"temperature\":22.5}", file) >= 0); assert(!fclose(file));
    assert(!enqueue(directory, "industrial-iot-sentinel", result));
    assert(!enqueue(directory, "industrial-iot-sentinel", result));
    assert(queue_count(directory) == 1);
    assert(enqueue(directory, "../outside", result) == 2);
    struct dirent **entries = NULL;
    int count = scandir(directory, &entries, queued_file, alphasort);
    for (int i = 0; i < count; ++i) {
        char path[4096]; assert(path_join(path, directory, entries[i]->d_name));
        assert(!unlink(path)); free(entries[i]);
    }
    free(entries); assert(!unlink(result));
    assert(path_join(result, directory, ".lock")); assert(!unlink(result)); assert(!rmdir(directory));
    curl_global_cleanup();
}
