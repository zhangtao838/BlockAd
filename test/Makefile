# 本地单元测试：macOS / Linux 用系统 cc 直接编译，无需 iOS 工具链
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra

all: t_blocklist

t_blocklist: t_blocklist.c ../blocklist.c ../blocklist.h
	$(CC) $(CFLAGS) -o $@ t_blocklist.c ../blocklist.c

test: all
	./t_blocklist

clean:
	rm -f t_blocklist

.PHONY: all test clean