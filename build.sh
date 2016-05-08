#!/bin/bash
# have ndk-build in your $PATH and the script figures out where your ANDROID_NDK is at.

# optionally, modify the variables below as needed.
NDKABI=21

# Default architecture is V7+Neon
ARCH=${ARCH:-"v7"}

# Default is to build with CUDA.
# Make sure you installed https://developer.nvidia.com/codeworks-android.
# Otherwise, set WITH_CUDA to OFF.
WITH_CUDA=${WITH_CUDA:-"OFF"}

if [[ "$ARCH" == "v8" ]]; then
    APP_ABI=arm64-v8a
    M_ARCH=-march=armv8-a
    ABI_NAME=aarch64-linux-androideabi
    COMPUTE_NAME=Maxwell+Tegra

elif [[ "$ARCH" == "v7n" ]]; then
    APP_ABI="armeabi-v7a with NEON"
    M_ARCH="-march=armv7-a"
    ABI_NAME=armv7-linux-androideabi
    COMPUTE_NAME="Kepler+Tegra Maxwell+Tegra"
elif [[ "$ARCH" == "v7" ]]; then
    APP_ABI="armeabi-v7a"
    M_ARCH="-march=armv7-a"
    ABI_NAME=armv7-linux-androideabi
    COMPUTE_NAME=Kepler
fi

    NVCC=`which nvcc`
export MAKE=make
export MAKEARGS=-j$(getconf _NPROCESSORS_ONLN)


####################################################
# You do not need to modify anything below this line
####################################################
# find system torch, if not found, install it
command -v th >/dev/null 2>&1
TORCHINSTALLCHECK=$?
if [ $TORCHINSTALLCHECK -ne 0 ]; then
    echo "Torch-7 not found on system. Please install it using instructions from http://torch.ch"
    exit -1
fi
# have ndk-build in your PATH and the script figures out where your ANDROID_NDK is at
unamestr=`uname`
ndkbuildloc=`which ndk-build`
if [[ "$?" == 1 ]]; then
    echo "Error: Cannot find ndk-build in PATH. Please add it to PATH environment variable"
    exit 1
fi
if [[ "$unamestr" == 'Linux' ]]; then
    export ANDROID_NDK=`readlink -f $ndkbuildloc|sed 's/ndk-exec.sh//'|sed 's/ndk-build//'`
elif [[ "$unamestr" == 'Darwin' ]]; then
    which greadlink >/dev/null 2>&1
    if [[ "$?" == 1 ]]; then
	brew install coreutils
    fi
    export ANDROID_NDK=`greadlink -f $ndkbuildloc|sed 's/ndk-exec.sh//'|sed 's/ndk-build//'`
fi
echo "Android NDK found at: $ANDROID_NDK"
cd "$(dirname "$0")" # switch to script directory
SCRIPT_ROOT_DIR=`pwd`
export INSTALL_DIR=$SCRIPT_ROOT_DIR/install
echo "INSTALL_DIR=${INSTALL_DIR}"
set +e # hard errors
export CMAKE_INSTALL_SUBDIR="share/cmake/torch"
NDK=$ANDROID_NDK

if [[ "$ARCH" == "v8" ]]; then
PREBUILT_PREFIX=aarch64-linux-android-
NDK_SYSROOT=$NDK/platforms/android-$NDKABI/arch-arm64
NDKVER=toolchains/aarch64-linux-android-4.9
NDKARCH="$M_ARCH -Wl,--fix-cortex-a8"
HOST_CC="gcc"
else
PREBUILT_PREFIX=arm-linux-androideabi-
NDK_SYSROOT=$NDK/platforms/android-$NDKABI/arch-arm
NDKVER=toolchains/arm-linux-androideabi-4.9
NDKARCH="$M_ARCH -mfloat-abi=softfp -Wl,--fix-cortex-a8"
HOST_CC="gcc -m32"
fi

NDKF="--sysroot $NDK_SYSROOT"
NDKVER=$NDK/$NDKVER


if [[ "$unamestr" == 'Linux' ]]; then
    export NDKP=$NDKVER/prebuilt/linux-x86_64/bin/${PREBUILT_PREFIX}
elif [[ "$unamestr" == 'Darwin' ]]; then
    export NDKP=$NDKVER/prebuilt/darwin-x86_64/bin/${PREBUILT_PREFIX}
fi

export CUDA_SELECT_NVCC_ARCH_TARGETS="${COMPUTE_NAME}"

do_cmake_config() {
cmake $1 -DCMAKE_VERBOSE_MAKEFILE=ON -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_ROOT_DIR/cmake/android.toolchain.cmake" \
    -DANDROID_NDK="${ANDROID_NDK}" -DANDROID_ABI="${APP_ABI}" \
    -DWITH_CUDA=${WITH_CUDA} -DWITH_LUAROCKS=OFF -DWITH_LUAJIT21=ON\
    -DCUDA_USE_STATIC_CUDA_RUNTIME=OFF -DANDROID_STL_FORCE_FEATURES=OFF\
    -DANDROID_NATIVE_API_LEVEL=21 -DANDROID_STL=gnustl_shared\
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_INSTALL_SUBDIR="${CMAKE_INSTALL_SUBDIR}" \
    -DLIBRARY_OUTPUT_PATH_ROOT="${INSTALL_DIR}" \
    -DLUAJIT_SYSTEM_MINILUA="$SCRIPT_ROOT_DIR/distro/exe/luajit-rocks/luajit-2.1/src/host/minilua" \
    -DLUAJIT_SYSTEM_BUILDVM="$SCRIPT_ROOT_DIR/distro/exe/luajit-rocks/luajit-2.1/src/host/buildvm" \
    -DCMAKE_C_FLAGS="-DDISABLE_POSIX_MEMALIGN"
echo " -------------- Configuring DONE ---------------"
}

cd $SCRIPT_ROOT_DIR

cd distro/extra/FindCUDA && \
    (cmake -E make_directory build && cd build && do_cmake_config .. && make install) \
    && echo "FindCuda installed" || exit 1

cd $SCRIPT_ROOT_DIR

cd external && \
    (cmake -E make_directory build && cd build && do_cmake_config .. && make install) \
    && echo "externals installed" || exit 1

cd $SCRIPT_ROOT_DIR
# Build host luajit for minilua and buildvm
cd distro/exe/luajit-rocks/luajit-2.1

# make clean
$MAKE $MAKEARGS HOST_CC="$HOST_CC" CC="gcc" HOST_SYS=$unamestr TARGET_SYS=Linux CROSS=$NDKP TARGET_FLAGS="$NDKF $NDKARCH"

echo "Done installing Lua"

cd $SCRIPT_ROOT_DIR
(cmake -E make_directory build && cd build && do_cmake_config ..) || exit 1

cd build

(cd distro/exe && $MAKE $MAKEARGS install) || exit 1
# cwrap needs to be there first
(cd distro/pkg/cwrap && $MAKE $MAKEARGS install) || exit 1
(cd distro/pkg && $MAKE $MAKEARGS install) || exit 1

# Cutorch installs some headers/libs used by other modules in extra
if [[ "$WITH_CUDA" == "ON" ]]; then
    (cd distro/extra/cutorch && $MAKE $MAKEARGS install) || exit 1
fi

(cd distro/extra && $MAKE  $MAKEARGS install) || exit 1
(cd src && $MAKE $MAKEARGS install) || exit 1

cd ..

echo "done"
