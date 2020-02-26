"""Tools for handling and linking static and dynamic libraries.

This includes C and Haskell libraries as both are tracked in CcInfo
providers.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(
    ":private/packages.bzl",
    "ghc_pkg_recache",
    "write_package_conf",
)
load(
    ":private/path_utils.bzl",
    "create_rpath_entry",
    "get_dirname",
    "get_lib_name",
    "is_hs_library",
    "mangle_static_library",
    "rel_to_pkgroot",
    "target_unique_name",
)
load(
    ":providers.bzl",
    "HaskellCcLibrariesInfo",
    "HaskellCcLibraryInfo",
    "HaskellInfo",
    "HaskellProtobufInfo",
)

def get_extra_libs(hs, cc_libraries_info, libraries_to_link, dynamic = False, pic = None):
    """Get libraries appropriate for linking with GHC.

    GHC expects dynamic and static versions of the same library to have the
    same library name. Static libraries for which this is not the case will be
    symlinked to a matching name.

    Furthermore, dynamic libraries will be symbolically linked into a common
    directory to allow for less RPATH entries.

    Args:
      hs: Haskell context.
      dynamic: Whether to prefer dynamic libraries.
      cc_libraries_info: Combined HaskellCcLibrariesInfo of dependencies.
      libraries_to_link: list of LibraryToLink.
      dynamic: Whether dynamic libraries are preferred.
      pic: Whether position independent code is required.

    Returns:
      depset of File: the libraries that should be passed to GHC for linking.

    """
    static_libs = []
    dynamic_libs = []
    if pic == None:
        pic = dynamic

    # PIC is irrelevant on static GHC.
    pic_required = pic and not hs.toolchain.is_static
    for lib_to_link in libraries_to_link:
        cc_library_info = cc_libraries_info.libraries[cc_library_key(lib_to_link)]
        dynamic_lib = None
        if lib_to_link.dynamic_library:
            dynamic_lib = lib_to_link.dynamic_library
        elif lib_to_link.interface_library:
            dynamic_lib = lib_to_link.interface_library
        static_lib = None
        if lib_to_link.pic_static_library:
            static_lib = cc_library_info.pic_static_library_link
            if static_lib == None:
                static_lib = lib_to_link.pic_static_library
        elif lib_to_link.static_library and not pic_required:
            static_lib = cc_library_info.static_library_link
            if static_lib == None:
                static_lib = lib_to_link.static_library

        if static_lib and not (dynamic and dynamic_lib):
            static_libs.append(static_lib)
        elif dynamic_lib:
            dynamic_libs.append(dynamic_lib)
        else:
            # Fall back if no PIC static library is available. This typically
            # happens during profiling builds.
            static_libs.append(lib_to_link.static_library)

    static_libs = depset(direct = static_libs)
    dynamic_libs = depset(direct = dynamic_libs)
    return (static_libs, dynamic_libs)

def link_libraries(libs, args, prefix_optl = False):
    """Add linker flags to link against the given libraries.

    Args:
      libs: Sequence of File, libraries to link.
      args: Args or List, append arguments to this object.
      prefix_optl: Bool, whether to prefix linker flags by -optl

    """

    # This test is a hack. When a CC library has a Haskell library
    # as a dependency, we need to be careful to filter it out,
    # otherwise it will end up polluting the linker flags. GHC
    # already uses hs-libraries to link all Haskell libraries.
    #
    # TODO Get rid of this hack. See
    # https://github.com/tweag/rules_haskell/issues/873.
    cc_libs = depset(direct = [
        lib
        for lib in libs.to_list()
        if not is_hs_library(lib)
    ])

    if prefix_optl:
        libfmt = "-optl-l%s"
        dirfmt = "-optl-L%s"
    else:
        libfmt = "-l%s"
        dirfmt = "-L%s"

    if hasattr(args, "add_all"):
        args.add_all(cc_libs, map_each = get_lib_name, format_each = libfmt)
        args.add_all(cc_libs, map_each = get_dirname, format_each = dirfmt, uniquify = True)
    else:
        cc_libs_list = cc_libs.to_list()
        args.extend([libfmt % get_lib_name(lib) for lib in cc_libs_list])
        args.extend([dirfmt % lib.dirname for lib in cc_libs_list])

def create_link_config(hs, posix, cc_libraries_info, libraries_to_link, binary, args, dynamic = None, pic = None):
    """Configure linker flags and inputs.

    Configure linker flags for C library dependencies and runtime dynamic
    library dependencies. And collect the C libraries to pass as inputs to
    the linking action. Creates a package configuration file that captures
    these flags.

    Args:
      hs: Haskell context.
      cc_libraries_info: Combined HaskellCcLibrariesInfo of dependencies.
      libraries_to_link: list of LibraryToLink.
      binary: Final linked binary.
      args: Arguments to the linking action.
      dynamic: Whether to link dynamically, or statically.
      pic: Whether position independent code is required.

    Returns:
      (cache_file, static_libs, dynamic_libs):
        cache_file: File, the cached package configuration.
        static_libs: depset of File, static library files.
        dynamic_libs: depset of File, dynamic library files.
    """

    (static_libs, dynamic_libs) = get_extra_libs(
        hs,
        cc_libraries_info,
        libraries_to_link,
        dynamic = dynamic,
        pic = pic,
    )

    # This test is a hack. When a CC library has a Haskell library
    # as a dependency, we need to be careful to filter it out,
    # otherwise it will end up polluting the linker flags. GHC
    # already uses hs-libraries to link all Haskell libraries.
    #
    # TODO Get rid of this hack. See
    # https://github.com/tweag/rules_haskell/issues/873.
    cc_static_libs = depset(direct = [
        lib
        for lib in static_libs.to_list()
        if not is_hs_library(lib)
    ])
    cc_dynamic_libs = depset(direct = [
        lib
        for lib in dynamic_libs.to_list()
        if not is_hs_library(lib)
    ])

    package_name = target_unique_name(hs, "link-config").replace("_", "-").replace("@", "-")
    conf_path = paths.join(package_name, package_name + ".conf")
    conf_file = hs.actions.declare_file(conf_path)
    libs = cc_static_libs.to_list() + cc_dynamic_libs.to_list()
    write_package_conf(hs, conf_file, {
        "name": package_name,
        "extra-libraries": [
            get_lib_name(lib)
            for lib in libs
        ],
        "library-dirs": depset(direct = [
            rel_to_pkgroot(lib.dirname, conf_file.dirname)
            for lib in libs
        ]),
        "dynamic-library-dirs": depset(direct = [
            rel_to_pkgroot(lib.dirname, conf_file.dirname)
            for lib in libs
        ]),
        # XXX: Set user_link_flags.
        "ld-options": depset(direct = [
            "-Wl,-rpath,%s" % create_rpath_entry(
                binary = binary,
                dependency = lib,
                keep_filename = False,
                prefix = "@loader_path" if hs.toolchain.is_darwin else "$ORIGIN",
            )
            for lib in dynamic_libs.to_list()
        ]),
    })
    cache_file = ghc_pkg_recache(hs, posix, conf_file)

    args.add_all([
        "-package-db",
        cache_file.dirname,
        "-package",
        package_name,
    ])

    return (cache_file, static_libs, dynamic_libs)

def cc_library_key(library_to_link):
    """Convert a LibraryToLink into a hashable dictionary key."""
    return struct(
        dynamic_library = library_to_link.dynamic_library,
        interface_library = library_to_link.interface_library,
        static_library = library_to_link.static_library,
        pic_static_library = library_to_link.pic_static_library,
    )

def deps_HaskellCcLibrariesInfo(deps):
    """Merge the HaskellCcLibrariesInfo over all given dependencies.

    Works on proto_library dependencies as well, where HaskellCcLibrariesInfo
    needs to be constructed by _haskell_proto_aspect.

    Args:
      deps: list of Target, extracts HaskellCcLibrariesInfo from the target
        directly, or from HaskellProtobufInfo if present.

    Returns:
      HaskellCcLibrariesInfo
    """
    infos = []
    for dep in deps:
        if HaskellCcLibrariesInfo in dep:
            infos.append(dep[HaskellCcLibrariesInfo])
        elif HaskellProtobufInfo in dep:
            infos.append(dep[HaskellProtobufInfo].cc_libraries_info)
    return merge_HaskellCcLibrariesInfo(infos = infos)

def merge_HaskellCcLibrariesInfo(infos):
    """Merge multiple HaskellCcLibrariesInfo.

    Prefer deps_HaskellCcLibrariesInfo if possible.
    """
    return HaskellCcLibrariesInfo(
        libraries = dicts.add(*[info.libraries for info in infos]),
    )

def extend_HaskellCcLibrariesInfo(
        ctx,
        cc_libraries_info,
        cc_info,
        is_haskell):
    """Adapt new LibraryToLink and add to HaskellCcLibrariesInfo.

    Generate a new HaskellCcLibraryInfo for each LibraryToLink in cc_info that
    is not already contained in cc_libraries_info and return a new extended
    CcLibrariesInfo.

    Args:
      ctx: Aspect or rule context.
      cc_libraries_info: HaskellCcLibrariesInfo of all dependencies.
      cc_info: CcInfo of the current target.
      is_haskell: Bool, whether the current target is a Haskell library.

    Returns:
      HaskellCcLibrariesInfo
    """
    hs = ctx.toolchains["@rules_haskell//haskell:toolchain"]
    posix = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]
    libraries = dict(cc_libraries_info.libraries)

    for lib_to_link in cc_info.linking_context.libraries_to_link.to_list():
        key = cc_library_key(lib_to_link)
        if key in libraries:
            continue
        if is_haskell:
            libraries[key] = HaskellCcLibraryInfo(
                static_library_link = None,
                pic_static_library_link = None,
                is_haskell = True,
            )
        else:
            libraries[key] = HaskellCcLibraryInfo(
                static_library_link = mangle_static_library(
                    ctx,
                    posix,
                    lib_to_link.dynamic_library,
                    lib_to_link.static_library,
                    outdir = "_ghc_a",
                ),
                pic_static_library_link = mangle_static_library(
                    ctx,
                    posix,
                    lib_to_link.dynamic_library,
                    lib_to_link.pic_static_library,
                    outdir = "_ghc_pic_a",
                ),
                is_haskell = False,
            )

    return HaskellCcLibrariesInfo(libraries = libraries)

def _haskell_cc_libraries_aspect_impl(target, ctx):
    if HaskellProtobufInfo in target:
        # haskell_cc_libraries_aspect depends on the CcInfo and optionally
        # HaskellInfo providers of a target. In the case of proto_library
        # targets these providers are returned by the _haskell_proto_aspect.
        # That aspect in turn requires HaskellCcLibrariesInfo in all its
        # dependencies. Bazel does not allow this kind of cyclic dependency and
        # one aspect will not be able to observe the other.
        #
        # To work around this we instead generate HaskellCcLibrariesInfo within
        # _haskell_proto_aspect and bundle it in HaskellProtobufInfo.
        return target[HaskellProtobufInfo].cc_libraries_info

    hs = ctx.toolchains["@rules_haskell//haskell:toolchain"]
    posix = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]

    cc_libraries_info = merge_HaskellCcLibrariesInfo(infos = [
        dep[HaskellCcLibrariesInfo]
        for attr in ["deps", "exports", "plugins"]
        for dep in getattr(ctx.rule.attr, attr, [])
        if HaskellCcLibrariesInfo in dep
    ])

    if CcInfo in target:
        cc_libraries_info = extend_HaskellCcLibrariesInfo(
            ctx = ctx,
            cc_libraries_info = cc_libraries_info,
            cc_info = target[CcInfo],
            is_haskell = HaskellInfo in target,
        )

    return [cc_libraries_info]

haskell_cc_libraries_aspect = aspect(
    implementation = _haskell_cc_libraries_aspect_impl,
    attr_aspects = ["deps", "exports", "plugins"],
    provides = [HaskellCcLibrariesInfo],
    required_aspect_providers = [HaskellProtobufInfo],
    toolchains = [
        "@rules_haskell//haskell:toolchain",
        "@rules_sh//sh/posix:toolchain_type",
    ],
)
"""Extend LibraryToLink of C dependencies for GHC compatibility

Create a symbolic link for each static library whose name doesn't match the
mangled name of the corresponding dynamic library.
"""
