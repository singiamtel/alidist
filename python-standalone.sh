package: Python-standalone
version: "3.11.11"
tag: "20251031"
source: https://github.com/astral-sh/python-build-standalone/releases/download/%(tag)s
requires:
  - AliEn-Runtime:(?!.*ppc64)
build_requires:
  - curl
  - zstd
  - alibuild-recipe-tools
env:
  SSL_CERT_FILE: "$(export PATH=$PYTHON_STANDALONE_ROOT/bin:$PATH; export LD_LIBRARY_PATH=$PYTHON_STANDALONE_ROOT/lib:$LD_LIBRARY_PATH; python3 -c \"import certifi; print(certifi.where())\")"
  PYTHONHOME: "$PYTHON_STANDALONE_ROOT"
  PYTHONPATH: "$PYTHON_STANDALONE_ROOT/lib/python/site-packages"
prefer_system: "(?!slc5|ubuntu)"
prefer_system_check: |
    case $ALIBUILD_ARCHITECTURE in
        osx*)
            # We need to include the python patch number because brew has it in the path
            python3 -c 'from sys import version_info; print(f"alibuild_system_replace: python-brew{version_info.major}.{version_info.minor}.{version_info.micro}")' ;;
        *)
            python3 -c 'from sys import version_info; print(f"alibuild_system_replace: python{version_info.major}.{version_info.minor}")'
        ;;
    esac
    python3 -c 'import sys; import sqlite3; sys.exit(1 if sys.version_info < (3, 10) or sys.version_info > (3, 14) else 0)' && python3 -m pip --help > /dev/null && printf '#include "pyconfig.h"' | cc -c $(python3-config --includes) -xc -o /dev/null -; if [ $? -ne 0 ]; then printf "Python, the Python development packages, and pip must be installed on your system.\nUsually those packages are called python, python-devel (or python-dev) and python-pip.\n"; exit 1; fi
prefer_system_replacement_specs:
  "python-brew3.*":
    version: "%(key)s"
    env:
        PYTHON_STANDALONE_ROOT: $(brew --prefix python3)
        PYTHON_STANDALONE_REVISION: ""
  "python3.*":
    version: "%(key)s"
    env:
        # Python is in path, so we need a dummy placeholder for PYTHON_STANDALONE_ROOT
        # to avoid having /bin in the middle of the path.
        PYTHON_STANDALONE_ROOT: "/dummy-python-folder"
        PYTHON_STANDALONE_REVISION: ""
---
#!/bin/bash -e

# Map architecture to python-build-standalone platform string
case $ARCHITECTURE in
  slc*_x86-64|ubuntu*_x86-64|rhel*_x86-64)
    PLATFORM="x86_64-unknown-linux-gnu"
    ;;
  slc*_aarch64|ubuntu*_aarch64|rhel*_aarch64)
    PLATFORM="aarch64-unknown-linux-gnu"
    ;;
  osx_x86-64)
    PLATFORM="x86_64-apple-darwin"
    ;;
  osx_arm64)
    PLATFORM="aarch64-apple-darwin"
    ;;
  *)
    echo "Unsupported architecture: $ARCHITECTURE"
    exit 1
    ;;
esac

# Construct download URL and filename
# Using install_only variant for smaller download, can switch to install_pgo+lto for optimized builds
VARIANT="install_only"
PYTHON_VERSION="${PKGVERSION%%.*}.${PKGVERSION#*.}"
PYTHON_VERSION="${PYTHON_VERSION%%.*}.${PYTHON_VERSION#*.}"  # Get major.minor
FILENAME="cpython-${PKGVERSION}+${PKGTAG}-${PLATFORM}-${VARIANT}.tar.zst"
DOWNLOAD_URL="${SOURCEDIR}/${FILENAME}"

# Download the prebuilt Python
echo "Downloading Python from: $DOWNLOAD_URL"
curl -L -o "$BUILDDIR/${FILENAME}" "$DOWNLOAD_URL"

# Extract archive
echo "Extracting Python standalone build..."
cd "$BUILDDIR"
tar -xf "${FILENAME}"

# Move extracted python directory to installation root
rsync -a python/ "$INSTALLROOT/"

# Patch long shebangs and add pip(3)/python(3) symlinks
pushd "$INSTALLROOT/bin"
  sed -i.deleteme -e "1 s|^#!${INSTALLROOT}/bin/\(.*\)$|#!/usr/bin/env \1|" * || true
  rm -f *.deleteme
  PYTHON_BIN=$(for X in python*; do echo "$X"; done | grep -E '^python[0-9]+\.[0-9]+$' | head -n1)
  PIP_BIN=$(for X in pip*; do echo "$X"; done | grep -E '^pip[0-9]+\.[0-9]+$' | head -n1)
  PYTHON_CONFIG_BIN=$(for X in python*-config; do echo "$X"; done | grep -E '^python[0-9]+\.[0-9]+m?-config$' | head -n1)
  [[ -x python ]] || ln -nfs "$PYTHON_BIN" python
  [[ -x python3 ]] || ln -nfs "$PYTHON_BIN" python3
  [[ -x pip ]] || ln -nfs "$PIP_BIN" pip
  [[ -x pip3 ]] || ln -nfs "$PIP_BIN" pip3
  [[ -x python-config ]] || ln -nfs "$PYTHON_CONFIG_BIN" python-config
  [[ -x python3-config ]] || ln -nfs "$PYTHON_CONFIG_BIN" python3-config
popd

# Install Python SSL certificates
env PATH="$INSTALLROOT/bin:$PATH" \
    LD_LIBRARY_PATH="$INSTALLROOT/lib:$LD_LIBRARY_PATH" \
    PYTHONHOME="$INSTALLROOT" \
    python3 -m pip install 'certifi==2022.12.7'

# Uniform Python library path
pushd "$INSTALLROOT/lib"
  ln -nfs python* python
popd

# Remove useless stuff
rm -rvf "$INSTALLROOT"/share "$INSTALLROOT"/lib/python*/test
find "$INSTALLROOT"/lib/python* \
     -mindepth 2 -maxdepth 2 -type d -and \( -name test -or -name tests \) \
     -exec rm -rvf '{}' \;

# Get OpenSSL and zlib at runtime from AliEn-Runtime if appropriate
[[ $ALIEN_RUNTIME_REVISION ]] && unset OPENSSL_REVISION ZLIB_REVISION

# Modulefile
MODULEDIR="$INSTALLROOT/etc/modulefiles"
MODULEFILE="$MODULEDIR/$PKGNAME"
mkdir -p "$MODULEDIR"
alibuild-generate-module --bin --lib > "$MODULEFILE"
cat >> "$MODULEFILE" <<EoF
setenv PYTHONHOME \$PKG_ROOT
prepend-path PYTHONPATH \$PKG_ROOT/lib/python/site-packages
if { [module-info mode load] } {
  setenv SSL_CERT_FILE  [exec \$PKG_ROOT/bin/python3 -c "import certifi; print(certifi.where())"]
}
if { [module-info mode remove] } {
  unsetenv SSL_CERT_FILE
}
EoF
