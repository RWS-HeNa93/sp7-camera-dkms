# SPDX-License-Identifier: GPL-2.0-only
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: modules clean
