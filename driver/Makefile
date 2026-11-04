# Build helper for the Apple CS8409 module.
#   make                 build against the running kernel (no install)
#   sudo make install    install via DKMS (rebuilds on every kernel update)
#   sudo make uninstall  remove it again; the stock module comes back
NAME    := cs8409-apple
VERSION := 0.9
KVER    ?= $(shell uname -r)
KDIR    ?= /lib/modules/$(KVER)/build
SRCDIR  := /usr/src/$(NAME)-$(VERSION)

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

install: uninstall
	mkdir -p $(SRCDIR)
	cp -r Kbuild dkms.conf src $(SRCDIR)/
	dkms add $(NAME)/$(VERSION)
	dkms install $(NAME)/$(VERSION) -k $(KVER)
	@echo; echo "Installed. Reboot, then run: ../tools/check.sh"

uninstall:
	-@for v in $$(dkms status $(NAME) 2>/dev/null | sed -n 's#^$(NAME)/\([^,]*\),.*#\1#p' | sort -u); do \
		echo "dkms remove $(NAME)/$$v"; dkms remove $(NAME)/$$v --all; done
	rm -rf /usr/src/$(NAME)-*

.PHONY: all clean install uninstall
