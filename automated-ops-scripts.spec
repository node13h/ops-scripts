Name:      automated-ops-scripts
Version:   %{rpm_version}
Release:   %{rpm_release}
Summary:   Scripts based on automated.sh
URL:       https://github.com/node13h/automated-ops-scripts
License:   GPLv3+
BuildArch: noarch
Source0:   automated-ops-scripts-%{full_version}.tar.gz
Requires: automated

%description
A collection of the automated.sh-based scripts

%prep
%setup -n automated-ops-scripts-%{full_version}

%clean
rm -rf --one-file-system --preserve-root -- "%{buildroot}"

%install
make install DESTDIR="%{buildroot}" PREFIX="%{prefix}"

%files
%{_bindir}/*
%{_defaultdocdir}/*
