
PROGRAM_FILES = /c/Program Files

DO_MAKEFILE_LOCAL := $(shell if test -f ../Makefile.local; then echo yes; fi)

ifeq ($(DO_MAKEFILE_LOCAL),yes)
include ../Makefile.local
endif

ifndef LISPDIR
LISPDIR = /c/acl82.patched
endif

ALLEGRO=$(LISPDIR)/allegro

# Worst directory name ever
ifndef MT
NEWSDK = $(shell if test -d "/c/Program Files/Microsoft SDKs/Windows/v6.0A/bin"; then echo yes; else echo no; fi)
ifeq ($(NEWSDK),yes)
MT="/c/Program Files/Microsoft SDKs/Windows/v6.0A/bin/mt.exe"
else
MT="/c/Program Files/Microsoft Platform SDK for Windows Server 2003 R2/Bin/mt.exe"
endif
endif

build: configure/configure.exe configure.exe.manifest
	$(MT) -manifest configure.exe.manifest -outputresource:configure/configure.exe

configure/configure.exe:
	$(ALLEGRO) -L buildit.cl

clean:
	rm -fr *.fasl configure *.build-dribble 
