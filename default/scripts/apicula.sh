cd apicula
source ${PATCHES_DIR}/python3_package.sh
python3_package_setup
python3_package_pip_install "msgspec"

# fastcrc is a Rust/PyO3 package. On linux-x64 (native build) pip can build
# it directly. For cross-compilation targets we use maturin with the
# generate-import-lib feature so PyO3 doesn't need a Python import library.
if [ ${ARCH} == 'linux-x64' ]; then
    python3_package_pip_install "fastcrc"
else
    pip3 install maturin
    pip3 download --no-binary :all: --no-deps fastcrc -d /tmp/fastcrc_src
    cd /tmp/fastcrc_src
    tar xzf fastcrc-*.tar.gz
    cd fastcrc-*/
    PYO3_CROSS_PYTHON_VERSION=3.11 \
        maturin build --release --target ${CARGO_TARGET} \
        --interpreter ${PYTHON3_NATIVE} \
        --cargo-extra-args="--features pyo3/generate-import-lib"
    ${PYTHON3_NATIVE} -m pip install \
        --target ${OUTPUT_DIR}${INSTALL_PREFIX}/lib/python3.11/site-packages \
        --no-cache-dir --disable-pip-version-check \
        target/wheels/fastcrc-*.whl
    cd ${SRC_DIR}/apicula
fi

curl -L https://github.com/YosysHQ/apicula/releases/download/0.0.0.dev/linux-x64-gowin-data.tgz > linux-x64-gowin-data.tgz
tar xvfz linux-x64-gowin-data.tgz
python3_package_pip_install "--no-deps ."
