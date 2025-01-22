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
    # Fix syntax error in if condition
    if [ -z "${ANDROID_NDK_LATEST_HOME}" ]; then
        ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
    else    
        ndk="$ANDROID_NDK_LATEST_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    fi

    # Create cross file in mesa directory
    cat <<EOF >"$workdir/mesa/android-aarch64"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=NDKDIR/pkgconfig', '/usr/bin/pkg-config']
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

    # Updated Meson configuration without problematic builtin definitions
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
        -Db_lto=false \
        -Dc_args="-O2 -Wno-error -DPANVK_VERSION_OVERRIDE=71" \
        -Dcpp_args="-O2 -Wno-error -DPANVK_VERSION_OVERRIDE=71" \
        -Dc_link_args="-lm -fuse-ld=lld -Wl,--undefined-version" \
        -Dcpp_link_args="-lm -fuse-ld=lld -Wl,--undefined-version" &> "$workdir"/meson_log || {
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
