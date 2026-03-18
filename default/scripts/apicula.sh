cd apicula
source ${PATCHES_DIR}/python3_package.sh
python3_package_setup
python3_package_pip_install "msgspec"

# Cross-compile fastcrc (Rust/PyO3/maturin).
# Install maturin via cargo (the Docker images have Rust installed).
# Use the native Python's pip to download fastcrc source.
cargo install maturin
${PYTHON3_NATIVE} -m pip download --no-binary :all: --no-deps fastcrc -d /tmp/fastcrc_src
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

curl -L https://github.com/YosysHQ/apicula/releases/download/0.0.0.dev/linux-x64-gowin-data.tgz > linux-x64-gowin-data.tgz
tar xvfz linux-x64-gowin-data.tgz
python3_package_pip_install "--no-deps ."
