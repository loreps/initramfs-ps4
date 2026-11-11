
CC       = musl-gcc
CFLAGS   = -Os -Wall -Wextra
LDFLAGS  = -static

TARGET   = ../../rootfs/bin/reboot
SOURCE   = reboot.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCE)
	mkdir -p $(dir $(TARGET))
	$(CC) $(CFLAGS) $(SOURCE) $(LDFLAGS) -o $@

clean:
	rm -f $(TARGET)

