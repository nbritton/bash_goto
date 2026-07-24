# Makefile for goto.sh

PREFIX ?= /usr/local
BINDIR  = $(DESTDIR)$(PREFIX)/bin
MANDIR  = $(DESTDIR)$(PREFIX)/share/man/man1

.PHONY: help test check lint install uninstall

help:
	@echo 'targets:'
	@echo '  test       run the QA suite (test/run_tests.sh)'
	@echo '  lint       shellcheck all first-party sources'
	@echo '  install    install scripts and man pages (PREFIX=$(PREFIX))'
	@echo '  uninstall  remove installed files'

test:
	bash test/run_tests.sh

check: test

lint:
	shellcheck -x -P SCRIPTDIR -S style goto.sh goto_trap.sh \
		examples/*.sh test/*.sh

install:
	install -d '$(BINDIR)' '$(MANDIR)'
	install -m 0755 goto.sh goto_trap.sh '$(BINDIR)/'
	install -m 0644 man/goto.sh.1 man/goto_trap.sh.1 '$(MANDIR)/'

uninstall:
	rm -f '$(BINDIR)/goto.sh' '$(BINDIR)/goto_trap.sh'
	rm -f '$(MANDIR)/goto.sh.1' '$(MANDIR)/goto_trap.sh.1'
