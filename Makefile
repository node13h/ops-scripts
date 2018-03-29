VERSION := $(shell cat VERSION)
RELEASE_BRANCH := master

SCRIPTS := OS deploy-collectd.sh deploy-riemann-fping.sh deploy-kubernetes.sh

PREFIX := /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
SHAREDIR = $(PREFIX)/share
DOCSDIR = $(SHAREDIR)/doc
MANDIR = $(SHAREDIR)/man

.PHONY: install clean uninstall release sdist rpm

all:
	false

clean:
	rm -rf bdist sdist

install:
	install -m 0755 -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 -d "$(DESTDIR)$(DOCSDIR)/ops-scripts"
	for script in $(SCRIPTS); do \
		install -m 0755 "scripts/$${script}" "$(DESTDIR)$(BINDIR)"; \
	done
	install -m 0755 scripts/*.sh "$(DESTDIR)$(BINDIR)"
	install -m 0644 README.* "$(DESTDIR)$(DOCSDIR)/ops-scripts"

uninstall:
	rm -rf "$(DESTDIR)$(DOCSDIR)/ops-scripts"
	for script in $(SCRIPTS); do \
		rm -f "$(DESTDIR)$(BINDIR)/$${script}"; \
	done

release:
	git tag $(VERSION)

sdist:
	mkdir -p sdist; \
	git archive "--prefix=ops-scripts-$(VERSION)/" -o "sdist/ops-scripts-$(VERSION).tar.gz" "$(VERSION)"

rpm: PREFIX := /usr
rpm: sdist
	mkdir -p bdist; \
	rpm_version=$$(cut -f 1 -d '-' <<< "$(VERSION)"); \
	rpm_release=$$(cut -s -f 2 -d '-' <<< "$(VERSION)"); \
	sourcedir=$$(readlink -f sdist); \
	rpmbuild -ba "ops-scripts.spec" \
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
