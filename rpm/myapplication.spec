Name: myapplication

Version: 1.0
Release: 1%{?dist}

Summary: My application RPM

License: GPLv3+

Source0: application.tar

%description
My application binary

%prep
%autosetup -c
cp %{SOURCE0} ./

%install
mkdir -p %{buildroot}/usr/bin
cp application.bin %{buildroot}/usr/bin

%files
/usr/bin/application.bin
