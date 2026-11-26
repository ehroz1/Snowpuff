# Packages the files package.sh lays out, with snowpuff_stage pointing at them: rpmbuild -bb from that script.
%global debug_package %{nil}

Name:           snowpuff
Version:        %{snowpuff_version}
Release:        1
Summary:        Snow on your Wayland desktop
License:        PolyForm-Noncommercial-1.0.0
URL:            https://github.com/ehroz1/Snowpuff
ExclusiveArch:  x86_64
# Loaded while running, so the automatic requirements miss it.
Requires:       libEGL.so.1()(64bit)

%description
Soft snow drifts across your desktop, settles on the tops of your windows and
the panel, slides off when you drag them and parts around the cursor. Needs
KDE Plasma 6, Hyprland, Sway or niri on Wayland.

%install
cp -a %{snowpuff_stage}/usr %{buildroot}/

%files
%license %{_datadir}/licenses/%{name}/LICENSE
%license %{_datadir}/licenses/%{name}/ThirdPartyNotices.txt
%{_bindir}/snowpuff
%{_datadir}/applications/snowpuff.desktop
%{_datadir}/icons/hicolor/*/apps/snowpuff.png
