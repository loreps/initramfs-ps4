CC ?= musl-gcc
CFLAGS ?= -Os -Wall -Wextra -Werror
LDFLAGS ?= -static -s

.PHONY: all clean
all: ../../rootfs/bin/bond-sync

../../rootfs/bin/bond-sync: bond_sync.c
	$(CC) $(CFLAGS) $< $(LDFLAGS) -o $@

clean:
	rm -f ../../rootfs/bin/bond-sync
