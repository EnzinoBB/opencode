Name:           opencode
Version:        %{ver}
Release:        1%{?dist}
Summary:        opencode AI coding agent (air-gapped build)
License:        MIT
URL:            https://opencode.ai
BuildArch:      x86_64
Requires:       tar
%global __os_install_post %{nil}
%global debug_package %{nil}

%description
Air-gapped opencode for RHEL 8/9. Bundles a glibc baseline binary, ripgrep,
and a LAN-Ollama default configuration. Performs no network access at
install time or runtime except to the configured Ollama endpoint.

%install
rm -rf %{buildroot}
cp -a %{_sourcedir}/payload/opencode/. %{buildroot}/
install -D -m 0755 %{_sourcedir}/files/opencode.wrapper %{buildroot}/usr/bin/opencode
install -d %{buildroot}/etc/opencode/conf.d
install -m 0644 %{_sourcedir}/config/00-base.json %{buildroot}/etc/opencode/conf.d/00-base.json
install -m 0644 %{_sourcedir}/config/ollama.conf  %{buildroot}/etc/opencode/ollama.conf

%files
%dir /opt/opencode
/opt/opencode/libexec/opencode
/opt/opencode/libexec/oc-rebuild-config
/opt/opencode/bin/rg
/usr/bin/opencode
%dir /etc/opencode
%dir /etc/opencode/conf.d
%config(noreplace) /etc/opencode/conf.d/00-base.json
%config(noreplace) /etc/opencode/ollama.conf

%post
/opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json || :

%postun
if [ "$1" = 0 ]; then rm -f /etc/opencode/opencode.json; fi
