#!/bin/bash -e
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

deps="meson ninja patchelf unzip curl pip flex bison zip git"
workdir="$(pwd)/panvk_workdir"
packagedir="$workdir/panvk_module"
ndkver="android-ndk-r27"
sdkver="33"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"

base_patches=()
experimental_patches=()
failed_patches=()
commit=""
commit_short=""
mesa_version=""
vulkan_version=""

check_deps(){
    sudo apt remove meson
    pip install meson PyYAML

    echo "Checking system for required Dependencies ..."
    for deps_chk in $deps; do
        sleep 0.25
        if command -v "$deps_chk" >/dev/null 2>&1 ; then
            echo -e "$green - $deps_chk found $nocolor"
        else
            echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
            deps_missing=1
        fi
    done

    if [ "$deps_missing" == "1" ]; then
        echo "Please install missing dependencies" && exit 1
    fi

    echo "Installing python Mako dependency (if missing) ..." $'\n'
    pip install mako &> /dev/null
}

prepare_workdir(){
    echo "Creating and entering to work directory ..." $'\n'
    mkdir -p "$workdir" && cd "$_"

    if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
        if [ ! -n "$(ls -d android-ndk*)" ]; then
            echo "Downloading android-ndk from google server (~640 MB) ..." $'\n'
            curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
            echo "Extracting android-ndk to a folder ..." $'\n'
            unzip "$ndkver"-linux.zip &> /dev/null
        fi
    else    
        echo "Using android ndk from github image"
    fi

    if [ -z "$1" ]; then
        if [ -d mesa ]; then
            echo "Removing old mesa ..." $'\n'
            rm -rf mesa
        fi
        
        echo "Cloning mesa ..." $'\n'
        git clone --depth=1 "$mesasrc"

        cd mesa
        
        # Update path to look for patches in patches directory
        if [ -f "$workdir/patches/fix_warnings.patch" ]; then
            echo "Applying warning fixes patch..."
            git apply "$workdir/patches/fix_warnings.patch" || {
                echo "Warning: Failed to apply fixes patch"
            }
        fi

        commit_short=$(git rev-parse --short HEAD)
        commit=$(git rev-parse HEAD)
        mesa_version=$(cat VERSION | xargs)
        version=$(awk -F'COMPLETE VK_MAKE_API_VERSION(|)' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
        major=$(echo $version | cut -d "," -f 2 | xargs)
        minor=$(echo $version | cut -d "," -f 3 | xargs)
        patch=$(awk -F'VK_HEADER_VERSION |\n#define' '{print $2}' <<< $(cat include/vulkan/vulkan_core.h) | xargs)
        vulkan_version="$major.$minor.$patch"
    else        
        cd mesa
        if [ $1 == "patched" ]; then 
            apply_patches ${base_patches[@]}
        else 
            apply_patches ${experimental_patches[@]}
        fi
    fi
}

apply_patches() {
    local arr=("$@")
    for patch in "${arr[@]}"; do
        echo "Applying patch $patch"
        patch_source="$(echo $patch | cut -d ";" -f 2 | xargs)"
        patch_args=$(echo $patch | cut -d ";" -f 3 | xargs)
        if [[ $patch_source == *"../.."* ]]; then
            if git apply $patch_args "$patch_source"; then
                echo "Patch applied successfully"
            else
                echo "Failed to apply $patch"
                failed_patches+=("$patch")
            fi
        else 
            patch_file="${patch_source#*\/}"
            curl --output "../$patch_file".patch -k --retry-delay 30 --retry 5 -f --retry-all-errors https://gitlab.freedesktop.org/mesa/mesa/-/"$patch_source".patch
            sleep 1

            if git apply $patch_args "../$patch_file".patch ; then
                echo "Patch applied successfully"
            else
                echo "Failed to apply $patch"
                failed_patches+=("$patch")
            fi
        fi
    done
}

patch_to_description() {
    local arr=("$@")
    for patch in "${arr[@]}"; do
        patch_name="$(echo $patch | cut -d ";" -f 1 | xargs)"
        patch_source="$(echo $patch | cut -d ";" -f 2 | xargs)"
        patch_args="$(echo $patch | cut -d ";" -f 3 | xargs)"
        if [[ $patch_source == *"../.."* ]]; then
            echo "- $patch_name, $patch_source, $patch_args" >> description
        else 
            echo "- $patch_name, [$patch_source](https://gitlab.freedesktop.org/mesa/mesa/-/$patch_source), $patch_args" >> description
        fi
    done
}

build_lib_for_android(){
    echo "Creating meson cross file ..." $'\n'
    if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
        ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
    else    
        ndk="$ANDROID_NDK_LATEST_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    fi

    # Create directories for libdrm headers
    mkdir -p "$workdir/include/libdrm/drm"
    mkdir -p "$workdir/include/xf86drm"

    # Download necessary libdrm headers and create type definitions
    echo "Downloading and setting up libdrm headers..."
    LIBDRM_HEADERS=(
        "drm.h"
        "drm_mode.h"
        "drm_fourcc.h"
    )
    
    for header in "${LIBDRM_HEADERS[@]}"; do
        curl -L "https://gitlab.freedesktop.org/mesa/drm/-/raw/main/include/drm/$header" -o "$workdir/include/libdrm/drm/$header"
    done
    
    curl -L "https://gitlab.freedesktop.org/mesa/drm/-/raw/main/xf86drm.h" -o "$workdir/include/libdrm/xf86drm.h"

    # Update drm.h include path in xf86drm.h
    sed -i 's|<drm.h>|"drm/drm.h"|g' "$workdir/include/libdrm/xf86drm.h"

    # Create drm_types.h with missing type definitions
    cat <<EOF >"$workdir/include/libdrm/drm/drm_types.h"
#ifndef _DRM_TYPES_H_
#define _DRM_TYPES_H_

#include <stdint.h>

typedef struct _drmDevice {
    char **nodes;
    int available_nodes;
    int bustype;
    union {
        struct {
            uint16_t vendor;
            uint16_t device;
            uint16_t subsystem_vendor;
            uint16_t subsystem_device;
            uint8_t revision;
        } pci;
    } businfo;
} drmDevice, *drmDevicePtr;

typedef unsigned int drm_handle_t;
typedef unsigned int drm_context_t;
typedef unsigned int drm_magic_t;

#endif /* _DRM_TYPES_H_ */
EOF

    # Add include for drm_types.h to drm.h
    sed -i '1i #include "drm_types.h"' "$workdir/include/libdrm/drm/drm.h"

    # Create pkgconfig directory and libdrm.pc file
    mkdir -p "$workdir/pkgconfig"
    cat <<EOF >"$workdir/pkgconfig/libdrm.pc"
prefix=$workdir
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libdrm
Description: Userspace interface to kernel DRM services
Version: 2.4.110
Libs: -L\${libdir} -ldrm
Cflags: -I\${includedir}/libdrm -I\${includedir}/libdrm/drm
EOF

    # Create stub drm.h declaration
    cat <<EOF >"$workdir/drm_stub.h"
#ifndef _DRM_H_
#define _DRM_H_

#include <stdint.h>

typedef struct _drmDevice {
    char **nodes;
    int available_nodes;
    int bustype;
    union {
        struct {
            uint16_t vendor;
            uint16_t device;
            uint16_t subsystem_vendor;
            uint16_t subsystem_device;
            uint8_t revision;
        } pci;
    } businfo;
} drmDevice, *drmDevicePtr;

#endif /* _DRM_H_ */
EOF

    # Create stub libdrm library
    echo "Creating stub libdrm library..."
    mkdir -p "$workdir/lib"
    
    cat <<EOF >"$workdir/drm_stub.c"
#include "drm_stub.h"
#include <stdint.h>

// Stub functions - minimal implementation
int drmGetNodeTypeFromFd(int fd) { return -1; }
char *drmGetDeviceNameFromFd2(int fd) { return 0; }
int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device) { return -1; }
void drmFreeDevice(drmDevicePtr *device) { }
EOF

    # Update include paths and compile
    cp "$workdir/drm_stub.h" "$workdir/include/libdrm/drm/drm.h"
    "$ndk/aarch64-linux-android$sdkver-clang" -c -o "$workdir/drm_stub.o" "$workdir/drm_stub.c" -I"$workdir/include/libdrm"
    "$ndk/llvm-ar" rcs "$workdir/lib/libdrm.a" "$workdir/drm_stub.o"

    # Update pkgconfig file with correct lib path
    cat <<EOF >"$workdir/pkgconfig/libdrm.pc"
prefix=$workdir
libdir=\${prefix}/lib
includedir=\${prefix}/include/libdrm

Name: libdrm
Description: Userspace interface to kernel DRM services
Version: 2.4.110
Libs: -L\${libdir} -ldrm
Cflags: -I\${includedir}
EOF

    # Create cross file with updated include paths
    cat <<EOF >"$workdir/mesa/android-aarch64"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$workdir/pkgconfig', '/usr/bin/pkg-config']
[built-in options]
c_args = ['-I$workdir/include', '-I$workdir/include/libdrm/drm']
cpp_args = ['-I$workdir/include', '-I$workdir/include/libdrm/drm']
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    echo "Generating build files ..." $'\n'
    
    cd "$workdir/mesa" || {
        echo -e "$red Failed to enter mesa directory! $nocolor"
        exit 1
    }

    # Run meson with updated environment
    PKG_CONFIG_PATH="$workdir/pkgconfig" \
    CFLAGS="-O2 -I$workdir/include" \
    CXXFLAGS="-O2 -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables -I$workdir/include" \
    meson setup build-android-aarch64 \
        --cross-file android-aarch64 \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$sdkver \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=panfrost \
        -Dllvm=disabled \
        -Dshared-llvm=disabled \
        -Dvulkan-beta=true \
        -Dperfetto=false \
        -Dbuild-aco-tests=false \
        -Dandroid-libbacktrace=disabled \
        -Db_ndebug=true \
        -Degl=disabled \
        -Dgbm=disabled \
        -Dglx=disabled \
        -Dopengl=false \
        -Dc_args="-Wno-error -DPANVK_VERSION_OVERRIDE=71" \
        -Dcpp_args="-Wno-error -DPANVK_VERSION_OVERRIDE=71 -Qunused-arguments" \
        -Dc_link_args="-lm -fuse-ld=lld" \
        -Dcpp_link_args="-lm -fuse-ld=lld" &> "$workdir"/meson_log || {
            echo -e "$red Meson configuration failed! $nocolor"
            cat "$workdir"/meson_log
            exit 1
        }

    echo "Compiling build files ..." $'\n'
    ninja -C build-android-aarch64 &> "$workdir"/ninja_log || {
        echo -e "$red Build failed! $nocolor"
        cat "$workdir"/ninja_log
        exit 1
    }
}

port_lib_for_adrenotool(){
    echo "Using patchelf to match soname ..."  $'\n'
    
    BUILD_DIR="$workdir/mesa/build-android-aarch64"
    PANVK_PATH="$BUILD_DIR/src/panfrost/vulkan"
    
    # Check build status
    if [ ! -d "$BUILD_DIR" ]; then
        echo -e "$red Build directory not found! $nocolor"
        exit 1
    fi

    # List contents of vulkan directory if it exists
    if [ -d "$BUILD_DIR/src/panfrost" ]; then
        echo "Contents of panfrost directory:"
        ls -R "$BUILD_DIR/src/panfrost"
    fi

    # Check for vulkan driver
    if [ ! -f "$PANVK_PATH/libvulkan_panfrost.so" ]; then
        echo -e "$red Build failed - libvulkan_panfrost.so not found! $nocolor"
        echo "Build log:"
        cat "$workdir/ninja_log"
        exit 1
    fi

    cp "$workdir"/mesa/build-android-aarch64/src/panfrost/vulkan/libvulkan_panfrost.so "$workdir"
    cd "$workdir"
    patchelf --set-soname vulkan.mali.so libvulkan_panfrost.so
    mv libvulkan_panfrost.so vulkan.g31.so

    if ! [ -a vulkan.g31.so ]; then
        echo -e "$red Build failed! $nocolor" && exit 1
    fi

    mkdir -p "$packagedir" && cd "$_"

    date=$(date +'%b %d, %Y')
    suffix=""

    if [ ! -z "$1" ]; then
        suffix="_$1"
    fi

    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "PanVK - $date - $commit_short$suffix",
  "description": "Compiled from Mesa, Commit $commit_short$suffix",
  "author": "mesa",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "$mesa_version/vk$vulkan_version",
  "minApi": 27,
  "libraryName": "vulkan.g31.so"
}
EOF

    filename=panvk_"$(date +'%b-%d-%Y')"_"$commit_short"
    echo "Copy necessary files from work directory ..." $'\n'
    cp "$workdir"/vulkan.g31.so "$packagedir"

    # ...rest of existing code with panvk instead of turnip in strings...
}

prep() {
    prepare_workdir "$1"
    build_lib_for_android
    port_lib_for_adrenotool "$1"
}

run_all() {
    check_deps
    prep

    if (( ${#base_patches[@]} )); then
        prep "patched"
    fi
 
    if (( ${#experimental_patches[@]} )); then
        prep "experimental"
    fi
}

# Execute the main function
run_all
