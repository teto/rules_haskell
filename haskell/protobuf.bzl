"""Support for protocol buffers"""

load(
    ":private/haskell_impl.bzl",
    _haskell_library_impl = "haskell_library_impl",
)
load("@bazel_skylib//lib:paths.bzl", "paths")
load(
    "@io_tweag_rules_haskell//haskell:providers.bzl",
    "HaskellInfo",
    "HaskellLibraryInfo",
    "HaskellProtobufInfo",
)

def _capitalize_first_letter(c):
    """Capitalize the first letter of the input. Unlike the built-in
    `capitalize()` method, doesn't lower-case the other characters. This helps
    mimic the behavior of `proto-lens-protoc`, which turns `Foo/Bar/BAZ.proto`
    into `Foo/Bar/BAZ.hs` (rather than `Foo/Bar/Baz.hs`).

    Args:
      c: A non-empty string word.

    Returns:
      The input with the first letter upper-cased.
    """
    return c[0].capitalize() + c[1:]

def _camel_case(comp):
    """Camel-case the input string, preserving any existing capital letters.
    """

    # Split on both "-" and "_", matching the behavior of proto-lens-protoc.
    # Be sure to ignore any empty segments from input with leading or trailing
    # delimiters.
    return "".join([
        _capitalize_first_letter(c2)
        for c1 in comp.split("_")
        for c2 in c1.split("-")
        if len(c2) > 0
    ])

def _proto_lens_output_file(path):
    """The output file from `proto-lens-protoc` when run on the given `path`.
    """

    path = path[:-len(".proto")]
    result = "/".join([_camel_case(p) for p in path.split("/")]) + ".hs"

    return "Proto/" + result

def _proto_lens_fields_file(path):
    """The fields file from `proto-lens-protoc` when run on the given `path`.
    """

    path = path[:-len(".proto")]
    result = "/".join([_camel_case(p) for p in path.split("/")]) + "_Fields.hs"

    return "Proto/" + result

def _proto_path(proto, proto_source_roots):
    """A path to the proto file which matches any import statements."""
    proto_path = proto.path
    for p in proto_source_roots:
        if proto_path.startswith(p):
            return paths.relativize(proto_path, p)

    return paths.relativize(
        proto_path,
        paths.join(proto.root.path, proto.owner.workspace_root),
    )

def _haskell_proto_aspect_impl(target, ctx):
    pb = ctx.toolchains["@io_tweag_rules_haskell//protobuf:toolchain"].tools

    args = ctx.actions.args()

    src_prefix = paths.join(
        ctx.label.workspace_root,
        ctx.label.package,
    )

    args.add("--plugin=protoc-gen-haskell=" + pb.plugin.path)

    hs_files = []
    inputs = []

    direct_proto_paths = [target.proto.proto_source_root]
    transitive_proto_paths = target.proto.transitive_proto_path

    args.add_all([
        "-I{0}={1}".format(_proto_path(s, transitive_proto_paths), s.path)
        for s in target.proto.transitive_sources.to_list()
    ])

    inputs.extend(target.proto.transitive_sources.to_list())

    for src in target.proto.direct_sources:
        inputs.append(src)

        # As with the native rules, require the .proto file to be in the same
        # Bazel package as the proto_library rule. This allows us to put the
        # output .hs file next to the input .proto file. Unfortunately Skylark
        # doesn't let us check the package of the file directly, so instead we
        # just look at its short_path and rely on the proto_library rule itself
        # to check for consistency. We use the file's path rather than its
        # dirname/basename in case it's in a subdirectory; for example, if the
        # proto_library rule is in "foo/BUILD" but the .proto file is
        # "foo/bar/baz.proto".

        if not src.path.startswith(paths.join(src.root.path, src_prefix)):
            fail("Mismatch between rule context " + str(ctx.label.package) +
                 " and source file " + src.short_path)
        if src.basename[-6:] != ".proto":
            fail("bad extension for proto file " + src)

        args.add(src.path)
        hs_files.append(ctx.actions.declare_file(
            _proto_lens_output_file(
                _proto_path(src, direct_proto_paths),
            ),
        ))
        hs_files.append(ctx.actions.declare_file(
            _proto_lens_fields_file(
                _proto_path(src, direct_proto_paths),
            ),
        ))

    args.add_all([
        "--proto_path=" + target.proto.proto_source_root,
        "--haskell_out=no-runtime:" + paths.join(
            hs_files[0].root.path,
            src_prefix,
        ),
    ])

    ctx.actions.run(
        inputs = depset([pb.protoc, pb.plugin] + inputs),
        outputs = hs_files,
        mnemonic = "HaskellProtoc",
        executable = pb.protoc,
        arguments = [args],
    )

    patched_attrs = {
        "compiler_flags": [],
        "src_strip_prefix": "",
        "repl_interpreted": True,
        "repl_ghci_args": [],
        "version": "",
        "linkstatic": False,
        "_ghci_script": ctx.attr._ghci_script,
        "_ghci_repl_wrapper": ctx.attr._ghci_repl_wrapper,
        "hidden_modules": [],
        "exports": {},
        "name": "proto-autogen-" + ctx.rule.attr.name,
        "srcs": hs_files,
        "deps": ctx.rule.attr.deps +
                ctx.toolchains["@io_tweag_rules_haskell//protobuf:toolchain"].deps,
        "plugins": [],
        "_cc_toolchain": ctx.attr._cc_toolchain,
    }

    patched_ctx = struct(
        actions = ctx.actions,
        attr = struct(**patched_attrs),
        bin_dir = ctx.bin_dir,
        disabled_features = ctx.rule.attr.features,
        executable = struct(
            _ls_modules = ctx.executable._ls_modules,
        ),
        # Necessary for CC interop (see cc.bzl).
        features = ctx.rule.attr.features,
        file = ctx.file,
        files = struct(
            srcs = hs_files,
            _cc_toolchain = ctx.files._cc_toolchain,
            extra_srcs = depset(),
        ),
        genfiles_dir = ctx.genfiles_dir,
        label = ctx.label,
        toolchains = ctx.toolchains,
        var = ctx.var,
    )

    # TODO this pattern match is very brittle. Let's not do this. The
    # order should match the order in the return value expression in
    # haskell_library_impl().
    [hs_info, cc_info, coverage_info, default_info, library_info] = _haskell_library_impl(patched_ctx)

    return [
        cc_info,  # CcInfo
        hs_info,  # HaskellInfo
        library_info,  # HaskellLibraryInfo
        # We can't return DefaultInfo here because target already provides that.
        HaskellProtobufInfo(files = default_info.files),
    ]

_haskell_proto_aspect = aspect(
    _haskell_proto_aspect_impl,
    attr_aspects = ["deps"],
    attrs = {
        "_ghci_script": attr.label(
            allow_single_file = True,
            default = Label("@io_tweag_rules_haskell//haskell:assets/ghci_script"),
        ),
        "_ghci_repl_wrapper": attr.label(
            allow_single_file = True,
            default = Label("@io_tweag_rules_haskell//haskell:private/ghci_repl_wrapper.sh"),
        ),
        "_ls_modules": attr.label(
            executable = True,
            cfg = "host",
            default = Label("@io_tweag_rules_haskell//haskell:ls_modules"),
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    toolchains = [
        "@io_tweag_rules_haskell//haskell:toolchain",
        "@io_tweag_rules_haskell//protobuf:toolchain",
    ],
)

def _haskell_proto_library_impl(ctx):
    dep = ctx.attr.deps[0]  # FIXME
    return [
        dep[CcInfo],
        dep[HaskellInfo],
        dep[HaskellLibraryInfo],
        DefaultInfo(files = dep[HaskellProtobufInfo].files),
    ]

haskell_proto_library = rule(
    _haskell_proto_library_impl,
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            allow_files = False,
            aspects = [_haskell_proto_aspect],
            doc = "List of `proto_library` targets to use for generation.",
        ),
    },
    toolchains = [
        "@io_tweag_rules_haskell//haskell:toolchain",
        "@io_tweag_rules_haskell//protobuf:toolchain",
    ],
)

"""Generate Haskell library allowing to use protobuf definitions with help
of [`proto-lens`](https://github.com/google/proto-lens#readme).

Example:
  ```bzl
  proto_library(
    name = "foo_proto",
    srcs = ["foo.proto"],
  )

  haskell_proto_library(
    name = "foo_haskell_proto",
    deps = [":foo_proto"],
  )
  ```

`haskell_proto_library` targets require `haskell_proto_toolchain` to be
registered.
"""

def _protobuf_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            name = ctx.label.name,
            tools = struct(
                plugin = ctx.executable.plugin,
                protoc = ctx.executable.protoc,
            ),
            deps = ctx.attr.deps,
        ),
    ]

_protobuf_toolchain = rule(
    _protobuf_toolchain_impl,
    attrs = {
        "protoc": attr.label(
            executable = True,
            cfg = "host",
            allow_single_file = True,
            mandatory = True,
            doc = "protoc compiler",
        ),
        "plugin": attr.label(
            executable = True,
            cfg = "host",
            allow_single_file = True,
            mandatory = True,
            doc = "proto-lens-protoc plugin for protoc",
        ),
        "deps": attr.label_list(
            doc = "List of other Haskell libraries to be linked to protobuf libraries.",
        ),
    },
)

def haskell_proto_toolchain(
        name,
        plugin,
        deps = [],
        protoc = Label("@com_google_protobuf//:protoc"),
        **kwargs):
    """Declare a Haskell protobuf toolchain.

    You need at least one of these declared somewhere in your `BUILD` files
    for the `haskell_proto_library` rules to work. Once declared, you then
    need to *register* the toolchain using `register_toolchains` in your
    `WORKSPACE` file (see example below).

    Example:

      In a `BUILD` file:

      ```bzl
      haskell_proto_toolchain(
        name = "protobuf-toolchain",
        protoc = "@com_google_protobuf//:protoc",
        plugin = "@hackage-proto-lens-protoc//:bin/proto-lens-protoc",
        deps = [
          "base",
          "bytestring",
          "containers",
          "data-default-class",
          "lens-family",
          "lens-labels",
          "proto-lens",
          "text",
        ],
      )
      ```

      The `deps` attribute is for specifying Haskell libraries to use
      when compiling the auto-generated source files.

      In `WORKSPACE` you could have something like this:

      ```bzl
      http_archive(
        name = "com_google_protobuf",
        sha256 = "cef7f1b5a7c5fba672bec2a319246e8feba471f04dcebfe362d55930ee7c1c30",
        strip_prefix = "protobuf-3.5.0",
        urls = ["https://github.com/google/protobuf/archive/v3.5.0.zip"],
      )

      nixpkgs_package(
        name = "protoc_gen_haskell",
        repository = "@nixpkgs",
        attribute_path = "haskell.packages.ghc822.proto-lens-protoc
      )

      register_toolchains(
        "//tests:ghc", # assuming you called your Haskell toolchain "ghc"
        "//tests:protobuf-toolchain",
      )
      ```

    """
    impl_name = name + "-impl"
    _protobuf_toolchain(
        name = impl_name,
        plugin = plugin,
        deps = deps,
        protoc = protoc,
        visibility = ["//visibility:public"],
        **kwargs
    )

    native.toolchain(
        name = name,
        toolchain_type = "@io_tweag_rules_haskell//protobuf:toolchain",
        toolchain = ":" + impl_name,
        exec_compatible_with = [
            "@bazel_tools//platforms:x86_64",
        ],
    )
