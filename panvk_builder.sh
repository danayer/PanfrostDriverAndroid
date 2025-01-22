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

check_deps() {
    # ...existing code...
}

prepare_workdir() {
    # ...existing code...
}

apply_patches() {
    # ...existing code...
}

patch_to_description() {
    # ...existing code...
}

build_lib_for_android(){
    # ...existing code...
    
    echo "Generating build files ..." $'\n'
    meson build-android-aarch64 --cross-file "$workdir"/mesa/android-aarch64 -Dbuildtype=release -Dplatforms=android -Dplatform-sdk-version=$sdkver -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=panfrost -Dvulkan-beta=true -Dpanfrost-kmds=kgsl -Db_lto=true &> "$workdir"/meson_log

    echo "Compiling build files ..." $'\n'
    ninja -C build-android-aarch64 &> "$workdir"/ninja_log
}

port_lib_for_adrenotool(){
    echo "Using patchelf to match soname ..."  $'\n'
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
