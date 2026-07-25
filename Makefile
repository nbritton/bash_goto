# Makefile for goto.sh
#
# NB: the "no external commands" rule in CONTRIBUTING.md applies to the two
# runtimes, not to this file - a Makefile that cannot run a command would
# not be much of a Makefile.

PREFIX  ?= /usr/local
INSTALL ?= install
BINDIR   = $(DESTDIR)$(PREFIX)/bin
MANDIR   = $(DESTDIR)$(PREFIX)/share/man/man1
DOCDIR   = $(DESTDIR)$(PREFIX)/share/doc/goto.sh

VERSION := $(shell sed -n "s/^__GT_VERSION='\(.*\)'$$/\1/p" goto.sh)
DISTNAME = goto.sh-$(VERSION)

DOCS = README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md LICENSE \
       bash-style-guide.md bash-style-guide.PROVENANCE

.DEFAULT_GOAL := help
.PHONY: help all test check fuzz lint bench manpage install uninstall dist clean

help:
	@echo 'targets:'
	@echo '  test       run the QA suite (test/run_tests.sh)'
	@echo '  fuzz       run the randomized harnesses deeply (500 seeds)'
	@echo '  lint       shellcheck all first-party sources'
	@echo '  bench      print benchmark numbers (test/bench.sh)'
	@echo '  manpage    render man/goto.sh.1 to the terminal'
	@echo '  install    install scripts, man pages and docs to $(PREFIX)'
	@echo '  uninstall  remove what install created'
	@echo '  dist       build $(DISTNAME).tar.gz from the git tree'
	@echo '  clean      remove build products'

all: test lint

test:
	bash test/run_tests.sh

check: test

# the seeded fuzzers take a count: a deep run for release checking
fuzz:
	GOTO_FUZZ_N=500 bash test/run_tests.sh t08
	GOTO_FUZZ_N=500 bash test/run_tests.sh t09

lint:
	shellcheck -x -P SCRIPTDIR -S style goto.sh goto_trap.sh \
		examples/*.sh test/*.sh

bench:
	@bash test/bench.sh

manpage:
	@man ./man/goto.sh.1 2> /dev/null || \
		groff -man -Tutf8 man/goto.sh.1

install:
	$(INSTALL) -d '$(BINDIR)' '$(MANDIR)' '$(DOCDIR)'
	$(INSTALL) -m 0755 goto.sh goto_trap.sh '$(BINDIR)/'
	$(INSTALL) -m 0644 man/goto.sh.1 man/goto_trap.sh.1 '$(MANDIR)/'
	$(INSTALL) -m 0644 $(DOCS) '$(DOCDIR)/'

uninstall:
	rm -f '$(BINDIR)/goto.sh' '$(BINDIR)/goto_trap.sh'
	rm -f '$(MANDIR)/goto.sh.1' '$(MANDIR)/goto_trap.sh.1'
	rm -rf '$(DOCDIR)'

dist: clean
	git archive --format=tar.gz --prefix='$(DISTNAME)/' \
		-o '$(DISTNAME).tar.gz' HEAD
	@echo 'wrote $(DISTNAME).tar.gz'

clean:
	rm -f goto.sh-*.tar.gz
