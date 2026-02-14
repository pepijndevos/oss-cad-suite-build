# Investigation: Python Bundling and C Extensions in oss-cad-suite-build

This document analyzes how Python and its C extensions are currently bundled,
and what would be needed to support msgspec (for apicula PR #454), numpy, and
crcmod.

## Current Architecture

### Python Build

CPython 3.11.6 is built twice:

1. **python3-native** (`default/scripts/python3-native.sh`): Built for the host
   (build machine) architecture. Used to run `setup.py` and `pip install`
   commands during cross-compilation.

2. **python3** (`default/scripts/python3.sh`): Cross-compiled for the target
   architecture (linux-x64, linux-arm64, windows-x64, darwin-x64, darwin-arm64).
   Always built with `--enable-shared` (dynamic libpython). All static `.a`
   libraries are removed post-build.

### Cross-Compilation of Python Packages

The helper script `default/patches/python3_package.sh` provides several
functions for installing Python packages during cross-compilation:

| Function | Method | Use Case |
|----------|--------|----------|
| `python3_package_install` | `setup.py install` | Packages with C extensions needing source compilation |
| `python3_package_install_numpy` | `setup.py build` + `install` with CPU dispatch flags | Numpy specifically (Windows gets restricted AVX512) |
| `python3_package_pip_install` | `pip install --target` | Pure-Python packages or packages with pre-built wheels |
| `python3_package_develop` | `setup.py develop` | Development installs |

All functions set two critical environment variables for cross-compilation:
- `_PYTHON_HOST_PLATFORM`: Tells distutils/pip what target platform to build for
- `_PYTHON_SYSCONFIGDATA_NAME`: Points to the target's `_sysconfigdata__*.py` module

The native Python interpreter (`$PYTHON3_NATIVE`) runs the build commands, but
the sysconfig data directs compilation to use the cross-compiler and target
flags.

### Docker Cross-Compilation Environment

Each target architecture has a Docker image (`docker/cross-*/`) with:
- Cross-compilers (GCC, Clang)
- Target development libraries (libffi, libssl, libsqlite3, etc.)
- Rust toolchain with cross-compilation targets
- CMake, autoconf, and other build tools

### Packaging (Distribution Assembly)

**Linux** (`scripts/package-linux.sh`):
- ELF binaries in `bin/`, `py3bin/` are moved to `libexec/`
- Wrapper shell scripts are created that invoke `ld-linux` with a custom
  `--library-path` pointing to the bundled `lib/` directory
- `lddtree` is used to find and copy all shared library dependencies into `lib/`
- Python scripts get wrappers that set `PYTHONHOME`, `PYTHONEXECUTABLE`, and
  `PYTHONNOUSERSITE=1`

**Critical gap for C extensions**: The `lddtree` dependency scan (lines 255-261)
only scans shared libraries in `lib/`, **not** `.so` files in
`lib/python3.11/site-packages/` or `lib/python3.11/lib-dynload/`. This means
C extension `.so` files rely on their dependencies already being bundled for
other reasons (e.g., libpython itself pulls in libc, libm, libpthread, etc.)
or being standard enough to exist on any target system.

## Current C Extension Packages

### Already bundled:

| Package | Build Method | Notes |
|---------|-------------|-------|
| **crc** | `python3_package_pip_install "crc"` | Pure Python - no C extension |
| **PyGObject** | `python3_package_install` (setup.py) | C extension, used by xdot |
| **cocotb** | `python3_package_install` | C extension (VPI/VHPI sim interfaces) |
| **rpds-py** | `python3_package_pip_install "rpds-py==0.16.1"` | Rust extension, compiled via Cargo |

### Infrastructure exists but not connected:

| Package | Status |
|---------|--------|
| **numpy** | Build script exists (`default/scripts/numpy.sh`) and `python3_package_install_numpy()` function exists, but **no Target rule** includes it. Dead infrastructure. |

### Not present at all:

| Package | Status |
|---------|--------|
| **msgspec** | No references anywhere in the repo |
| **crcmod** | No references anywhere in the repo |

## Apicula Current State

**Rule**: `default/rules/nextpnr.py:140-146`
```
Target(
    name = 'apicula',
    sources = [ 'apicula' ],
    dependencies = [ 'python3', 'python3-native' ],
    resources = [ 'python3' ],
    package = 'gowin',
)
```

**Build script** (`default/scripts/apicula.sh`):
1. Sources `python3_package.sh` and sets up cross-compilation environment
2. Installs `crc` (pure Python) via pip
3. Downloads pre-built gowin chip database (`.pickle` files)
4. Installs apicula itself via `setup.py install --old-and-unmanageable`

**apicula-bba** (`default/scripts/apicula-bba.sh`): Copies apicula's
site-packages into the native Python and runs nextpnr's CMake to generate BBA
chip database files. Runs natively (not cross-compiled).

## Analysis: Apicula PR #454 (msgspec)

PR #454 replaces pickle with msgspec MessagePack serialization for chip database
files. Key changes:

- **New dependency**: `msgspec` added to `install_requires` in setup.py
- **File format**: `.pickle` + gzip -> `.msgpack.xz` (LZMA compression)
- **Data restructuring**: `Device.grid` changes from `List[List[Tile]]` to
  `List[List[int]]` (tile type indices) to avoid object duplication that msgspec
  can't handle (unlike pickle's object identity preservation)
- **Benefits**: ~1s faster chipdb loading, 5x better compression (2.8MB vs
  15.8MB), type validation

### What would need to change in oss-cad-suite-build:

#### 1. Add msgspec to apicula.sh

msgspec is a C extension (Cython-based). Two options:

**Option A: pip install (preferred if wheels are available)**
```bash
python3_package_pip_install "msgspec"
```
This works if PyPI has pre-built wheels for all target platforms. msgspec
publishes wheels for:
- linux x86_64 (manylinux)
- linux aarch64 (manylinux)
- macOS x86_64
- macOS arm64
- Windows x64

This covers all 5 oss-cad-suite target architectures, so pip should be able
to download pre-built wheels without source compilation. However, the pip
install runs under the **native** Python with cross-compilation env vars set.
The `_PYTHON_HOST_PLATFORM` variable tells pip which platform's wheel to select.
This approach works for pure-Python packages and should work for selecting the
correct platform wheel, but **testing is needed** to confirm pip correctly
selects target-platform wheels in this cross-compilation setup.

**Option B: Source compilation**
```bash
python3_package_pip_install "Cython"
cd msgspec
python3_package_install
```
This compiles msgspec from source using the cross-compiler. More reliable for
cross-compilation but requires Cython and the msgspec source to be available.

#### 2. Update chip database download URL

The current `apicula.sh` downloads pre-built `.pickle` databases from GitHub
releases. After PR #454, these would be `.msgpack.xz` files instead. The
download URL pattern would need updating.

#### 3. apicula-bba.sh may need msgspec natively

Since `apicula-bba` runs natively and imports apicula code, msgspec would also
need to be available in the native Python environment. The current script copies
apicula's site-packages into the native Python (line 2 of `apicula-bba.sh`), so
if msgspec is installed as a dependency of apicula, its `.so` would be the
cross-compiled version - **wrong architecture for native execution**.

This would need to be addressed, likely by also pip-installing msgspec into the
native Python environment, similar to how the numpy script installs Cython
natively first.

## Analysis: Adding numpy

### Current infrastructure

The build script `default/scripts/numpy.sh` already exists and works:
```bash
cd numpy
git submodule update --init
source ${PATCHES_DIR}/python3_package.sh
python3_package_setup
python3_package_pip_install "Cython"
python3_package_install_numpy
```

The `python3_package_install_numpy()` function handles platform-specific CPU
dispatch flags (disabling AVX-512 on Windows where it's problematic).

### What's needed

1. **Add a numpy rule** in `default/rules/` (e.g., a new file or in an existing
   one):
   ```python
   SourceLocation(
       name = 'numpy',
       vcs = 'git',
       location = 'https://github.com/numpy/numpy',
       revision = 'tags/v1.26.4',  # or appropriate version
       license_file = 'LICENSE.txt',
   )

   Target(
       name = 'numpy',
       sources = [ 'numpy' ],
       dependencies = [ 'python3', 'python3-native' ],
       resources = [ 'python3' ],
       patches = [ 'python3_package.sh' ],
   )
   ```

2. **Add numpy as a dependency of apicula** (if apicula wants to use it):
   ```python
   Target(
       name = 'apicula',
       sources = [ 'apicula' ],
       dependencies = [ 'python3', 'python3-native', 'numpy' ],
       resources = [ 'python3', 'numpy' ],
       package = 'gowin',
   )
   ```

3. **Packaging concern**: numpy's compiled `.so` extensions (e.g.,
   `numpy/core/_multiarray_umath.cpython-311-x86_64-linux-gnu.so`) may depend on
   BLAS/LAPACK libraries. The Linux packaging script's `lddtree` scan does NOT
   cover files in `site-packages/`, so any non-standard shared library
   dependencies would not be automatically bundled. This would need either:
   - Statically linking BLAS/LAPACK into numpy (numpy's build system supports
     this via bundled OpenBLAS)
   - Extending `package-linux.sh` to also scan `.so` files in site-packages
   - Using numpy's bundled (vendored) BLAS which is the default behavior for
     recent numpy versions

4. **Size impact**: numpy is large. The site-packages footprint is typically
   30-50MB depending on architecture.

## Analysis: Adding crcmod

`crcmod` is a small C extension that provides fast CRC computation. It was
historically removed from apicula's dependencies (replaced by the pure-Python
`crc` package).

### What's needed

`crcmod` is straightforward to add since it has minimal dependencies (just libc):

```bash
python3_package_pip_install "crcmod"
```

Or if compiling from source is preferred:
```bash
cd crcmod
python3_package_install
```

Since crcmod's C extension only depends on standard C libraries (already bundled
for libpython), there should be no packaging issues.

The apicula.sh script would change from:
```bash
python3_package_pip_install "crc"
```
to:
```bash
python3_package_pip_install "crcmod"
```
(or both, if apicula still imports `crc` as well).

## Summary of Risks and Recommendations

### msgspec (required for PR #454)

| Aspect | Risk | Mitigation |
|--------|------|------------|
| Cross-compilation | Medium - wheel selection with `_PYTHON_HOST_PLATFORM` needs testing | Test pip install in Docker build env; fall back to source build |
| Native build (apicula-bba) | High - cross-compiled `.so` won't work natively | Install msgspec separately for native Python |
| Platform coverage | Low - wheels exist for all 5 target platforms | Monitor for new platform additions |

### numpy (performance acceleration)

| Aspect | Risk | Mitigation |
|--------|------|------------|
| Build infrastructure | Low - scripts already exist | Just need to add Target rule |
| BLAS/LAPACK bundling | Medium - shared lib deps may not be bundled | Use numpy's vendored OpenBLAS; extend package script if needed |
| Distribution size | Medium - adds 30-50MB | Acceptable trade-off for performance |
| Cross-compilation | Low - `python3_package_install_numpy` already handles this | Existing infrastructure |

### crcmod (performance acceleration)

| Aspect | Risk | Mitigation |
|--------|------|------------|
| Cross-compilation | Low - minimal C extension with no exotic deps | Standard pip install or setup.py |
| Packaging | Low - only depends on libc | Already bundled |
| Compatibility | Low - well-established package | Pin version for reproducibility |

### Recommended priority

1. **crcmod** - lowest risk, easiest to add, immediate benefit
2. **msgspec** - required for PR #454, moderate complexity due to apicula-bba native build issue
3. **numpy** - infrastructure mostly exists, but size impact and BLAS bundling need attention
