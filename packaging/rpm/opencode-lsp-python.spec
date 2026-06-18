%global __os_install_post %{nil}
%global debug_package %{nil}
%global _build_id_links none
Name:           opencode-lsp-python
Version:        %{pyrightver}
Release:        1%{?dist}
Summary:        Python LSP (pyright) for air-gapped opencode
License:        MIT
BuildArch:      x86_64
Requires:       opencode
Requires:       nodejs
Requires:       python3

%description
Bundles pyright (Python language server) for air-gapped opencode and
registers it via /etc/opencode/conf.d. pyright-langserver is a Node.js
program, so nodejs is required; python3 lets pyright locate the analyzed
Python environment. Both are resolved from the internal mirror.

%install
rm -rf %{buildroot}
cp -a %{_sourcedir}/payload/opencode-lsp-python/. %{buildroot}/
install -d %{buildroot}/opt/opencode/bin
ln -sf ../lsp/python/node_modules/.bin/pyright-langserver %{buildroot}/opt/opencode/bin/pyright-langserver
install -d %{buildroot}/etc/opencode/conf.d
install -m 0644 %{_sourcedir}/config/10-python.json %{buildroot}/etc/opencode/conf.d/10-python.json

%files
%dir /opt/opencode/lsp
/opt/opencode/lsp/python
/opt/opencode/bin/pyright-langserver
%config(noreplace) /etc/opencode/conf.d/10-python.json

%post
/opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json || :

%postun
if [ "$1" = 0 ]; then
  rm -f /etc/opencode/conf.d/10-python.json
  /opt/opencode/libexec/oc-rebuild-config /etc/opencode/conf.d /etc/opencode/ollama.conf /etc/opencode/opencode.json || :
fi
