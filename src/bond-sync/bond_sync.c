#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define CAPTURE_MAGIC "BONDREC1"
#define CAPTURE_VERSION 1
#define CAPTURE_SLOT_COUNT 32u
#define CAPTURE_RECORD_SIZE 1000u
#define CAPTURE_HEADER_SIZE 32u
#define CAPTURE_SLOT_SIZE 1008u
#define CAPTURE_SIZE (CAPTURE_HEADER_SIZE + CAPTURE_SLOT_COUNT * CAPTURE_SLOT_SIZE)

#define HEADER_VERSION 8
#define HEADER_FIRMWARE 12
#define HEADER_SLOT_COUNT 16
#define HEADER_RECORD_SIZE 20
#define HEADER_SUCCESSFUL_READS 24
#define HEADER_RESERVED 28

#define SLOT_REGISTRY_KEY 0
#define SLOT_READ_STATUS 4
#define SLOT_RECORD 8

#define FIRST_REGISTRY_KEY 0x12010100u
#define REGISTRY_KEY_STEP 0x10000u

#define RECORD_DEVICE_ADDRESS 0x00
#define RECORD_ADDRESS_PADDING 0x06
#define RECORD_LINK_KEY 0x10
#define RECORD_FLAGS 0x24
#define RECORD_VENDOR_ID 0x28
#define RECORD_PRODUCT_ID 0x2a
#define RECORD_TYPE 0x2f

#define RECORD_FLAG_LINK_KEY_VALID 0x2000u
#define RECORD_TYPE_DS4 2
#define DS4_VENDOR_ID 0x054c
#define DS4_PRODUCT_ID_V1 0x05c4
#define DS4_PRODUCT_ID_V2 0x09cc

#define ADDRESS_SIZE 6
#define LINK_KEY_SIZE 16
#define ADDRESS_TEXT_SIZE 18
#define LINK_KEY_TEXT_LENGTH 32

#define INFO_FILE_NAME "info"
#define INFO_BACKUP_NAME "info.before-bond-sync"
#define INFO_FILE_LIMIT 65536u
#define INFO_KEY_LINE "Key="
#define INFO_TYPE_LINE "Type="
#define INFO_LINK_KEY_SECTION "[LinkKey]"
#define INFO_LINK_KEY_TYPE '4'
#define TEMP_NAME_ATTEMPTS 100

#define BTPROTO_HCI 1
#define HCI_GET_DEVICE_LIST _IOR('H', 210, int)
#define HCI_GET_DEVICE_INFO _IOR('H', 211, int)
#define HCI_LIST_CAPACITY 2

#define OPEN_DIR_FLAGS (O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
#define CREATE_FILE_FLAGS (O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW)

enum exit_status {
    STATUS_OK = 0,
    STATUS_ERROR = 1,
    STATUS_USAGE = 2,
    STATUS_NO_MATCH = 3,
};

enum capture_load {
    CAPTURE_INVALID = -1,
    CAPTURE_LOADED = 0,
    CAPTURE_MISSING = 1,
};

enum adapter_lookup {
    ADAPTER_ERROR = -1,
    ADAPTER_NOT_SINGLE = 0,
    ADAPTER_FOUND = 1,
};

enum sync_result {
    SYNC_FAILED = -1,
    SYNC_SKIPPED = 0,
    SYNC_ALREADY_SET = 1,
    SYNC_UPDATED = 2,
};

struct bond_entry {
    char address[ADDRESS_TEXT_SIZE];
    char link_key[LINK_KEY_TEXT_LENGTH + 1];
};

struct hci_device {
    uint16_t id;
    uint32_t options;
};

struct hci_device_list {
    uint16_t count;
    struct hci_device devices[HCI_LIST_CAPACITY];
};

struct hci_device_info {
    uint16_t id;
    char name[8];
    unsigned char address[ADDRESS_SIZE];
    uint32_t rest[64];
};

static uint32_t read_le32(const unsigned char *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t read_le16(const unsigned char *p)
{
    return (uint16_t)p[0] | (uint16_t)p[1] << 8;
}

static int all_zero(const unsigned char *p, size_t length)
{
    for (size_t i = 0; i < length; i++)
        if (p[i])
            return 0;
    return 1;
}

static int read_all(int fd, void *buffer, size_t length)
{
    unsigned char *p = buffer;
    while (length) {
        ssize_t n = read(fd, p, length);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return -1;
        p += n;
        length -= (size_t)n;
    }
    return 0;
}

static int write_all(int fd, const void *buffer, size_t length)
{
    const unsigned char *p = buffer;
    while (length) {
        ssize_t n = write(fd, p, length);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return -1;
        p += n;
        length -= (size_t)n;
    }
    return 0;
}

static void format_address(char out[ADDRESS_TEXT_SIZE], const unsigned char *bytes)
{
    snprintf(out, ADDRESS_TEXT_SIZE, "%02X:%02X:%02X:%02X:%02X:%02X",
             bytes[5], bytes[4], bytes[3], bytes[2], bytes[1], bytes[0]);
}

static void format_link_key(char out[LINK_KEY_TEXT_LENGTH + 1], const unsigned char *key)
{
    const char digits[] = "0123456789ABCDEF";
    for (unsigned i = 0; i < LINK_KEY_SIZE; i++) {
        out[i * 2] = digits[key[i] >> 4];
        out[i * 2 + 1] = digits[key[i] & 15];
    }
    out[LINK_KEY_TEXT_LENGTH] = 0;
}

static int address_valid(const char *text)
{
    if (strlen(text) != ADDRESS_TEXT_SIZE - 1)
        return 0;
    for (int i = 0; i < ADDRESS_TEXT_SIZE - 1; i++) {
        int separator = i % 3 == 2;
        if (separator ? text[i] != ':' : !isxdigit((unsigned char)text[i]))
            return 0;
    }
    return strcmp(text, "00:00:00:00:00:00") != 0;
}

static const uint32_t supported_firmwares[] = { 900, 903, 904, 950, 951, 960, 1000, 1001, 1050, 1070, 1071, 1100, 1102, 1150, 1152, 1200, 1202, 1250, 1252, 1300, 1302, 1304, 1350, 1352, 1400, 1402 };

static int firmware_supported(uint32_t firmware)
{
    for (size_t i = 0; i < sizeof(supported_firmwares) / sizeof(supported_firmwares[0]); i++)
        if (supported_firmwares[i] == firmware)
            return 1;
    return 0;
}

static int capture_header_valid(const unsigned char *capture)
{
    return !memcmp(capture, CAPTURE_MAGIC, 8) &&
           read_le32(capture + HEADER_VERSION) == CAPTURE_VERSION &&
           firmware_supported(read_le32(capture + HEADER_FIRMWARE)) &&
           read_le32(capture + HEADER_SLOT_COUNT) == CAPTURE_SLOT_COUNT &&
           read_le32(capture + HEADER_RECORD_SIZE) == CAPTURE_RECORD_SIZE &&
           read_le32(capture + HEADER_RESERVED) == 0;
}

static int record_is_ds4_bond(const unsigned char *record)
{
    uint16_t product = read_le16(record + RECORD_PRODUCT_ID);

    if (!(read_le32(record + RECORD_FLAGS) & RECORD_FLAG_LINK_KEY_VALID))
        return 0;
    if (read_le16(record + RECORD_VENDOR_ID) != DS4_VENDOR_ID)
        return 0;
    if (product != DS4_PRODUCT_ID_V1 && product != DS4_PRODUCT_ID_V2)
        return 0;
    if (record[RECORD_TYPE] != RECORD_TYPE_DS4)
        return 0;
    if (record[RECORD_ADDRESS_PADDING] || record[RECORD_ADDRESS_PADDING + 1])
        return 0;
    return !all_zero(record + RECORD_DEVICE_ADDRESS, ADDRESS_SIZE) &&
           !all_zero(record + RECORD_LINK_KEY, LINK_KEY_SIZE);
}

static int address_listed(const struct bond_entry *entries, size_t count, const char *address)
{
    for (size_t i = 0; i < count; i++)
        if (!strcmp(entries[i].address, address))
            return 1;
    return 0;
}

static int parse_capture(const unsigned char *capture, struct bond_entry *entries, size_t *count)
{
    uint32_t successful_reads = 0;

    if (!capture_header_valid(capture))
        return -1;

    *count = 0;
    for (unsigned i = 0; i < CAPTURE_SLOT_COUNT; i++) {
        const unsigned char *slot = capture + CAPTURE_HEADER_SIZE + i * CAPTURE_SLOT_SIZE;
        const unsigned char *record = slot + SLOT_RECORD;

        if (read_le32(slot + SLOT_REGISTRY_KEY) != FIRST_REGISTRY_KEY + i * REGISTRY_KEY_STEP)
            return -1;
        if (read_le32(slot + SLOT_READ_STATUS)) {
            if (!all_zero(record, CAPTURE_RECORD_SIZE))
                return -1;
            continue;
        }
        successful_reads++;
        if (!record_is_ds4_bond(record))
            continue;

        struct bond_entry *entry = &entries[*count];
        format_address(entry->address, record + RECORD_DEVICE_ADDRESS);
        if (address_listed(entries, *count, entry->address))
            return -1;
        format_link_key(entry->link_key, record + RECORD_LINK_KEY);
        (*count)++;
    }

    if (!successful_reads || successful_reads != read_le32(capture + HEADER_SUCCESSFUL_READS))
        return -1;
    return 0;
}

static int load_capture(const char *path, struct bond_entry *entries, size_t *count)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return errno == ENOENT ? CAPTURE_MISSING : CAPTURE_INVALID;

    unsigned char *capture = malloc(CAPTURE_SIZE);
    struct stat st;
    int result = CAPTURE_INVALID;

    if (capture && !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_size == CAPTURE_SIZE &&
        !read_all(fd, capture, CAPTURE_SIZE) && !parse_capture(capture, entries, count))
        result = CAPTURE_LOADED;

    close(fd);
    if (capture) {
        explicit_bzero(capture, CAPTURE_SIZE);
        free(capture);
    }
    return result;
}

static int open_child_dir(int parent, const char *name)
{
    return openat(parent, name, OPEN_DIR_FLAGS);
}

static int line_starts_with(const char *line, size_t length, const char *prefix)
{
    size_t prefix_length = strlen(prefix);
    return length >= prefix_length && !memcmp(line, prefix, prefix_length);
}

static int find_link_key(const char *data, size_t length, size_t *key_offset)
{
    size_t pos = 0;
    int in_link_key_section = 0;
    unsigned link_key_sections = 0, key_lines = 0, type_lines = 0;

    while (pos < length) {
        size_t start = pos;
        while (pos < length && data[pos] != '\n')
            pos++;
        size_t end = pos;
        if (pos < length)
            pos++;
        if (end > start && data[end - 1] == '\r')
            end--;

        const char *line = data + start;
        size_t line_length = end - start;

        if (line_length && line[0] == '[') {
            in_link_key_section = line_length == strlen(INFO_LINK_KEY_SECTION) &&
                                  !memcmp(line, INFO_LINK_KEY_SECTION, line_length);
            if (in_link_key_section)
                link_key_sections++;
        } else if (in_link_key_section && line_starts_with(line, line_length, INFO_KEY_LINE)) {
            if (line_length != strlen(INFO_KEY_LINE) + LINK_KEY_TEXT_LENGTH)
                return -1;
            for (size_t i = strlen(INFO_KEY_LINE); i < line_length; i++)
                if (!isxdigit((unsigned char)line[i]))
                    return -1;
            *key_offset = start + strlen(INFO_KEY_LINE);
            key_lines++;
        } else if (in_link_key_section && line_starts_with(line, line_length, INFO_TYPE_LINE)) {
            if (line_length != strlen(INFO_TYPE_LINE) + 1 ||
                line[strlen(INFO_TYPE_LINE)] != INFO_LINK_KEY_TYPE)
                return -1;
            type_lines++;
        }
    }

    return link_key_sections == 1 && key_lines == 1 && type_lines == 1 ? 0 : -1;
}

static int save_backup(int device_dir, const char *data, size_t length)
{
    int backup = openat(device_dir, INFO_BACKUP_NAME, CREATE_FILE_FLAGS, 0600);

    if (backup >= 0) {
        int failed = write_all(backup, data, length) || fsync(backup);
        if (close(backup))
            failed = 1;
        if (failed)
            unlinkat(device_dir, INFO_BACKUP_NAME, 0);
        return failed ? -1 : 0;
    }
    if (errno != EEXIST)
        return -1;

    struct stat existing;
    if (fstatat(device_dir, INFO_BACKUP_NAME, &existing, AT_SYMLINK_NOFOLLOW))
        return -1;
    return S_ISREG(existing.st_mode) && !(existing.st_mode & 077) ? 0 : -1;
}

static int replace_info(int device_dir, const struct stat *original, const char *data, size_t length)
{
    char temporary[64];
    int out = -1;

    for (unsigned attempt = 0; attempt < TEMP_NAME_ATTEMPTS; attempt++) {
        snprintf(temporary, sizeof(temporary), ".bond-sync-%ld-%u", (long)getpid(), attempt);
        out = openat(device_dir, temporary, CREATE_FILE_FLAGS, 0600);
        if (out >= 0 || errno != EEXIST)
            break;
    }
    if (out < 0)
        return -1;

    int failed = fchown(out, original->st_uid, original->st_gid) ||
                 fchmod(out, original->st_mode & 0600) ||
                 write_all(out, data, length) || fsync(out);
    if (close(out))
        failed = 1;
    if (failed || renameat(device_dir, temporary, device_dir, INFO_FILE_NAME)) {
        unlinkat(device_dir, temporary, 0);
        return -1;
    }
    return fsync(device_dir) ? -1 : 0;
}

static int sync_device(int adapter_dir, const struct bond_entry *entry)
{
    int device_dir = open_child_dir(adapter_dir, entry->address);
    if (device_dir < 0)
        return errno == ENOENT ? SYNC_SKIPPED : SYNC_FAILED;

    int fd = openat(device_dir, INFO_FILE_NAME, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        int result = errno == ENOENT ? SYNC_SKIPPED : SYNC_FAILED;
        close(device_dir);
        return result;
    }

    struct stat st;
    char *data = NULL;
    size_t length = 0;
    size_t key_offset = 0;
    int result = SYNC_FAILED;

    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        (uint64_t)st.st_size > INFO_FILE_LIMIT)
        goto done;
    length = (size_t)st.st_size;
    data = malloc(length);
    if (!data || read_all(fd, data, length))
        goto done;

    if (find_link_key(data, length, &key_offset)) {
        result = SYNC_SKIPPED;
        goto done;
    }
    if (!strncasecmp(data + key_offset, entry->link_key, LINK_KEY_TEXT_LENGTH)) {
        result = SYNC_ALREADY_SET;
        goto done;
    }
    if (save_backup(device_dir, data, length))
        goto done;
    memcpy(data + key_offset, entry->link_key, LINK_KEY_TEXT_LENGTH);
    if (replace_info(device_dir, &st, data, length))
        goto done;
    result = SYNC_UPDATED;

done:
    if (data) {
        explicit_bzero(data, length);
        free(data);
    }
    close(fd);
    close(device_dir);
    return result;
}

static int open_bluetooth_state(const char *root_path)
{
    int root = open(root_path, OPEN_DIR_FLAGS);
    if (root < 0)
        return -1;

    int var = open_child_dir(root, "var");
    int lib = var < 0 ? -1 : open_child_dir(var, "lib");
    int bluetooth = lib < 0 ? -1 : open_child_dir(lib, "bluetooth");

    if (var >= 0)
        close(var);
    if (lib >= 0)
        close(lib);
    close(root);
    return bluetooth;
}

static int find_single_adapter(char address[ADDRESS_TEXT_SIZE])
{
    int hci = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
    if (hci < 0)
        return ADAPTER_ERROR;

    struct hci_device_list list = { .count = HCI_LIST_CAPACITY };
    int result = ADAPTER_NOT_SINGLE;

    if (ioctl(hci, HCI_GET_DEVICE_LIST, &list)) {
        result = ADAPTER_ERROR;
    } else if (list.count == 1) {
        struct hci_device_info info = { .id = list.devices[0].id };
        if (ioctl(hci, HCI_GET_DEVICE_INFO, &info)) {
            result = ADAPTER_ERROR;
        } else {
            format_address(address, info.address);
            result = address_valid(address) ? ADAPTER_FOUND : ADAPTER_ERROR;
        }
    }

    close(hci);
    return result;
}

static unsigned sync_adapter(int bluetooth_dir, const char *adapter_address,
                             const struct bond_entry *entries, size_t count, unsigned *matched)
{
    int adapter_dir = open_child_dir(bluetooth_dir, adapter_address);
    if (adapter_dir < 0)
        return errno == ENOENT ? 0 : 1;

    unsigned errors = 0;
    for (size_t i = 0; i < count; i++) {
        int result = sync_device(adapter_dir, &entries[i]);
        if (result == SYNC_FAILED)
            errors++;
        else if (result != SYNC_SKIPPED)
            (*matched)++;
    }

    close(adapter_dir);
    return errors;
}

static int sync_into_root(const char *root_path, const struct bond_entry *entries, size_t count)
{
    int bluetooth_dir = open_bluetooth_state(root_path);
    if (bluetooth_dir < 0)
        return STATUS_ERROR;

    char adapter_address[ADDRESS_TEXT_SIZE] = {0};
    unsigned errors = 0, matched = 0;
    int adapter = find_single_adapter(adapter_address);

    if (adapter == ADAPTER_ERROR)
        errors++;
    else if (adapter == ADAPTER_FOUND)
        errors += sync_adapter(bluetooth_dir, adapter_address, entries, count, &matched);

    close(bluetooth_dir);
    if (errors)
        return STATUS_ERROR;
    return count && !matched ? STATUS_NO_MATCH : STATUS_OK;
}

int main(int argc, char **argv)
{
    int check_only = argc == 3 && !strcmp(argv[1], "--check");
    if (!check_only && argc != 3)
        return STATUS_USAGE;

    const char *capture_path = check_only ? argv[2] : argv[1];
    struct bond_entry entries[CAPTURE_SLOT_COUNT] = {0};
    size_t count = 0;
    int status;

    int loaded = load_capture(capture_path, entries, &count);
    if (loaded == CAPTURE_MISSING)
        status = STATUS_OK;
    else if (loaded == CAPTURE_INVALID)
        status = STATUS_ERROR;
    else if (check_only)
        status = count ? STATUS_OK : STATUS_NO_MATCH;
    else
        status = sync_into_root(argv[2], entries, count);

    explicit_bzero(entries, sizeof(entries));
    return status;
}
