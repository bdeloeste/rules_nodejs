# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Custom provider that mimics the Runfiles, but doesn't incur the expense of creating the runfiles symlink tree"""

load("//internal/linker:link_node_modules.bzl", "add_arg", "write_node_modules_manifest")
load("//internal/providers:external_npm_package_info.bzl", "ExternalNpmPackageInfo")

NodeRuntimeDepsInfo = provider(
    doc = """Stores runtime dependencies of a nodejs_binary or nodejs_test

These are files that need to be found by the node module resolver at runtime.

Historically these files were passed using the Runfiles mechanism.
However runfiles has a big performance penalty of creating a symlink forest
with FS API calls for every file in node_modules.
It also causes there to be separate node_modules trees under each binary. This
prevents user-contributed modules passed as deps[] to a particular action from
being found by node module resolver, which expects everything in one tree.

In node, this resolution is done dynamically by assuming a node_modules
tree will exist on disk, so we assume node actions/binary/test executions will
do the same.
""",
    fields = {
        "deps": "depset of runtime dependency labels",
        "pkgs": "list of labels of packages that provide ExternalNpmPackageInfo",
    },
)

def _compute_node_modules_root(ctx):
    """Computes the node_modules root (if any) from data & deps targets."""
    node_modules_root = ""
    deps = []
    if hasattr(ctx.attr, "data"):
        deps += ctx.attr.data
    if hasattr(ctx.attr, "deps"):
        deps += ctx.attr.deps
    for d in deps:
        if ExternalNpmPackageInfo in d:
            possible_root = "/".join([d[ExternalNpmPackageInfo].workspace, "node_modules"])
            if not node_modules_root:
                node_modules_root = possible_root
            elif node_modules_root != possible_root:
                fail("All npm dependencies need to come from a single workspace. Found '%s' and '%s'." % (node_modules_root, possible_root))
    return node_modules_root

def run_node(ctx, inputs, arguments, executable, **kwargs):
    """Helper to replace ctx.actions.run

    This calls node programs with a node_modules directory in place

    Args:
        ctx: rule context from the calling rule implementation function
        inputs: list or depset of inputs to the action
        arguments: list or ctx.actions.Args object containing arguments to pass to the executable
        executable: stringy representation of the executable this action will run, eg eg. "my_executable" rather than ctx.executable.my_executable
        mnemonic: optional action mnemonic, used to differentiate module mapping files from the same rule context
        link_workspace_root: Link the workspace root to the bin_dir to support absolute requires like 'my_wksp/path/to/file'.
            If source files need to be required then they can be copied to the bin_dir with copy_to_bin.
        kwargs: all other args accepted by ctx.actions.run
    """
    if (type(executable) != "string"):
        fail("""run_node requires that executable be provided as a string,
            eg. my_executable rather than ctx.executable.my_executable
            got %s""" % type(executable))
    exec_attr = getattr(ctx.attr, executable)
    exec_exec = getattr(ctx.executable, executable)

    outputs = kwargs.pop("outputs", [])
    extra_inputs = depset()
    link_data = []
    if (NodeRuntimeDepsInfo in exec_attr):
        extra_inputs = exec_attr[NodeRuntimeDepsInfo].deps
        link_data = exec_attr[NodeRuntimeDepsInfo].pkgs

    # NB: mnemonic is also passed to ctx.actions.run below
    mnemonic = kwargs.get("mnemonic")
    link_workspace_root = kwargs.pop("link_workspace_root", False)
    modules_manifest = write_node_modules_manifest(
        ctx,
        extra_data = link_data,
        mnemonic = mnemonic,
        link_workspace_root = link_workspace_root,
    )
    add_arg(arguments, "--bazel_node_modules_manifest=%s" % modules_manifest.path)

    stdout_file = kwargs.pop("stdout", None)
    if stdout_file:
        add_arg(arguments, "--bazel_capture_stdout=%s" % stdout_file.path)
        outputs = outputs + [stdout_file]

    stderr_file = kwargs.pop("stderr", None)
    if stderr_file:
        add_arg(arguments, "--bazel_capture_stderr=%s" % stderr_file.path)
        outputs = outputs + [stderr_file]

    exit_code_file = kwargs.pop("exit_code_out", None)
    if exit_code_file:
        # this will force the script to exit 0, all declared outputs must still be created
        add_arg(arguments, "--bazel_capture_exit_code=%s" % exit_code_file.path)
        outputs = outputs + [exit_code_file]

    env = kwargs.pop("env", {})

    # Always forward the COMPILATION_MODE to node process as an environment variable
    configuration_env_vars = kwargs.pop("configuration_env_vars", []) + ["COMPILATION_MODE"]
    for var in configuration_env_vars:
        if var not in env.keys():
            # If env is not explicitly specified, check ctx.var first & if env var not in there
            # then check ctx.configuration.default_shell_env. The former will contain values from
            # --define=FOO=BAR and latter will contain values from --action_env=FOO=BAR
            # (but not from --action_env=FOO).
            if var in ctx.var.keys():
                env[var] = ctx.var[var]
            elif var in ctx.configuration.default_shell_env.keys():
                env[var] = ctx.configuration.default_shell_env[var]
    env["BAZEL_NODE_MODULES_ROOT"] = _compute_node_modules_root(ctx)

    # ctx.actions.run accepts both lists and a depset for inputs. Coerce the original inputs to a
    # depset if they're a list, so that extra inputs can be combined in a performant manner.
    inputs_depset = depset(transitive = [
        depset(direct = inputs) if type(inputs) == "list" else inputs,
        extra_inputs,
        depset(direct = [modules_manifest]),
    ])

    ctx.actions.run(
        outputs = outputs,
        inputs = inputs_depset,
        arguments = arguments,
        executable = exec_exec,
        env = env,
        **kwargs
    )
