#define _POSIX_C_SOURCE 200809L
#include <ctype.h>
#include <curl/curl.h>
#include <cjson/cJSON.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

enum { MAX_PAYLOAD = 262144, MAX_RESPONSE = 4096, MAX_QUEUE = 10000 };
typedef struct { char data[MAX_RESPONSE + 1]; size_t used; } Receipt;

static int identifier(const char *s, size_t maximum) {
    if (!s || !*s || strlen(s) > maximum) return 0;
    for (; *s; ++s)
        if (!isalnum((unsigned char)*s) && *s != '_' && *s != '-' && *s != '.') return 0;
    return 1;
}

static char *read_file(const char *path, size_t maximum) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    struct stat info;
    if (fd < 0) return NULL;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        (unsigned long long)info.st_size > maximum) {
        close(fd); errno = EINVAL; return NULL;
    }
    size_t length = (size_t)info.st_size, used = 0;
    char *data = malloc(length + 1);
    if (!data) { close(fd); return NULL; }
    while (used < length) {
        ssize_t count = read(fd, data + used, length - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { free(data); close(fd); errno = EIO; return NULL; }
        used += (size_t)count;
    }
    close(fd); data[length] = 0;
    if (memchr(data, 0, length)) { free(data); errno = EINVAL; return NULL; }
    return data;
}

static cJSON *parse_object(const char *data) {
    if (!data) return NULL;
    cJSON *value = cJSON_ParseWithLengthOpts(data, strlen(data) + 1, NULL, 1);
    if (!cJSON_IsObject(value)) { cJSON_Delete(value); return NULL; }
    return value;
}

static int path_join(char path[4096], const char *directory, const char *name) {
    return snprintf(path, 4096, "%s/%s", directory, name) < 4096;
}

static int lock_queue(const char *directory, int *directory_fd) {
    if (mkdir(directory, 0700) && errno != EEXIST) return -1;
    *directory_fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (*directory_fd < 0) return -1;
    int fd = openat(*directory_fd, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (fd < 0 || flock(fd, LOCK_EX)) {
        if (fd >= 0) close(fd);
        close(*directory_fd); return -1;
    }
    return fd;
}

static int write_atomic(const char *directory, int directory_fd, const char *name, const char *data) {
    char destination[4096], temporary[4096];
    if (!path_join(destination, directory, name) || !path_join(temporary, directory, ".tmp-XXXXXX")) return -1;
    char *previous = read_file(destination, MAX_PAYLOAD);
    if (previous) {
        int same = !strcmp(previous, data); free(previous);
        if (!same) errno = EEXIST;
        return same ? 0 : -1;
    }
    if (errno != ENOENT) return -1;
    int fd = mkstemp(temporary);
    if (fd < 0) return -1;
    size_t used = 0, length = strlen(data);
    int result = 0;
    while (used < length) {
        ssize_t count = write(fd, data + used, length - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { result = -1; break; }
        used += (size_t)count;
    }
    if (!result && fsync(fd)) result = -1;
    if (close(fd)) result = -1;
    if (!result && rename(temporary, destination)) result = -1;
    if (!result && fsync(directory_fd)) result = -1;
    if (result) unlink(temporary);
    return result;
}

static int queued_file(const struct dirent *entry) {
    size_t size = strlen(entry->d_name);
    return size > 5 && !strcmp(entry->d_name + size - 5, ".json");
}

static int queue_count(const char *directory) {
    struct dirent **entries = NULL;
    int count = scandir(directory, &entries, queued_file, alphasort);
    if (count >= 0) {
        for (int i = 0; i < count; ++i) free(entries[i]);
        free(entries);
    }
    return count;
}

static int enqueue(const char *directory, const char *project, const char *file) {
    if (!identifier(project, 100)) return 2;
    char *source = read_file(file, 196608);
    cJSON *result = parse_object(source);
    free(source);
    if (!result) { fprintf(stderr, "a bounded JSON object is required\n"); return 2; }
    cJSON *body = cJSON_CreateObject();
    if (!body) { cJSON_Delete(result); return 2; }
    cJSON_AddStringToObject(body, "project", project);
    cJSON_AddStringToObject(body, "kind", "report");
    cJSON_AddItemToObject(body, "result", result);
    cJSON_AddArrayToObject(body, "events");
    char *encoded = cJSON_PrintUnformatted(body);
    unsigned char digest[32]; unsigned length = 0;
    if (!encoded || EVP_Digest(encoded, strlen(encoded), digest, &length, EVP_sha256(), NULL) != 1 || length != 32) {
        cJSON_free(encoded); cJSON_Delete(body); return 2;
    }
    char key[65];
    for (unsigned i = 0; i < 32; ++i) snprintf(key + 2 * i, 3, "%02x", digest[i]);
    cJSON_free(encoded);
    cJSON_AddStringToObject(body, "clientKey", key);
    encoded = cJSON_PrintUnformatted(body); cJSON_Delete(body);
    if (!encoded || strlen(encoded) > MAX_PAYLOAD) { cJSON_free(encoded); return 2; }
    int directory_fd = -1, lock = lock_queue(directory, &directory_fd);
    if (lock < 0) { cJSON_free(encoded); perror("queue"); return 2; }
    int count = queue_count(directory), status = 2;
    char name[80], destination[4096];
    snprintf(name, sizeof name, "%s.json", key);
    if (count >= 0 && path_join(destination, directory, name) &&
        (count < MAX_QUEUE || faccessat(directory_fd, name, F_OK, AT_SYMLINK_NOFOLLOW) == 0) &&
        write_atomic(directory, directory_fd, name, encoded) == 0) {
        printf("{\"queued\":\"%s\"}\n", key); status = 0;
    } else perror("enqueue");
    cJSON_free(encoded); close(lock); close(directory_fd); return status;
}

static size_t receive(void *data, size_t size, size_t count, void *context) {
    Receipt *receipt = context;
    if (size && count > MAX_RESPONSE / size) return 0;
    size_t length = size * count;
    if (length > MAX_RESPONSE - receipt->used) return 0;
    memcpy(receipt->data + receipt->used, data, length);
    receipt->used += length; receipt->data[receipt->used] = 0;
    return length;
}

static int confirmed(const char *response, const char *key) {
    cJSON *body = parse_object(response);
    if (!body) return 0;
    const cJSON *persisted = cJSON_GetObjectItemCaseSensitive(body, "persisted");
    const cJSON *client_key = cJSON_GetObjectItemCaseSensitive(body, "clientKey");
    int accepted = cJSON_IsTrue(persisted) && cJSON_IsString(client_key) &&
                   !strcmp(client_key->valuestring, key);
    int fields = 0;
    for (const cJSON *item = body->child; item; item = item->next)
        if (item->string && (!strcmp(item->string, "persisted") || !strcmp(item->string, "clientKey"))) ++fields;
    cJSON_Delete(body); return accepted && fields == 2;
}

static int endpoint_valid(const char *endpoint) {
    CURLU *url = curl_url();
    if (!url) return 0;
    char *scheme = NULL, *host = NULL, *user = NULL, *password = NULL;
    int ok = endpoint && curl_url_set(url, CURLUPART_URL, endpoint, 0) == CURLUE_OK &&
             curl_url_get(url, CURLUPART_SCHEME, &scheme, 0) == CURLUE_OK &&
             !strcmp(scheme, "https") && curl_url_get(url, CURLUPART_HOST, &host, 0) == CURLUE_OK && *host &&
             curl_url_get(url, CURLUPART_USER, &user, 0) == CURLUE_NO_USER &&
             curl_url_get(url, CURLUPART_PASSWORD, &password, 0) == CURLUE_NO_PASSWORD;
    curl_free(scheme); curl_free(host); curl_free(user); curl_free(password); curl_url_cleanup(url);
    return ok;
}

static int sync_queue(const char *directory, const char *endpoint, const char *token) {
    if (!endpoint_valid(endpoint) || !identifier(token, 8192)) {
        fprintf(stderr, "HTTPS endpoint and a session token are required\n"); return 2;
    }
    int directory_fd = -1, lock = lock_queue(directory, &directory_fd);
    if (lock < 0) return 2;
    struct dirent **entries = NULL;
    int count = scandir(directory, &entries, queued_file, alphasort), sent = 0, failed = 0;
    if (count < 0) { close(lock); close(directory_fd); return 2; }
    for (int i = 0; i < count && i < 100; ++i) {
        char path[4096];
        if (!path_join(path, directory, entries[i]->d_name)) { failed++; break; }
        char *payload = read_file(path, MAX_PAYLOAD);
        cJSON *body = parse_object(payload);
        const cJSON *key_value = body ? cJSON_GetObjectItemCaseSensitive(body, "clientKey") : NULL;
        if (!cJSON_IsString(key_value) || !identifier(key_value->valuestring, 128)) {
            cJSON_Delete(body); free(payload); failed++; break;
        }
        CURL *handle = curl_easy_init(); Receipt receipt = {{0}, 0};
        char authorization[8220];
        snprintf(authorization, sizeof authorization, "Authorization: Bearer %s", token);
        struct curl_slist *headers = curl_slist_append(NULL, "Content-Type: application/json");
        headers = curl_slist_append(headers, authorization);
        long status = 0; CURLcode error = CURLE_FAILED_INIT;
        if (handle) {
            curl_easy_setopt(handle, CURLOPT_URL, endpoint);
            curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);
            curl_easy_setopt(handle, CURLOPT_POSTFIELDS, payload);
            curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE, (long)strlen(payload));
            curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, 5L);
            curl_easy_setopt(handle, CURLOPT_TIMEOUT, 15L);
            curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 0L);
            curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
            curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, receive);
            curl_easy_setopt(handle, CURLOPT_WRITEDATA, &receipt);
            error = curl_easy_perform(handle);
            curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status);
            curl_easy_cleanup(handle);
        }
        int accepted = error == CURLE_OK && status >= 200 && status < 300 && confirmed(receipt.data, key_value->valuestring);
        cJSON_Delete(body); free(payload); curl_slist_free_all(headers);
        if (!accepted || unlinkat(directory_fd, entries[i]->d_name, 0) || fsync(directory_fd)) { failed++; break; }
        sent++;
    }
    for (int i = 0; i < count; ++i) free(entries[i]);
    free(entries);
    printf("{\"sent\":%d,\"failed\":%d,\"pending\":%d}\n", sent, failed, queue_count(directory));
    close(lock); close(directory_fd); return failed ? 1 : 0;
}

#ifndef ARCHIVE_TEST
int main(int argc, char **argv) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) return 2;
    int status = 2;
    if (argc == 5 && !strcmp(argv[1], "enqueue")) status = enqueue(argv[2], argv[3], argv[4]);
    else if (argc == 3 && !strcmp(argv[1], "sync"))
        status = sync_queue(argv[2], getenv("BRUNNODEV_API_URL"), getenv("BRUNNODEV_ACCESS_TOKEN"));
    else fprintf(stderr, "archive enqueue DIRECTORY PROJECT RESULT.json | archive sync DIRECTORY\n");
    curl_global_cleanup(); return status;
}
#endif
