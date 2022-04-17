VERSION := $(shell cat VERSION)
RELEASE_BRANCH := master

SCRIPTS := libvirt-cloud-instance.sh secure-block-overlay.sh

PREFIX := /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
SHAREDIR = $(PREFIX)/share
DOCSDIR = $(SHAREDIR)/doc
MANDIR = $(SHAREDIR)/man

.PHONY: install clean uninstall release sdist rpm

all: build

clean:
	rm -f automated-ops-scripts-config.sh
	rm -f lib/automated-ops-scripts.sh
	rm -rf bdist sdist

automated-ops-scripts-config.sh: automated-ops-scripts-config.sh.in
	sed -e 's~@LIBDIR@~$(LIBDIR)/automated-ops-scripts~g' -e 's~@VERSION@~$(VERSION)~g' automated-ops-scripts-config.sh.in >automated-ops-scripts-config.sh

lib/automated-ops-scripts.sh: lib/automated-ops-scripts.sh.in
	sed -e 's~@VERSION@~$(VERSION)~g' lib/automated-ops-scripts.sh.in >lib/automated-ops-scripts.sh

build: automated-ops-scripts-config.sh lib/automated-ops-scripts.sh

install: build
	install -m 0755 -d $(DESTDIR)$(BINDIR)
	install -m 0755 -d $(DESTDIR)$(LIBDIR)/automated-ops-scripts
	install -m 0755 -d $(DESTDIR)$(DOCSDIR)/automated-ops-scripts
	install -m 0755 automated-ops-scripts-config.sh $(DESTDIR)$(BINDIR)
	install -m 0644 lib/*.sh $(DESTDIR)$(LIBDIR)/automated-ops-scripts
	for script in $(SCRIPTS); do \
		install -m 0755 "scripts/$${script}" $(DESTDIR)$(BINDIR); \
	done
	install -m 0644 README.* $(DESTDIR)$(DOCSDIR)/automated-ops-scripts

uninstall:
	rm -rf $(DESTDIR)$(LIBDIR)/automated-ops-scripts
	rm -rf $(DESTDIR)$(DOCSDIR)/automated-ops-scripts
	for script in $(SCRIPTS); do \
		rm -f "$(DESTDIR)$(BINDIR)/$${script}"; \
	done

release:
	git tag $(VERSION)

sdist:
	mkdir -p sdist; \
	git archive "--prefix=automated-ops-scripts-$(VERSION)/" -o sdist/automated-ops-scripts-$(VERSION).tar.gz $(VERSION)

rpm: PREFIX := /usr
rpm: sdist
	mkdir -p bdist; \
	rpm_version=$$(cut -f 1 -d '-' <<< $(VERSION)); \
	rpm_release=$$(cut -s -f 2 -d '-' <<< $(VERSION)); \
	sourcedir=$$(readlink -f sdist); \
	rpmbuild -ba "automated-ops-scripts.spec" \
		--define "rpm_version $${rpm_version}" \
		--define "rpm_release $${rpm_release:-1}" \
		--define "full_version $(VERSION)" \
		--define "prefix $(PREFIX)" \
		--define "_srcrpmdir sdist/" \
		--define "_rpmdir bdist/" \
		--define "_sourcedir $${sourcedir}" \
		--define "_bindir $(BINDIR)" \
		--define "_libdir $(LIBDIR)" \
		--define "_defaultdocdir $(DOCSDIR)"
