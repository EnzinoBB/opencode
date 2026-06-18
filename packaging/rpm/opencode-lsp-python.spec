%global __os_install_post %{nil}
%global debug_package %{nil}
%global _build_id_links none
Name:           opencode-lsp-python
Version:        %{pylspver}
Release:        1%{?dist}
Summary:        Python LSP (python-lsp-server) for air-gapped opencode
License:        MIT
BuildArch:      x86_64
Requires:       opencode
Requires:       python3.9

%description
Bundles python-lsp-server (pylsp), a pure-Python language server, for
air-gapped opencode. No Node.js and no network access required: the complete
pure-Python dependency tree is shipped inside this package and launched with
python3.9 via /opt/opencode/bin/pylsp. python-lsp-server needs Python >= 3.9;
the python3.9 package is the same on RHEL 8 and 9 and is resolved from the
internal mirror. Registered through /etc/opencode/conf.d.

%install
rm -rf %{buildroot}
cp -a %{_sourcedir}/payload/opencode-lsp-python/. %{buildroot}/
install -D -m 0755 %{_sourcedir}/files/pylsp.wrapper %{buildroot}/opt/opencode/bin/pylsp
install -d %{buildroot}/etc/opencode/conf.d
install -m 0644 %{_sourcedir}/config/10-python.json %{buildroot}/etc/opencode/conf.d/10-python.json

%files
%dir /opt/opencode/lsp
/opt/opencode/lsp/python
/opt/opencode/bin/pylsp
%config(noreplace) /etc/opencode/conf.d/10-python.json

%post
/opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json || :

%postun
if [ "$1" = 0 ]; then
  rm -f /etc/opencode/conf.d/10-python.json
  /opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json || :
fi
