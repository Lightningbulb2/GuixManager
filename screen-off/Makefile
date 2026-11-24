# screen-off: needs a C compiler, pkg-config, wayland (wayland-scanner,
# wayland-client), wayland-protocols and wlr-protocols.
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
PKG_CONFIG ?= pkg-config
WAYLAND_PROTOCOLS = $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols)
WLR_PROTOCOLS = $(shell $(PKG_CONFIG) --variable=pkgdatadir wlr-protocols)
IDLE_XML = $(WAYLAND_PROTOCOLS)/staging/ext-idle-notify/ext-idle-notify-v1.xml
POWER_XML = $(WLR_PROTOCOLS)/unstable/wlr-output-power-management-unstable-v1.xml
GENERATED = ext-idle-notify-v1-client-protocol.h ext-idle-notify-v1.c \
	wlr-output-power-management-unstable-v1-client-protocol.h \
	wlr-output-power-management-unstable-v1.c

screen-off: screen-off.c $(GENERATED)
	$(CC) $(CFLAGS) -o $@ screen-off.c ext-idle-notify-v1.c \
	  wlr-output-power-management-unstable-v1.c \
	  $$($(PKG_CONFIG) --cflags --libs wayland-client)

ext-idle-notify-v1-client-protocol.h: $(IDLE_XML)
	wayland-scanner client-header $< $@
ext-idle-notify-v1.c: $(IDLE_XML)
	wayland-scanner private-code $< $@
wlr-output-power-management-unstable-v1-client-protocol.h: $(POWER_XML)
	wayland-scanner client-header $< $@
wlr-output-power-management-unstable-v1.c: $(POWER_XML)
	wayland-scanner private-code $< $@

clean:
	rm -f screen-off $(GENERATED)

.PHONY: clean
