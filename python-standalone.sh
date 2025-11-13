package: Python-standalone
version: "3.10.19"
tag: "20251028"
build_requires:
  - curl
  - alibuild-recipe-tools
env:
  SSL_CERT_FILE: "$(export PATH=$PYTHON_STANDALONE_ROOT/bin:$PATH; python3 -c \"import certifi; print(certifi.where())\" 2>/dev/null || true)"
  PYTHONHOME: "$PYTHON_STANDALONE_ROOT"
  PYTHONPATH: "$PYTHON_STANDALONE_ROOT/lib/python/site-packages"
prefer_system: "(?!slc5|ubuntu)"
prefer_system_check: |
    python3 -c 'import sys; import sqlite3; sys.exit(1 if sys.version_info < (3, 10) or sys.version_info > (3, 14) else 0)' && python3 -m pip --help > /dev/null && printf '#include "pyconfig.h"' | cc -c $(python3-config --includes) -xc -o /dev/null - 2>/dev/null; if [ $? -ne 0 ]; then exit 1; fi
    python3 -c 'from sys import version_info; print(f"alibuild_system_replace: python{version_info.major}.{version_info.minor}")'
prefer_system_replacement_specs:
  "python3.*":
    version: "%(key)s"
    env:
        PYTHON_STANDALONE_ROOT: "/dummy-python-folder"
        PYTHON_STANDALONE_REVISION: ""
---
#!/bin/bash -e

# Map architecture to python-build-standalone filename
case $ARCHITECTURE in
  slc*_x86-64|ubuntu*_x86-64|rhel*_x86-64)
    FILENAME="cpython-${PKGVERSION}+${PKGTAG}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
    ;;
  slc*_aarch64|ubuntu*_aarch64|rhel*_aarch64)
    FILENAME="cpython-${PKGVERSION}+${PKGTAG}-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz"
    ;;
  osx_x86-64)
    FILENAME="cpython-${PKGVERSION}+${PKGTAG}-x86_64-apple-darwin-install_only_stripped.tar.gz"
    ;;
  osx_arm64)
    FILENAME="cpython-${PKGVERSION}+${PKGTAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
    ;;
  *)
    echo "Unsupported architecture: $ARCHITECTURE"
    exit 1
    ;;
esac

# Download URL
DOWNLOAD_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PKGTAG}/${FILENAME}"

# Download the prebuilt Python
echo "Downloading Python from: $DOWNLOAD_URL"
curl -L -o "$BUILDDIR/${FILENAME}" "$DOWNLOAD_URL"

# Extract archive
cd "$BUILDDIR"
tar -xzf "${FILENAME}"

# Move extracted python directory to installation root
rsync -a python/ "$INSTALLROOT/"

# Patch long shebangs and add pip(3)/python(3) symlinks
pushd "$INSTALLROOT/bin"
  sed -i.deleteme -e "1 s|^#!${INSTALLROOT}/bin/\(.*\)$|#!/usr/bin/env \1|" * 2>/dev/null || true
  rm -f *.deleteme
  PYTHON_BIN=$(ls python3.* 2>/dev/null | head -n1)
  PIP_BIN=$(ls pip3.* 2>/dev/null | head -n1)
  PYTHON_CONFIG_BIN=$(ls python3.*-config 2>/dev/null | head -n1)
  [[ $PYTHON_BIN && ! -e python ]] && ln -nfs "$PYTHON_BIN" python
  [[ $PYTHON_BIN && ! -e python3 ]] && ln -nfs "$PYTHON_BIN" python3
  [[ $PIP_BIN && ! -e pip ]] && ln -nfs "$PIP_BIN" pip
  [[ $PIP_BIN && ! -e pip3 ]] && ln -nfs "$PIP_BIN" pip3
  [[ $PYTHON_CONFIG_BIN && ! -e python-config ]] && ln -nfs "$PYTHON_CONFIG_BIN" python-config
  [[ $PYTHON_CONFIG_BIN && ! -e python3-config ]] && ln -nfs "$PYTHON_CONFIG_BIN" python3-config
popd

# Install Python SSL certificates
env PATH="$INSTALLROOT/bin:$PATH" \
    LD_LIBRARY_PATH="$INSTALLROOT/lib:$LD_LIBRARY_PATH" \
    PYTHONHOME="$INSTALLROOT" \
    python3 -m pip install --no-warn-script-location 'certifi==2022.12.7'

# Uniform Python library path
pushd "$INSTALLROOT/lib"
  [[ ! -e python ]] && ln -nfs python* python
popd

# Remove useless stuff to save space
rm -rf "$INSTALLROOT"/share "$INSTALLROOT"/lib/python*/test 2>/dev/null || true
find "$INSTALLROOT"/lib/python* \
     -mindepth 2 -maxdepth 2 -type d -and \( -name test -or -name tests \) \
     -exec rm -rf '{}' \; 2>/dev/null || true

# Modulefile
MODULEDIR="$INSTALLROOT/etc/modulefiles"
MODULEFILE="$MODULEDIR/$PKGNAME"
mkdir -p "$MODULEDIR"
alibuild-generate-module --bin --lib > "$MODULEFILE"
cat >> "$MODULEFILE" <<EoF
setenv PYTHONHOME \$PKG_ROOT
prepend-path PYTHONPATH \$PKG_ROOT/lib/python/site-packages
if { [module-info mode load] } {
  catch { setenv SSL_CERT_FILE [exec \$PKG_ROOT/bin/python3 -c "import certifi; print(certifi.where())"] }
}
if { [module-info mode remove] } {
  unsetenv SSL_CERT_FILE
}
EoF
