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
    
    # Download and modify xf86drm.h to avoid redefinitions
    curl -L "https://gitlab.freedesktop.org/mesa/drm/-/raw/main/xf86drm.h" -o "$workdir/include/libdrm/xf86drm.h"
    
    # Remove existing struct definitions from xf86drm.h
    sed -i '/typedef struct _drmDevice/,/} drmDevice, \*drmDevicePtr;/c\#include "drm/drm_device.h"\n' "$workdir/include/libdrm/xf86drm.h"
    
    # Update include paths
    sed -i 's|<drm.h>|"drm/drm.h"|g' "$workdir/include/libdrm/xf86drm.h"

    # Create base types header first, with proper guards
    cat <<EOF >"$workdir/include/libdrm/drm/drm_base_types.h"
#ifndef _DRM_BASE_TYPES_H_
#define _DRM_BASE_TYPES_H_

#include <stdint.h>
#include "../../../include/drm-uapi/drm.h"

/* Basic DRM types */
typedef unsigned int drm_handle_t;
typedef unsigned int drm_context_t;
typedef unsigned int drm_magic_t;
typedef unsigned int drm_drawable_t;

/* Use existing enums from drm-uapi/drm.h instead of redefining */
#ifndef DRM_DRAWABLE_INFO_TYPE_DEFINED
#define DRM_DRAWABLE_INFO_TYPE_DEFINED
/* Only define if not already defined in drm-uapi/drm.h */
#ifndef drm_drawable_info_type_t
typedef enum {
    DRM_DRAWABLE_CLIPRECTS_DEPRECATED  /* Use the one from drm-uapi/drm.h instead */
} drm_drawable_info_type_deprecated_t;
#endif
#endif

#endif /* _DRM_BASE_TYPES_H_ */
EOF

    # Create device types header with proper PCI struct
    cat <<EOF >"$workdir/include/libdrm/drm/drm_device.h"
#ifndef _DRM_DEVICE_H_
#define _DRM_DEVICE_H_

#include "drm_base_types.h"

/* PCI device info structure */
struct drm_pci_info {
    uint32_t domain;
    uint32_t bus;
    uint32_t dev;
    uint32_t func;
};

typedef struct _drmDevice {
    char **nodes;
    int available_nodes;
    int bustype;
    union {
        struct drm_pci_info *pci;    /* Make this a pointer to match Mesa's usage */
    } businfo;
} drmDevice, *drmDevicePtr;

#endif /* _DRM_DEVICE_H_ */
EOF

    # Update drm.h to include in correct order
    cat <<EOF >"$workdir/include/libdrm/drm/drm.h"
#ifndef _DRM_H_
#define _DRM_H_

/* Include Mesa's DRM headers first */
#include "../../../include/drm-uapi/drm.h"

/* Then our local headers */
#include "drm_base_types.h"
#include "drm_device.h"
#include "drm_syncobj.h"

#endif /* _DRM_H_ */
EOF

    # Create drm_pci.h for PCI device info
    cat <<EOF >"$workdir/include/libdrm/drm/drm_pci.h"
#ifndef _DRM_PCI_H_
#define _DRM_PCI_H_

struct drm_pci_bus_info {
    uint32_t domain;
    uint32_t bus;
    uint32_t dev;
    uint32_t func;
};

#endif /* _DRM_PCI_H_ */
EOF

    # Create drm_device.h with Mesa-compatible structure
    cat <<EOF >"$workdir/include/libdrm/drm/drm_device.h"
#ifndef _DRM_DEVICE_H_
#define _DRM_DEVICE_H_

#include "drm_pci.h"

struct drm_device_bus_info {
    int type;
    struct drm_pci_bus_info pci;
};

typedef struct _drmDevice {
    char **nodes;
    int available_nodes;
    struct drm_device_bus_info *businfo;  /* Pointer to match Mesa's expectations */
} drmDevice, *drmDevicePtr;

#endif /* _DRM_DEVICE_H_ */
EOF

    # Create drm_uapi.h for core DRM definitions
    cat <<EOF >"$workdir/include/libdrm/drm/drm_uapi.h"
#ifndef _DRM_UAPI_H_
#define _DRM_UAPI_H_

/* Skip redefining enums that are already in drm-uapi/drm.h */
#ifndef DRM_DRAWABLE_CLIPRECTS
enum drm_drawable_info_type {
    DRM_DRAWABLE_CLIPRECTS
};
typedef enum drm_drawable_info_type drm_drawable_info_type_t;
#endif

#endif /* _DRM_UAPI_H_ */
EOF

    # Update main drm.h
    cat <<EOF >"$workdir/include/libdrm/drm/drm.h"
#ifndef _DRM_H_
#define _DRM_H_

#include "drm_base_types.h"
#include "drm_uapi.h"
#include "drm_pci.h"
#include "drm_device.h"
#include "drm_syncobj.h"
#include "drm_stub.h"

#endif /* _DRM_H_ */
EOF

    # Create stub implementation header
    cat <<EOF >"$workdir/include/libdrm/drm/drm_stub.h"
#ifndef _DRM_STUB_H_
#define _DRM_STUB_H_

#include "drm_base_types.h"
#include "drm_device.h"

#ifdef __cplusplus
extern "C" {
#endif

/* DRM function declarations */
int drmGetNodeTypeFromFd(int fd);
char *drmGetDeviceNameFromFd2(int fd);
int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device);
void drmFreeDevice(drmDevicePtr *device);
int drmGetMagic(int fd, drm_magic_t *magic);
int drmAuthMagic(int fd, drm_magic_t magic);
int drmCreateContext(int fd, drm_context_t *handle);
void drmFreeReservedContextList(drm_context_t *pt);
int drmCreateDrawable(int fd, drm_drawable_t *handle);
int drmDestroyDrawable(int fd, drm_drawable_t handle);

#ifdef __cplusplus
}
#endif

#endif /* _DRM_STUB_H_ */
EOF

    # Create drm_syncobj.h with sync object definitions
    cat <<EOF >"$workdir/include/libdrm/drm/drm_syncobj.h"
#ifndef _DRM_SYNCOBJ_H_
#define _DRM_SYNCOBJ_H_

#define DRM_SYNCOBJ_CREATE_SIGNALED        (1 << 0)
#define DRM_SYNCOBJ_WAIT_FLAGS_WAIT_ALL    (1 << 0)
#define DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT (1 << 1)
#define DRM_SYNCOBJ_WAIT_FLAGS_WAIT_AVAILABLE  (1 << 2)

/* Capability definitions */
#define DRM_CAP_SYNCOBJ_TIMELINE   0x14

int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle);
int drmSyncobjDestroy(int fd, uint32_t handle);
int drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles,
                   int64_t timeout_nsec, unsigned flags,
                   uint32_t *first_signaled);
int drmGetCap(int fd, uint64_t capability, uint64_t *value);

#endif /* _DRM_SYNCOBJ_H_ */
EOF

    # Update drm_stub.c to use proper types
    cat <<EOF >"$workdir/drm_stub.c"
#include "drm/drm.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

int drmGetNodeTypeFromFd(int fd) { return -1; }
char *drmGetDeviceNameFromFd2(int fd) { return NULL; }
int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device) { 
    if (device) {
        *device = calloc(1, sizeof(drmDevice));
        if (*device) {
            (*device)->businfo = calloc(1, sizeof(struct drm_device_bus_info));
        }
    }
    return -1; 
}
void drmFreeDevice(drmDevicePtr *device) { 
    if (device && *device) {
        free((*device)->businfo);
        free(*device);
        *device = NULL;
    }
}

/* Rest of stub implementations */
int drmGetMagic(int fd, drm_magic_t *magic) { return -1; }
int drmAuthMagic(int fd, drm_magic_t magic) { return -1; }
int drmCreateContext(int fd, drm_context_t *handle) { return -1; }
void drmFreeReservedContextList(drm_context_t *pt) { }
int drmCreateDrawable(int fd, drm_drawable_t *handle) { return -1; }
int drmDestroyDrawable(int fd, drm_drawable_t handle) { return -1; }
int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle) { return -1; }
int drmSyncobjDestroy(int fd, uint32_t handle) { return -1; }
int drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles,
                   int64_t timeout_nsec, unsigned flags,
                   uint32_t *first_signaled) { return -1; }
int drmGetCap(int fd, uint64_t capability, uint64_t *value) { return -1; }
EOF

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

    # Create a single header for all DRM types and definitions
    cat <<EOF >"$workdir/include/libdrm/drm/drm_all.h"
#ifndef _DRM_ALL_H_
#define _DRM_ALL_H_

#include <stdint.h>

/* Basic type definitions */
typedef unsigned int drm_handle_t;
typedef unsigned int drm_context_t;
typedef unsigned int drm_magic_t;

/* Device structure */
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

/* Function declarations */
#ifdef __cplusplus
extern "C" {
#endif

int drmGetNodeTypeFromFd(int fd);
char *drmGetDeviceNameFromFd2(int fd);
int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device);
void drmFreeDevice(drmDevicePtr *device);
int drmGetMagic(int fd, drm_magic_t *magic);
int drmAuthMagic(int fd, drm_magic_t magic);
int drmCreateContext(int fd, drm_context_t *handle);
void drmFreeReservedContextList(drm_context_t *pt);

#ifdef __cplusplus
}
#endif

#endif /* _DRM_ALL_H_ */
EOF

    # Create stub library implementation
    cat <<EOF >"$workdir/drm_stub.c"
#include "drm/drm_all.h"
#include <stddef.h>

int drmGetNodeTypeFromFd(int fd) { return -1; }
char *drmGetDeviceNameFromFd2(int fd) { return NULL; }
int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device) { return -1; }
void drmFreeDevice(drmDevicePtr *device) { }
int drmGetMagic(int fd, drm_magic_t *magic) { return -1; }
int drmAuthMagic(int fd, drm_magic_t magic) { return -1; }
int drmCreateContext(int fd, drm_context_t *handle) { return -1; }
void drmFreeReservedContextList(drm_context_t *pt) { }
int drmCreateDrawable(int fd, drm_drawable_t *handle) { return -1; }
int drmDestroyDrawable(int fd, drm_drawable_t handle) { return -1; }
int drmSyncobjCreate(int fd, uint32_t flags, uint32_t *handle) { return -1; }
int drmSyncobjDestroy(int fd, uint32_t handle) { return -1; }
int drmSyncobjWait(int fd, uint32_t *handles, unsigned num_handles,
                   int64_t timeout_nsec, unsigned flags,
                   uint32_t *first_signaled) { return -1; }
int drmGetCap(int fd, uint64_t capability, uint64_t *value) { return -1; }
EOF

    # Create lib directory and compile
    mkdir -p "$workdir/lib"
    "$ndk/aarch64-linux-android$sdkver-clang" -c -o "$workdir/drm_stub.o" "$workdir/drm_stub.c" \
        -I"$workdir/include/libdrm" \
        -fPIC -Wno-unused-parameter

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
